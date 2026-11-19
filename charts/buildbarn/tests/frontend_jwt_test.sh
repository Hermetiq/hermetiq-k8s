#!/usr/bin/env bash
# Exercise the rendered Jsonnet and JMESPath policy, including the anonymous
# fallback and write authorizers. String matching alone cannot prove that a
# valid token from the wrong client loses write/execute access.
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${chart_dir}" <<'PY'
import copy
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

import _jsonnet
import jmespath
import yaml

chart = pathlib.Path(sys.argv[1])


def render(jwks, *, starter=False, frontend=None, source_chart=chart, extra_values=None):
    with tempfile.TemporaryDirectory() as directory:
        directory = pathlib.Path(directory)
        values = copy.deepcopy(extra_values or {})
        values["frontend"] = copy.deepcopy(frontend or {})
        values["frontend"]["jwks"] = {"enabled": True, **jwks}
        overrides = directory / "values.yaml"
        overrides.write_text(yaml.safe_dump(values))
        fixture = (chart.parents[1] / "custom-values/buildbarn-values.yaml"
                   if starter else source_chart / "ci-values/ci.yaml")
        output = subprocess.check_output([
            "helm", "template", "frontend-jwt", str(source_chart),
            "-f", str(fixture), "-f", str(overrides),
        ], text=True)
        config = next(
            obj["data"] for obj in yaml.safe_load_all(output)
            if obj and obj["kind"] == "ConfigMap"
            and obj["metadata"]["name"] == "buildbarn-config"
        )
        for name, content in config.items():
            (directory / name).write_text(content)
        return json.loads(_jsonnet.evaluate_file(str(directory / "frontend.jsonnet")))


def jwt_policy(config):
    policies = config["grpcServers"][0]["authenticationPolicy"]["any"]["policies"]
    assert policies[1] == {"allow": {}}, "anonymous reads must remain available"
    return policies[0]["jwt"]


def claims_match(config, payload):
    expression = jwt_policy(config)["claimsValidationJmespathExpression"]["expression"]
    # bb-storage requires a boolean true, not just a truthy JMESPath result.
    return jmespath.search(expression, {"payload": payload}) is True


def write_decisions(config, payload):
    # Signature/expiry verification belongs to bb-storage. Here the supplied
    # payload represents a valid signed token, or None for an anonymous caller.
    metadata = {}
    if payload is not None and claims_match(config, payload):
        expression = jwt_policy(config)["metadataExtractionJmespathExpression"]["expression"]
        metadata = jmespath.search(expression, {"payload": payload})
    policies = [
        config["contentAddressableStorage"]["putAuthorizer"],
        config["actionCache"]["putAuthorizer"],
        config["executeAuthorizer"],
    ]
    decisions = []
    for policy in policies:
        if "allow" in policy:
            decisions.append(True)
        else:
            expression = policy["jmespathExpression"]["expression"]
            decisions.append(jmespath.search(expression, {"authenticationMetadata": metadata}) is True)
    return decisions


issuer, audience = "https://issuer.example/", "https://build.example/"
jwks = {"issuer": issuer, "audience": audience, "allowedClientIds": ["bazel", "ci"]}
config = render(jwks, starter=True)
valid = {"iss": issuer, "aud": audience, "azp": "bazel"}
for claims in [valid, {**valid, "azp": "ci"}, {**valid, "aud": ["other", audience]}]:
    assert claims_match(config, claims), claims
    assert write_decisions(config, claims) == [True, True, True], claims
for claims in [
    None, {}, {"iss": issuer, "aud": audience},
    {**valid, "azp": "other"}, {**valid, "azp": None},
    {**valid, "azp": ["bazel"]}, {**valid, "azp": True},
    {**valid, "iss": "https://wrong.example/"},
    {**valid, "aud": "wrong"}, {**valid, "aud": ["wrong"]},
]:
    assert write_decisions(config, claims) == [False, False, False], claims
for store in ["contentAddressableStorage", "actionCache"]:
    assert config[store]["getAuthorizer"] == {"allow": {}}

# Clearing inherited raw overrides with null must behave like an empty map;
# neither replaces the generated frontend policy or invalidates client binding.
assert render(jwks, extra_values={"configOverrides": None}) == render(
    jwks, extra_values={"configOverrides": {}})

# Custom expressions must remain exactly true; wrapping a truthy scalar or
# object in `&& contains(...)` must never turn it into authorization.
custom = render({**jwks, "claimsValidationExpression": "payload.permitted"})
for permitted in [True, False, None, "true", "yes", 1, [True], {"yes": True}]:
    assert claims_match(custom, {"azp": "bazel", "permitted": permitted}) is (permitted is True)
assert not claims_match(custom, {"azp": "other", "permitted": True})

# Quoted identifiers must select the complete claim name, not traverse nested
# fields. Exercise the parser/evaluator after Helm and Jsonnet string escaping.
for claim_name in ["cid", "https://example.com/client_id", "client.id"]:
    named = render({**jwks, "clientIdClaim": claim_name})
    assert claims_match(named, {"iss": issuer, "aud": audience, claim_name: "bazel"})
    assert not claims_match(named, valid)
    assert not claims_match(named, {"iss": issuer, "aud": audience, "client": {"id": "bazel"}})

# Keep authentication and authorization independent for deployments that leave
# CAS uploads open but restrict action-cache writes and execution.
mixed = render(jwks, frontend={
    "actionCache": {"putAuthorizer": {"mode": "requireCanWriteToCache"}},
    "executeAuthorizer": {"mode": "requireCanWriteToCache"},
})
assert write_decisions(mixed, None) == [True, False, False]
assert write_decisions(mixed, {**valid, "azp": "other"}) == [True, False, False]
assert write_decisions(mixed, valid) == [True, True, True]

# Helm --reuse-values supplies the previous chart defaults, so newly added
# optional keys can be absent. Preserve unbound behavior for those releases,
# and use the default claim name when adding a binding during their upgrade.
with tempfile.TemporaryDirectory() as directory:
    legacy = pathlib.Path(directory) / "buildbarn"
    shutil.copytree(chart, legacy)
    values_file = legacy / "values.yaml"
    values = yaml.safe_load(values_file.read_text())
    values["frontend"]["jwks"].pop("allowedClientIds")
    values["frontend"]["jwks"].pop("clientIdClaim")
    values["scheduler"]["adminHttpServers"].pop("allowUnauthenticatedRoute")
    values_file.write_text(yaml.safe_dump(values))
    assert render({}, source_chart=legacy) == render({})
    legacy_bound = render(jwks, source_chart=legacy)
    assert claims_match(legacy_bound, valid)
    assert not claims_match(legacy_bound, {**valid, "azp": "other"})
    unsafe = subprocess.run([
        "helm", "template", "frontend-jwt", str(legacy),
        "--set", "routing.provider=gateway", "--set", "gateway.name=gw",
        "--set", "gateway.httpRoutes.rbeWeb.enabled=true",
    ], capture_output=True, text=True)
    assert unsafe.returncode != 0
    assert "an rbeWeb route would publish the scheduler admin UI" in unsafe.stderr

print("Frontend JWT claims and write authorization checks passed")
PY
