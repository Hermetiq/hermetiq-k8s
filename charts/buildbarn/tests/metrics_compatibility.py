"""Evaluate the shipped queries, rather than copies of them, with promtool."""
import collections
import json
import pathlib
import re
import subprocess
import tempfile

import yaml


CHART = pathlib.Path(__file__).resolve().parent.parent
REPO = CHART.parent.parent
DASHBOARDS = REPO / "charts/hermetiq/files/dashboards"
FIXTURE = yaml.safe_load((CHART / "tests/testdata/metrics_compatibility.yaml").read_text())
RULES = yaml.safe_load((CHART / "files/vmrules/buildbarn-vmrules.yaml").read_text())


def selector(metric, labels):
    return metric + "{" + ",".join(f"{k}={json.dumps(str(v))}" for k, v in sorted(labels.items())) + "}"


def panels(items):
    for item in items:
        yield item
        yield from panels(item.get("panels", []))


def fixture_series(scenario):
    result = []

    def counter(metric, labels, rate):
        result.append({"series": selector(metric, labels), "values": f"0+{15 * rate}x20"})

    for store in scenario["stores"]:
        labels = {"namespace": scenario["name"], "instance": store["version"] + store["type"]}
        for metric in FIXTURE["key_location_metrics"]:
            klm_labels = dict(labels, **metric["labels"])
            if store["version"] == "cdc":
                klm_labels["name"] = "KeyLocationMap:" + store["type"]
            else:
                klm_labels["storage_type"] = store["type"]
            counter(metric[store["version"]], klm_labels, store["rate"])

        # Emit both local_block_device (storage) and grpc (client) backend_type
        # plus multiple histogram buckets so dropdown filters and heatmap `by (le)`
        # grouping are genuinely exercised.
        base_labels = dict(labels, storage_type=store["type"], kubernetes_service="storage")
        for backend_type, mult in (("local_block_device", 1), ("grpc", 0)):
            b_labels = dict(base_labels, backend_type=backend_type)
            for operation in ("Get", "Put"):
                operation_labels = dict(b_labels, operation=operation)
                counter("buildbarn_blobstore_blob_access_operations_blob_size_bytes_count", operation_labels, store["rate"] * mult)
                for le, frac in (("1024", 0.5), ("+Inf", 1.0)):
                    counter("buildbarn_blobstore_blob_access_operations_blob_size_bytes_bucket", dict(operation_labels, le=le), store["rate"] * mult * frac)
            for operation in ("Get", "Put", "FindMissing"):
                operation_labels = dict(b_labels, operation=operation, grpc_code="OK")
                counter("buildbarn_blobstore_blob_access_operations_duration_seconds_count", operation_labels, store["rate"] * mult)
                for le, frac in (("0.1", 0.5), ("+Inf", 1.0)):
                    counter("buildbarn_blobstore_blob_access_operations_duration_seconds_bucket", dict(operation_labels, le=le), store["rate"] * mult * frac)
            counter("buildbarn_blobstore_blob_access_operations_find_missing_batch_size_count", b_labels, store["rate"] * mult)
            for le, frac in (("16", 0.5), ("+Inf", 1.0)):
                counter("buildbarn_blobstore_blob_access_operations_find_missing_batch_size_bucket", dict(b_labels, le=le), store["rate"] * mult * frac)
        for service in ("storage", "worker"):
            retention_labels = dict(base_labels, backend_type="local_block_device", kubernetes_service=service, kubernetes_replica="0", kubernetes_shard="0")
            # Worker retention is intentionally different and must not affect
            # the storage-tier records, including the new CMS panels.
            result.append({"series": selector("buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds", retention_labels), "values": "0x20" if service == "storage" else "290x20"})

    # Generic lossy-map metrics also exist outside storage. They must not
    # appear as unlabelled storage data in the compatibility recording rules.
    for metric in FIXTURE["key_location_metrics"]:
        counter(metric["cdc"], dict(metric["labels"], namespace=scenario["name"], name="UnrelatedCache"), 1000)
    return result


def scalar_test(expr, expected):
    return {"expr": f"sum({expr}) or vector(0)", "eval_time": "5m", "exp_samples": [{"labels": "{}", "value": expected}]}


def expand(query, namespace):
    return query.replace("$namespace", namespace).replace("$cas_backend_type", "local_block_device").replace("$cms_backend_type", "local_block_device")


def dashboard_tests(scenario):
    tests = []
    for name in ("buildbarn/bb-storage.json", "buildbarn/bb-blobaccess.json", "hermetiq-demo.json"):
        dashboard = json.loads((DASHBOARDS / name).read_text())
        ids = [p["id"] for p in panels(dashboard["panels"])]
        assert len(ids) == len(set(ids)), f"duplicate panel IDs in {name}"
        # Within each row (and across hermetiq-demo), sibling panels must have distinct titles.
        if name == "hermetiq-demo.json":
            titles = [p.get("title", "") for p in panels(dashboard["panels"]) if p.get("type") != "row" and p.get("title")]
            assert len(titles) == len(set(titles)), f"duplicate panel titles in {name}: {[t for t in titles if titles.count(t) > 1]}"
        data_panels = mapping_panels = 0
        for panel in panels(dashboard["panels"]):
            title = panel.get("title", "")
            is_data = "legacy CAS" in title
            is_mapping = "CMS" in title
            data_panels += is_data
            mapping_panels += is_mapping
            for target in panel.get("targets", []):
                expr = target.get("expr", "")
                assert "put_ignored_invalid" not in expr, f"absent upstream metric queried by {name}: {title}"
                if not (is_data or is_mapping):
                    continue
                # Independent expected values: CMS must never leak into the
                # legacy CAS/CS graphs, and legacy-only installs keep working.
                expected = scenario["expected_data_rate"] if is_data else scenario["expected_mapping_rate"]
                expanded = expand(expr, scenario["name"])
                if "last_removed_old_block" in expr:
                    stores = scenario["expected_data_stores"] if is_data else int(expected > 0)
                    expected = 300 * stores
                elif "_bucket:" in expr:
                    # Two histogram buckets (finite + +Inf): verify both sum and distinct `le` preservation.
                    expected = expected * 1.5 if "key_location_map" not in expr else expected
                    if expected > 0 and "key_location_map" not in expr:
                        tests.append(scalar_test(f"count(count by (le) ({expanded}))", 2))
                elif "operations_started" in expr or "duration_seconds_count" in expr:
                    # Get, Put, FindMissing are separate output series.
                    expected *= 3
                tests.append(scalar_test(expanded, expected))
                # Verify legend labels referenced by legendFormat actually exist on non-empty output series.
                legend = target.get("legendFormat", "")
                for lbl in re.findall(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}", legend):
                    if expected > 0:
                        tests.append(scalar_test(f"count(count by ({lbl}) ({expanded})) > bool 0", 1))
        assert data_panels >= 5 and data_panels == mapping_panels, f"missing CS/CMS panels in {name}"
        for variable in dashboard.get("templating", {}).get("list", []):
            if variable["name"] not in ("cas_backend_type", "cms_backend_type"):
                continue
            query = variable["query"]
            if isinstance(query, dict):
                query = query["query"]
            match = re.fullmatch(r"label_values\((.*), backend_type\)", query)
            assert match, query
            expected = 2 if variable["name"] == "cas_backend_type" or scenario["expected_mapping_rate"] else 0
            expr = f"count(count by (backend_type) ({expand(match.group(1), scenario['name'])}))"
            tests.append(scalar_test(expr, expected))
    return tests


def alert_tests():
    # Prove all three shipped Buildbarn storage alerts fire for CDC cs and cms series.
    input_series = [
        {
            "series": selector("buildbarn_lossymap_hash_map_put_too_many_iterations_total", {"namespace": "alerts", "instance": "s0", "name": "KeyLocationMap:cs"}),
            "values": "0+15x140",
        },
        {
            "series": selector("buildbarn_lossymap_hash_map_put_too_many_iterations_total", {"namespace": "alerts", "instance": "s0", "name": "KeyLocationMap:cms"}),
            "values": "0+15x140",
        },
        {
            "series": selector("buildbarn_lossymap_hash_map_get_too_many_attempts_total", {"namespace": "alerts", "instance": "s0", "name": "KeyLocationMap:cs"}),
            "values": "0+15x140",
        },
        {
            "series": selector("buildbarn_lossymap_hash_map_get_too_many_attempts_total", {"namespace": "alerts", "instance": "s0", "name": "KeyLocationMap:cms"}),
            "values": "0+15x140",
        },
        {
            "series": selector("buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds", {
                "namespace": "alerts", "kubernetes_service": "storage", "kubernetes_replica": "0", "kubernetes_shard": "0", "storage_type": "cs",
            }),
            "values": "0x140",
        },
        {
            "series": selector("buildbarn_blobstore_old_current_new_location_blob_map_last_removed_old_block_insertion_time_seconds", {
                "namespace": "alerts", "kubernetes_service": "storage", "kubernetes_replica": "0", "kubernetes_shard": "0", "storage_type": "cms",
            }),
            "values": "0x140",
        },
        # Storage pod uptime > 86400s (start time = -100000s) so BuildbarnCacheRetentionLow is not suppressed.
        {
            "series": selector("process_start_time_seconds", {"namespace": "alerts", "kubernetes_service": "storage"}),
            "values": "-100000x140",
        },
    ]
    return {
        "name": "cdc-alerts",
        "interval": "15s",
        "input_series": input_series,
        "alert_rule_test": [
            {
                "eval_time": "20m",
                "alertname": "BuildbarnKeyLocationMapPutsDropped",
                "exp_alerts": [
                    {
                        "exp_labels": {"namespace": "alerts", "storage_type": st, "severity": "warning"},
                        "exp_annotations": {
                            "summary": f"Buildbarn {st} key-location map is dropping writes",
                            "description": f"Put() on the {st} store exhausted its iteration budget — the key-location map is undersized relative to the blocks it fronts; newly written blobs are unreachable.",
                        },
                    }
                    for st in ("cs", "cms")
                ],
            },
            {
                "eval_time": "20m",
                "alertname": "BuildbarnKeyLocationMapGetsExhausted",
                "exp_alerts": [
                    {
                        "exp_labels": {"namespace": "alerts", "storage_type": st, "severity": "warning"},
                        "exp_annotations": {
                            "summary": f"Buildbarn {st} key-location map lookups hit the attempt limit",
                            "description": f"Get() on the {st} store exceeded its probe budget, returning NOT_FOUND for objects that may exist — the key-location map is over-utilized; grow it.",
                        },
                    }
                    for st in ("cs", "cms")
                ],
            },
            {
                "eval_time": "32m",
                "alertname": "BuildbarnCacheRetentionLow",
                "exp_alerts": [
                    {
                        "exp_labels": {"namespace": "alerts", "kubernetes_shard": "0", "storage_type": st, "severity": "warning"},
                        "exp_annotations": {
                            "summary": f"Buildbarn alerts/{st} shard 0 retains data for under 24h",
                            "description": f"The youngest block evicted from the {st} store on shard 0 in namespace alerts was inserted less than 24h ago — the store cycles too fast for its workload; grow the blocks volume and the key-location map together.",
                        },
                    }
                    for st in ("cs", "cms")
                ],
            },
        ],
    }


def main():
    tests = []
    for scenario in FIXTURE["scenarios"]:
        query_tests = []
        expected = collections.Counter()
        for store in scenario["stores"]:
            expected[store["type"]] += store["rate"]
        for metric in FIXTURE["key_location_metrics"]:
            record = metric["record"]
            for storage_type, rate in expected.items():
                query_tests.append(scalar_test(selector(record, {"namespace": scenario["name"], "storage_type": storage_type}), rate))
            # The namespace-wide total also detects non-KeyLocationMap series
            # or accidental duplicate counting during a mixed deployment.
            query_tests.append(scalar_test(selector(record, {"namespace": scenario["name"]}), sum(expected.values())))
        query_tests.extend(dashboard_tests(scenario))
        tests.append({"name": scenario["name"], "interval": "15s", "input_series": fixture_series(scenario), "promql_expr_test": query_tests})
    tests.append(alert_tests())
    with tempfile.TemporaryDirectory(prefix="buildbarn-metrics-") as directory:
        directory = pathlib.Path(directory)
        (directory / "rules.yaml").write_text(yaml.safe_dump({"groups": RULES["spec"]["groups"]}, sort_keys=False))
        (directory / "tests.yaml").write_text(yaml.safe_dump({"rule_files": ["rules.yaml"], "evaluation_interval": "15s", "tests": tests}, sort_keys=False))
        subprocess.run(["promtool", "test", "rules", "tests.yaml"], cwd=directory, check=True)
    expr_count = sum(len(t.get("promql_expr_test", [])) for t in tests)
    alert_count = sum(len(t.get("alert_rule_test", [])) for t in tests)
    print(f"Validated {expr_count} recording-rule/dashboard queries and {alert_count} alert rules across legacy, CDC, and mixed fixtures")


if __name__ == "__main__":
    main()
