#!/usr/bin/env bash
# Validate policy values and schema, including explicit clearing and unique
# environment entries so a merge cannot silently overwrite the manager policy.
set -euo pipefail
chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$chart_dir" <<'PY'
from pathlib import Path
import subprocess
import sys

import yaml

chart_dir = Path(sys.argv[1])


def unique_mapping(pairs):
    result = {}
    for key, value in pairs:
        assert key not in result, f"duplicate environment variable: {key}"
        result[key] = value
    return result


def command(*args):
    return ["helm", "template", "bb-worker-operator", str(chart_dir),
            "--namespace", "hermetiq", "--show-only", "templates/deployment.yaml", *args]


def render(*args):
    doc = yaml.safe_load(subprocess.check_output(command(*args), text=True))
    spec = doc["spec"]["template"]["spec"]
    env = spec["containers"][0]["env"]
    by_name = unique_mapping((entry["name"], entry) for entry in env)
    assert by_name["POD_SERVICE_ACCOUNT"] == {
        "name": "POD_SERVICE_ACCOUNT",
        "valueFrom": {"fieldRef": {"fieldPath": "spec.serviceAccountName"}},
    }, "operator identity must follow the pod's actual ServiceAccount"
    return spec, by_name


def expect_policy(env, **expected):
    for name, value in expected.items():
        assert env[name] == {"name": name, "value": value}, (name, env[name], value)


# Keep main's existing default GKE pools valid and its preflight enabled.
spec, env = render()
assert spec["serviceAccountName"] == "bb-worker-operator"
expect_policy(env,
    ALLOWED_POD_SERVICE_ACCOUNTS="",
    ALLOW_PRIVILEGED_EXTRA_CONTAINERS="false",
    ALLOWED_HOST_PATH_PREFIXES="/mnt/stateful_partition/kube-ephemeral-ssd",
    ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS="",
)

# Empty lists and false must explicitly clear policy, not depend on image defaults.
_, env = render(
    "--set-json", "specPolicy.allowedPodServiceAccounts=[]",
    "--set", "specPolicy.allowPrivilegedExtraContainers=false",
    "--set-json", "specPolicy.allowedHostPathPrefixes=[]",
    "--set-json", "specPolicy.allowedClusterTriggerAuthentications=[]",
)
expect_policy(env,
    ALLOWED_POD_SERVICE_ACCOUNTS="", ALLOW_PRIVILEGED_EXTRA_CONTAINERS="false",
    ALLOWED_HOST_PATH_PREFIXES="", ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS="",
)

# Every configured environment variable must occur exactly once.
_, env = render(
    "--set-json", 'specPolicy.allowedPodServiceAccounts=["rbe-worker","default"]',
    "--set", "specPolicy.allowPrivilegedExtraContainers=true",
    "--set-json", 'specPolicy.allowedHostPathPrefixes=["/mnt/stateful_partition/kube-ephemeral-ssd","/var/cache/bb"]',
    "--set-json", 'specPolicy.allowedClusterTriggerAuthentications=["vm-auth"]',
)
expect_policy(env,
    ALLOWED_POD_SERVICE_ACCOUNTS="rbe-worker,default",
    ALLOW_PRIVILEGED_EXTRA_CONTAINERS="true",
    ALLOWED_HOST_PATH_PREFIXES="/mnt/stateful_partition/kube-ephemeral-ssd,/var/cache/bb",
    ALLOWED_CLUSTER_TRIGGER_AUTHENTICATIONS="vm-auth",
)

for name, args in [
    ("bbwo-manager", []),
    ("external-sa", ["--set", "serviceAccount.create=false"]),
]:
    spec, _ = render("--set", f"serviceAccount.name={name}", *args)
    assert spec["serviceAccountName"] == name

# The schema must retain the preflight switch and reject invalid policy values.
render("--set", "specPolicy.checkExistingRbeWorkers=false")
for args in [
    ["--set-json", 'specPolicy.allowedHostPathPrefixes=["relative/path"]'],
    ["--set-json", 'specPolicy.allowedPodServiceAccounts=["a,b"]'],
    ["--set-json", 'specPolicy.allowedPodServiceAccounts=["not a name"]'],
    ["--set-json", 'specPolicy.allowedClusterTriggerAuthentications=["bad/name"]'],
    ["--set", "specPolicy.allowedHostPathPrefix=/mnt"],
]:
    result = subprocess.run(command(*args), text=True, capture_output=True)
    assert result.returncode != 0, f"schema accepted invalid policy: {args}"
    assert "specPolicy" in result.stderr, result.stderr

print("spec policy defaults, schema, unique environment and overrides passed")
PY
