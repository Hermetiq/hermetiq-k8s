#!/usr/bin/env bash
# Evaluate the rendered Jsonnet: Helm rendering alone cannot catch missing
# imports or lexical-scope regressions when routing moves into its own file.
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${chart_dir}" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys
import tempfile

import _jsonnet
import yaml

chart = pathlib.Path(sys.argv[1])


def evaluate(values, ext_vars=None):
    with tempfile.TemporaryDirectory() as directory:
        directory = pathlib.Path(directory)
        overrides = directory / "values.yaml"
        overrides.write_text(yaml.safe_dump(values))
        output = subprocess.check_output(
            ["helm", "template", "scheduler-routing", str(chart),
             "-f", str(chart / "ci-values/ci.yaml"), "-f", str(overrides)],
            text=True,
        )
        config = next(
            obj["data"] for obj in yaml.safe_load_all(output)
            if obj and obj["kind"] == "ConfigMap"
            and obj["metadata"]["name"] == "buildbarn-config"
        )
        for name, content in config.items():
            (directory / name).write_text(content)
        return json.loads(_jsonnet.evaluate_file(
            str(directory / "scheduler.jsonnet"), ext_vars=ext_vars or {},
        ))


platform = [{"name": "pool", "value": "dedicated"}]
routers = [
    {"mode": "simple"},
    {
        "mode": "demultiplexing",
        "backends": [{"instanceNamePrefix": "project", "platform": {"properties": platform}}],
        "catchAll": {"platform": {"properties": [{"name": "pool", "value": "fallback"}]}},
    },
    {
        "mode": "custom",
        # Custom router bodies have always shared scheduler.jsonnet's `common`
        # import. Use it in an evaluated field to detect scope changes.
        "custom": """simple: {
          platformKeyExtractor: { action: {} },
          initialSizeClassAnalyzer: {
            defaultExecutionTimeout: std.toString(common.maximumMessageSizeBytes / 1024 / 1024) + 's',
            maximumExecutionTimeout: '7200s',
          },
        },""",
    },
]
# Object inheritance must also preserve references to scheduler-root fields;
# copying routing.actionRouter into another object loses this `$` context.
root_router = copy.deepcopy(routers[-1])
root_router["custom"] = root_router["custom"].replace("common.maximumMessageSizeBytes", "$.maximumMessageSizeBytes")
routers.append(root_router)
queue_sets = [[], [{"instanceNamePrefix": "project", "platform": platform, "sizeClasses": [1, 2]}]]

for router in routers:
    for queues in queue_sets:
        values = {
            "images": {"scheduler": {"repository": "example.com/bb-scheduler"}},
            "scheduler": {"actionRouter": router, "predeclaredPlatformQueues": queues},
        }
        inline = evaluate(values)
        reloading_values = copy.deepcopy(values)
        reloading_values["scheduler"]["configurationReloadInterval"] = "30s"
        reloading = evaluate(reloading_values)
        assert inline["actionRouter"] == reloading["actionRouter"], router["mode"]
        assert inline.get("predeclaredPlatformQueues", []) == reloading["predeclaredPlatformQueues"], router["mode"]
        assert reloading["configurationReloadInterval"] == "30s"
        if router["mode"] == "custom":
            analyzer = reloading["actionRouter"]["simple"]["initialSizeClassAnalyzer"]
            expected = str(inline["maximumMessageSizeBytes"] // 1024 // 1024) + "s"
            assert analyzer["defaultExecutionTimeout"] == expected

for pod_ip, endpoint_host in [("10.0.0.7", "10.0.0.7"), ("fd00::7", "[fd00::7]")]:
    for handover_port in [8985, 9999]:
        config = evaluate({
            "images": {"scheduler": {"repository": "example.com/bb-scheduler"}},
            "scheduler": {"handover": {
                "enabled": True,
                "port": handover_port,
                "coordinator": {"image": {
                    "repository": "example.com/bb-scheduler-coordinator", "tag": "test",
                }},
            }},
        }, ext_vars={"POD_NAME": "scheduler-test", "POD_IP": pod_ip})
        coordinator = config["coordinator"]
        assert coordinator["selfId"] == "scheduler-test"
        for field, port in [("selfClientEndpoint", 8982), ("selfWorkerEndpoint", 8983),
                            ("selfStateEndpoint", 8984), ("selfHandoverEndpoint", handover_port)]:
            assert coordinator[field] == f"{endpoint_host}:{port}", (pod_ip, field)

print("Scheduler Jsonnet routing equivalence and handover endpoint checks passed")
PY
