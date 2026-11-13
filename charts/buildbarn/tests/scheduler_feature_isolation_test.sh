#!/usr/bin/env bash
# Compare complete renders: dormant hooks must not change deployments, and
# enabling scheduler features must not roll storage, frontend, or workers.
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${chart_dir}" <<'PY'
import copy
import pathlib
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])


def render(values):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as overrides:
        yaml.safe_dump(values, overrides)
        overrides.flush()
        output = subprocess.check_output(
            ["helm", "template", "scheduler-isolation", str(chart),
             "--namespace", "buildbarn", "-f", str(chart / "ci-values/ci.yaml"),
             "-f", overrides.name], text=True,
        )
    return {
        (obj["kind"], obj["metadata"]["name"]): obj
        for obj in yaml.safe_load_all(output) if obj
    }


baseline = render({})
dormant = render({"scheduler": {
    "configurationReloadInterval": "",
    "handover": {
        "enabled": False,
        "peerServerName": "future-scheduler",
        "port": 9999,
        "terminationGracePeriodSeconds": 300,
        "coordinator": {"image": {
            "repository": "example.com/future-coordinator", "tag": "next",
        }},
    },
}})
assert baseline == dormant, "disabled scheduler hooks changed rendered resources"

config_key = ("ConfigMap", "buildbarn-config")
scheduler_key = ("Deployment", "scheduler-ubuntu22-04")
rbac_keys = {("ServiceAccount", "scheduler"), ("Role", "scheduler"),
             ("RoleBinding", "scheduler")}
queue = {"platform": [{"name": "pool", "value": "reload-test"}], "sizeClasses": [0]}

for reload_enabled, handover_enabled in [(True, False), (False, True), (True, True)]:
    values = {
        "images": {"scheduler": {"repository": "example.com/bb-scheduler"}},
        "scheduler": {
            "configurationReloadInterval": "30s" if reload_enabled else "",
            "handover": {
                "enabled": handover_enabled,
                "coordinator": {"image": {
                    "repository": "example.com/bb-scheduler-coordinator",
                    "tag": "v0.1.0",
                }},
            },
        },
    }
    enabled = render(values)
    expected_keys = set(baseline) | (rbac_keys if handover_enabled else set())
    assert set(enabled) == expected_keys, "unexpected feature resources"
    for key in set(baseline) - {config_key, scheduler_key}:
        assert baseline[key] == enabled[key], f"scheduler feature changed {key}"
    before_config = baseline[config_key]["data"]
    after_config = enabled[config_key]["data"]
    for name in before_config.keys() - {"scheduler.jsonnet"}:
        assert before_config[name] == after_config[name], f"feature changed {name}"
    assert ("scheduler-routing.libsonnet" in after_config) == reload_enabled

    updated_values = copy.deepcopy(values)
    updated_values["scheduler"]["predeclaredPlatformQueues"] = [queue]
    updated = render(updated_values)
    for key in set(enabled) - {config_key, scheduler_key}:
        assert enabled[key] == updated[key], f"queue change modified {key}"
    before_pod = enabled[scheduler_key]["spec"]["template"]
    after_pod = updated[scheduler_key]["spec"]["template"]
    assert (before_pod == after_pod) == reload_enabled, "incorrect queue rollout behavior"

print("Scheduler feature isolation and queue rollout checks passed")
PY
