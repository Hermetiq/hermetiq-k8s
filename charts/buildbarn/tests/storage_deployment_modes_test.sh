#!/usr/bin/env bash
# Exercise the two-release storage handoff, including ownership and validation.
set -euo pipefail
python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" <<'PY'
import copy
import os
import pathlib
import subprocess
import sys
import tempfile

import yaml

chart = pathlib.Path(sys.argv[1])


def render(values=None, error=None):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as overrides:
        yaml.safe_dump(values or {}, overrides)
        overrides.flush()
        result = subprocess.run(
            ["helm", "template", "test", str(chart), "--namespace", "buildbarn",
             "-f", overrides.name], text=True, capture_output=True,
            env=dict(os.environ, KUBECONFIG="/dev/null"),
        )
    if error:
        assert result.returncode and error in result.stderr, result.stderr
        return
    assert result.returncode == 0, result.stderr
    documents = [doc for doc in yaml.safe_load_all(result.stdout) if doc]
    objects = {(doc["kind"], doc["metadata"]["name"]): doc for doc in documents}
    assert len(objects) == len(documents), "duplicate object identity"
    return objects


blue = render()
assert ("StatefulSet", "storage") in blue
assert ("Service", "storage") in blue
assert ("ConfigMap", "buildbarn-config") in blue
assert ("ConfigMap", "buildbarn-worker-config") in blue

spread = [{
    "maxSkew": 1, "topologyKey": "topology.kubernetes.io/zone",
    "whenUnsatisfiable": "DoNotSchedule",
    "labelSelector": {"matchLabels": {"app": "storage-cdc"}},
}]
green_values = {
    "deploymentMode": "storage-only",
    "storage": {"name": "storage-cdc", "replicas": 3,
                "networkPolicy": {"enabled": True},
                "topologySpreadConstraints": spread},
    # These features and existing legacy workers belong to the main release.
    # They must neither render resources nor block staging green storage.
    "createNamespace": True,
    "remoteAsset": {"enabled": True}, "portal": {"enabled": True},
    "scheduler": {"handover": {"enabled": True}, "actionRouter": {"mode": "invalid"}},
    "frontend": {"grpcCacheProxy": {"cacheEvents": {"trackingMode": "invalid"}}},
    "images": {"worker": {"tag": "20260908T142432Z-77f7642"}},
    "config": {"blobstore": {"deadlineEnforcing": {"timeout": "unused"}},
               "contentAddressableStorage": {"cdcParameterCache": {"cacheSize": 0}}},
    "configOverrides": {"frontend.jsonnet": "{ contentAddressableStorage: {} }"},
    "extraObjects": [{"apiVersion": "v1", "kind": "ConfigMap",
                      "metadata": {"name": "full-release-only"}}],
    "_testLookup": {
        "rbeWorkers": {"items": [{"metadata": {"name": "legacy"}, "spec": {
            "images": {"worker": "ghcr.io/buildbarn/bb-worker:20260908T142432Z-77f7642"},
        }}]},
        "statefulSets": {"items": [{"metadata": {"name": "storage"}, "spec": {
            "volumeClaimTemplates": [{"metadata": {"name": "legacy"}}],
        }}]},
    },
}
green = render(green_values)
assert set(green) == {
    ("ConfigMap", "storage-cdc-config"), ("StatefulSet", "storage-cdc"),
    ("Service", "storage-cdc"), ("PodDisruptionBudget", "storage-cdc"),
    ("NetworkPolicy", "storage-cdc"), ("VMPodScrape", "storage-cdc-vmpodscrape"),
}, set(green)
assert not set(blue) & set(green), "green must not take ownership of blue objects"
config = green[("ConfigMap", "storage-cdc-config")]["data"]
assert set(config) == {"common.libsonnet", "storage.jsonnet"}
sts = green[("StatefulSet", "storage-cdc")]
assert sts["spec"]["replicas"] == 3
assert sts["spec"]["serviceName"] == "storage-cdc"
assert sts["spec"]["selector"]["matchLabels"] == {"app": "storage-cdc"}
pod = sts["spec"]["template"]
assert pod["metadata"]["labels"]["app"] == "storage-cdc"
assert pod["metadata"]["labels"]["kubernetes_service"] == "storage"
assert pod["spec"]["topologySpreadConstraints"] == spread
anti_affinity = pod["spec"]["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]
assert anti_affinity[0]["labelSelector"]["matchLabels"] == {"app": "storage-cdc"}
assert next(v for v in pod["spec"]["volumes"] if v["name"] == "configs")["configMap"]["name"] == "storage-cdc-config"
# Absence uses Kubernetes' Retain defaults for both deletion and scale-down.
assert "persistentVolumeClaimRetentionPolicy" not in sts["spec"]
assert sts["spec"]["volumeClaimTemplates"] == blue[("StatefulSet", "storage")]["spec"]["volumeClaimTemplates"]
assert green[("Service", "storage-cdc")]["spec"]["selector"] == {"app": "storage-cdc"}
assert green[("Service", "storage-cdc")]["spec"]["clusterIP"] == "None"
assert green[("PodDisruptionBudget", "storage-cdc")]["spec"]["selector"]["matchLabels"] == {"app": "storage-cdc"}
assert green[("NetworkPolicy", "storage-cdc")]["spec"]["podSelector"]["matchLabels"] == {"app": "storage-cdc"}
scrape = green[("VMPodScrape", "storage-cdc-vmpodscrape")]
assert scrape["spec"]["selector"]["matchLabels"] == {"app": "storage-cdc"}
assert scrape["metadata"]["labels"]["app.kubernetes.io/component"] == "storage"
assert scrape["spec"]["podMetricsEndpoints"][0]["relabelConfigs"][0]["targetLabel"] == "kubernetes_shard"

cutover_values = {"storage": {"enabled": False, "name": "storage-cdc", "replicas": 3,
                              "persistence": {"mode": "unused"}},
                  "configOverrides": {"storage.jsonnet": "{ contentAddressableStorage: {} }"},
                  "_testLookup": {"statefulSets": {"items": [{
                      "metadata": {"name": "storage-cdc", "annotations": {
                          "meta.helm.sh/release-name": "buildbarn-storage-cdc",
                          "meta.helm.sh/release-namespace": "buildbarn"}},
                      "spec": {
                          "replicas": 3,
                          "volumeClaimTemplates": [{"metadata": {"name": "different"}}],
                      },
                  }]}}}
cutover = render(cutover_values)
assert not set(green) & set(cutover), "main must not manage green objects"
for kind in ("StatefulSet", "Service", "PodDisruptionBudget", "NetworkPolicy"):
    assert (kind, "storage") not in cutover
assert ("VMPodScrape", "storage-vmpodscrape") not in cutover
assert "storage.jsonnet" not in cutover[("ConfigMap", "buildbarn-config")]["data"]
for name in ("buildbarn-config", "buildbarn-worker-config"):
    common = cutover[("ConfigMap", name)]["data"]["common.libsonnet"]
    for ordinal in range(3):
        assert f"storage-cdc-{ordinal}.storage-cdc.buildbarn:8981" in common
    assert "storage-0.storage." not in common
for name in ("frontend", "scheduler-ubuntu22-04", "browser"):
    old = blue[("Deployment", name)]["spec"]["template"]["metadata"]["annotations"]["checksum/config"]
    new = cutover[("Deployment", name)]["spec"]["template"]["metadata"]["annotations"]["checksum/config"]
    assert old != new, f"{name} must reload its new storage target"

# Claim preflight follows the managed name; it must still reject changes to green.
changed = copy.deepcopy(green_values)
changed["_testLookup"]["statefulSets"]["items"][0]["metadata"]["name"] = "storage-cdc"
render(changed, error="live StatefulSet buildbarn/storage-cdc has different volumeClaimTemplates")
render({"deploymentMode": "storage-only", "storage": {"enabled": False}}, error="storage")
render({"deploymentMode": "unknown"}, error="deploymentMode")
for name in ("", "bad.name", "-invalid", "a" * 64):
    render({"storage": {"name": name}}, error="name")
render({"storage": {"replicas": 0}}, error="replicas")
render({"storage": {"enabled": False}, "configOverrides": {"common.libsonnet": "{}"}},
       error='configOverrides["common.libsonnet"]')
render({"deploymentMode": "storage-only", "images": {"storage": {"tag": "20260908T142448Z-db62041"}}},
       error="images.storage pins pre-CDC image")
# The main upgrade still checks old workers even after storage moves to another release.
render({"storage": {"enabled": False}, "_testLookup": green_values["_testLookup"]},
       error="pre-CDC image")
# --reuse-values replaces chart defaults with the old release's values, which
# have no storage.enabled. A missing key must keep storage, not delete it.
reused = render({"storage": {"enabled": None}})
for kind in ("StatefulSet", "Service", "PodDisruptionBudget"):
    assert (kind, "storage") in reused, f"missing storage.enabled dropped {kind}"
assert ("VMPodScrape", "storage-vmpodscrape") in render(
    {"storage": {"enabled": None}, "vmPodScrapes": {"enabled": True}})
assert "storage.jsonnet" in reused[("ConfigMap", "buildbarn-config")]["data"]

# hostPath stores use fixed node paths, so a second ring could share disks.
render({"deploymentMode": "storage-only", "storage": {"name": "storage-cdc",
        "persistence": {"mode": "hostPath"}}}, error="does not support storage.persistence.mode=hostPath")

# External-storage preflight: target must exist, belong to another release and
# match storage.replicas. An offline render has no list result and passes.
render({"storage": {"enabled": False, "name": "storage-cdc"}})
def external(items, **storage):
    return {"storage": {"enabled": False, "name": "storage-cdc", "replicas": 3, **storage},
            "_testLookup": {"statefulSets": {"items": items}}}
def sts(name="storage-cdc", release="buildbarn-storage-cdc", **spec):
    return {"metadata": {"name": name, "annotations": {
        "meta.helm.sh/release-name": release, "meta.helm.sh/release-namespace": "buildbarn"}},
        "spec": spec}
render(external([]), error="StatefulSet buildbarn/storage-cdc, which does not exist")
render(external([sts(name="storage", release="test", replicas=3)]),
       error="StatefulSet buildbarn/storage-cdc, which does not exist")
render(external([sts(release="test", replicas=3)]), error="which this release (test) owns")
render(external([sts(replicas=4)]), error="storage.replicas is 3 but StatefulSet buildbarn/storage-cdc is set to 4")
render(external([sts()]), error="is set to 1 replicas")
render(external([sts(name="storage", release="test", replicas=3)]) | {
    "storage": {"enabled": False, "replicas": 3}}, error="which this release (test) owns")
render(external([{"metadata": {"name": "storage-cdc"}, "spec": {"replicas": 3}}]))
render(external([sts(replicas=3)]))
render(external([]) | {"upgradeChecks": {"skipExternalStorageCheck": True}})
print("PASS storage-only staging, external-storage cutover, selectors, rollouts and preflights")
PY
