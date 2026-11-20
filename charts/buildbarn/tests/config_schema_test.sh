#!/usr/bin/env bash
# Evaluate every rendered Buildbarn Jsonnet config across default values,
# optional feature flags, and all custom-values/buildbarn-values-*.yaml files,
# and validate the evaluated JSON against the Buildbarn protobuf
# FileDescriptorSets (buildbarn_descriptors_cdc.pb for CDC services,
# buildbarn_descriptors.pb for legacy bb-browser), using the official protobuf
# JSON parser. Fork scheduler modes have their own pinned descriptor fixture.
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "${chart_dir}" <<'PY'
import pathlib
import json
import subprocess
import sys
import tempfile

import _jsonnet
import yaml
from google.protobuf import descriptor_pb2, descriptor_pool, json_format, message_factory

chart = pathlib.Path(sys.argv[1])
repo_root = chart.parent.parent
testdata = chart / "tests" / "testdata"

def load_descriptor_set(path):
    descriptors = descriptor_pb2.FileDescriptorSet.FromString(path.read_bytes())
    files = {file.name: file for file in descriptors.file}
    pool = descriptor_pool.DescriptorPool()
    loaded = set()
    visiting = set()

    def add_file(name):
        if name in loaded:
            return
        if name in visiting:
            raise AssertionError(f"{path.name}: cyclic protobuf import {name}")
        visiting.add(name)
        file = files[name]
        for dependency in file.dependency:
            add_file(dependency)
        pool.AddSerializedFile(file.SerializeToString())
        visiting.remove(name)
        loaded.add(name)

    for name in files:
        add_file(name)
    return pool


def validate_message(fqn, obj, registry, path=""):
    descriptor = registry.FindMessageTypeByName(fqn)
    # Debian bookworm ships protobuf 3.21; newer protobuf releases replaced
    # MessageFactory.GetPrototype with the module-level GetMessageClass API.
    if hasattr(message_factory, "GetMessageClass"):
        message_class = message_factory.GetMessageClass(descriptor)
    else:
        message_class = message_factory.MessageFactory(registry).GetPrototype(descriptor)
    try:
        json_format.ParseDict(
            obj, message_class(), descriptor_pool=registry, ignore_unknown_fields=False,
        )
    except (json_format.ParseError, ValueError) as exc:
        raise AssertionError(f"{path or fqn}: {exc}") from exc


# See testdata/schema-descriptors.md for immutable source commits and the
# fork fixture regeneration command. The base descriptors are the exact bytes
# copied from cloud-native's pre-CDC / CDC schemas, not locally edited schemas.
# The fork fixture compiles its pinned source against the same CDC imports.
import hashlib
EXPECTED_DESCRIPTOR_SHA256 = {
    "buildbarn_descriptors.pb": "3c7760bcddbc0516efdfc33f667a5e2c2382e461dac91713d87bfdeeaab60aa0",
    "buildbarn_descriptors_cdc.pb": "e08e0b969d71f8dd41f52063de2e252a9ac77c85a5e3681d62109ab20f73b5b4",
    "scheduler_fork_descriptors.pb": "91a82d605600f25e8cb67d7cd49f098472a9f789465d56ce9528893c9eecc7c2",
    "bb_scheduler_fork.proto": "aa2512178031613eb7eeaa4830b90b4d56aabfae6566a1a35913124c5dd43faf",
}
for name, expected in EXPECTED_DESCRIPTOR_SHA256.items():
    actual = hashlib.sha256((testdata / name).read_bytes()).hexdigest()
    if actual != expected:
        raise AssertionError(
            f"tests/testdata/{name} has sha256 {actual}, expected {expected}; follow "
            "testdata/schema-descriptors.md and update EXPECTED_DESCRIPTOR_SHA256"
        )

cdc_registry = load_descriptor_set(testdata / "buildbarn_descriptors_cdc.pb")
pre_cdc_registry = load_descriptor_set(testdata / "buildbarn_descriptors.pb")
fork_registry = load_descriptor_set(testdata / "scheduler_fork_descriptors.pb")

CONFIG_SPECS = {
    "storage.jsonnet": (
        "buildbarn.configuration.bb_storage.ApplicationConfiguration",
        cdc_registry,
    ),
    "frontend.jsonnet": (
        "buildbarn.configuration.bb_storage.ApplicationConfiguration",
        cdc_registry,
    ),
    "scheduler.jsonnet": (
        "buildbarn.configuration.bb_scheduler.ApplicationConfiguration",
        cdc_registry,
    ),
    "portal.jsonnet": (
        "buildbarn.configuration.bb_portal.ApplicationConfiguration",
        cdc_registry,
    ),
    "asset.jsonnet": (
        "buildbarn.configuration.bb_remote_asset.ApplicationConfiguration",
        cdc_registry,
    ),
    "browser.jsonnet": (
        "buildbarn.configuration.bb_browser.ApplicationConfiguration",
        pre_cdc_registry,
    ),
}

# Sanity check: ensure our validator catches unknown/removed pre-CDC fields on CDC messages.
try:
    validate_message(
        "buildbarn.configuration.bb_storage.ApplicationConfiguration",
        {
            "contentAddressableStorageServer": {
                "contentAddressableStorage": {
                    "chunkStorage": {
                        "local": {
                            "blocksOnBlockDevice": {
                                "dataIntegrityValidationCache": {"cacheSize": 1000}
                            }
                        }
                    }
                }
            }
        },
        cdc_registry,
    )
except AssertionError as exc:
    assert "dataIntegrityValidationCache" in str(exc), exc
else:
    raise AssertionError("validator failed to reject removed field dataIntegrityValidationCache")


def expect_invalid(label, fqn, value, expected_error, registry=cdc_registry):
    try:
        validate_message(fqn, value, registry, label)
    except AssertionError as exc:
        assert expected_error in str(exc), exc
    else:
        raise AssertionError(f"{label}: invalid protobuf JSON was accepted")


# Negative controls exercise semantics the previous handwritten parser missed.
expect_invalid(
    "unknown-null-field", "buildbarn.configuration.bb_storage.ApplicationConfiguration",
    {"contentAddressableStorage": None}, "contentAddressableStorage",
)
expect_invalid(
    "conflicting-backends", "buildbarn.configuration.blobstore.BlobAccessConfiguration",
    {"grpc": {"client": {"address": "storage:8981"}}, "local": {}}, "oneof",
)
expect_invalid("invalid-duration", "google.protobuf.Duration", "garbage", "Duration")
expect_invalid(
    "integer-overflow", "buildbarn.configuration.bb_storage.ApplicationConfiguration",
    {"maximumMessageSizeBytes": 2**80}, "maximumMessageSizeBytes",
)
# CDC CAS fields must not be placed under the old single-store configuration.
expect_invalid(
    "cdc-in-legacy-blobstore", "buildbarn.configuration.blobstore.BlobAccessConfiguration",
    {"chunkStorage": {}, "chunkMappingStorage": {}}, "chunkStorage",
)
expect_invalid(
    "legacy-cas-on-cdc-fork", "buildbarn.configuration.bb_scheduler.ApplicationConfiguration",
    {"legacyContentAddressableStorage": {"chunkStorage": {}}},
    "legacyContentAddressableStorage", registry=fork_registry,
)
print("PASS protobuf negative controls")


def render_and_validate(label, value_files=(), inline_overrides=None, scheduler_registry=None, expected_files=None):
    with tempfile.TemporaryDirectory() as tmpdir:
        tmpdir = pathlib.Path(tmpdir)
        cmd = ["helm", "template", "buildbarn", str(chart), "--namespace", "buildbarn"]
        for vf in value_files:
            cmd.extend(["-f", str(vf)])
        if inline_overrides:
            override_path = tmpdir / "overrides.yaml"
            override_path.write_text(yaml.safe_dump(inline_overrides))
            cmd.extend(["-f", str(override_path)])
        output = subprocess.check_output(cmd, text=True)
        config_data = next(
            obj["data"]
            for obj in yaml.safe_load_all(output)
            if obj
            and obj.get("kind") == "ConfigMap"
            and obj.get("metadata", {}).get("name") == "buildbarn-config"
        )
        for name, content in config_data.items():
            (tmpdir / name).write_text(content)

        validated = {}
        ext_vars = {
            "POD_NAME": "pod-0",
            "POD_IP": "10.0.0.1",
            "DB_CONNECTION_STRING": "postgres://buildbarn:secret@postgres:5432/buildbarn",
            "K8S_LOCAL_NODE_IP": "10.0.0.2",
            "SERVICE_NAME": "bb-service",
            "POD_NAMESPACE": "buildbarn",
        }
        for filename, (fqn, reg) in CONFIG_SPECS.items():
            if filename not in config_data:
                continue
            rendered_json = json.loads(
                _jsonnet.evaluate_file(str(tmpdir / filename), ext_vars=ext_vars)
            )
            if filename == "scheduler.jsonnet" and scheduler_registry is not None:
                reg = scheduler_registry
            validate_message(fqn, rendered_json, reg, f"{label}:{filename}")
            validated[filename] = rendered_json
        required = set(expected_files or ("storage.jsonnet", "frontend.jsonnet", "scheduler.jsonnet", "browser.jsonnet"))
        missing = required - set(validated)
        assert not missing, f"{label}: missing expected jsonnet files {sorted(missing)} (validated: {sorted(validated)})"
        print(f"PASS {label}: {', '.join(validated)}")
        return validated


ci_values = chart / "ci-values" / "ci.yaml"

# 1. Default values (with ci-values image repository fixtures)
defaults = render_and_validate("defaults", value_files=[ci_values])
for name in ("initialSizeClassCache", "fileSystemAccessCache"):
    assert "persistent" in defaults["storage.jsonnet"][name]["backend"]["local"], name
assert "initialSizeClassCache" not in defaults["scheduler.jsonnet"], "scheduler analysis remains opt-in"
disabled = render_and_validate(
    "explicitly-disabled-history-stores", value_files=[ci_values],
    inline_overrides={"storage": {"persistence": {
        "iscc": {"enabled": False}, "fsac": {"enabled": False},
    }}},
)
for name in ("initialSizeClassCache", "fileSystemAccessCache"):
    assert name not in disabled["storage.jsonnet"], name

# 2. All optional components and storage backends enabled
render_and_validate(
    "all-features-shared-cas",
    value_files=[ci_values],
    inline_overrides={
        "portal": {"enabled": True},
        "remoteAsset": {"enabled": True},
        "storage": {
            "persistence": {
                "iscc": {"enabled": True},
                "fsac": {"enabled": True},
                "cms": {"backend": "sharedCas"},
            }
        },
        "frontend": {"readCache": {"enabled": True}},
        "config": {"blobstore": {"deadlineEnforcing": {"timeout": "60s"}}},
    },
    expected_files=("storage.jsonnet", "frontend.jsonnet", "scheduler.jsonnet", "browser.jsonnet", "portal.jsonnet", "asset.jsonnet"),
)

# 3. Dedicated CMS filesystem PVC mode
render_and_validate(
    "cms-filesystem-pvc",
    value_files=[ci_values],
    inline_overrides={
        "portal": {"enabled": True},
        "remoteAsset": {"enabled": True},
        "storage": {
            "persistence": {
                "cms": {"backend": "filesystem", "size": "10Gi"},
            }
        },
    },
    expected_files=("storage.jsonnet", "frontend.jsonnet", "scheduler.jsonnet", "browser.jsonnet", "portal.jsonnet", "asset.jsonnet"),
)

# 4. Dedicated CMS raw block-device PVC mode (both inMemory and file KLM)
render_and_validate(
    "cms-block-device-pvc",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cms": {"backend": "blockDevice", "blockDevice": {"size": "10Gi", "keyLocationMap": "inMemory"}},
            }
        },
    },
)
render_and_validate(
    "cms-block-device-file-klm",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cms": {
                    "backend": "blockDevice",
                    "blockDevice": {"size": "10Gi", "keyLocationMap": "file"},
                },
            }
        },
    },
)

# 5. Raw CAS with persistent file-backed KLM + sharedCas CMS
raw_file_configs = render_and_validate(
    "raw-cas-file-klm-shared-cms",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cas": {"backend": "blockDevice", "blockDevice": {"keyLocationMap": "file"}},
                "cms": {"backend": "sharedCas"},
            }
        },
    },
)
raw_cas = raw_file_configs["storage.jsonnet"]["contentAddressableStorageServer"]["contentAddressableStorage"]
assert raw_cas["chunkStorage"]["local"]["keyLocationMap"]["onBlockDevice"]["file"]["path"] == "/storage-cas-meta/cdc-v1/keys.db"
assert raw_cas["chunkMappingStorage"]["local"]["keyLocationMap"]["onBlockDevice"]["file"]["path"] == "/storage-cas-meta/cdc-v1/cms-keys.db"
assert raw_cas["chunkMappingStorage"]["local"]["persistent"]["stateDirectoryPath"] == "/storage-cas-meta/cdc-v1/cms_persistent_state"

# 6. Raw CAS without a filesystem mount uses the actual in-memory CMS fallback.
# cas.enabled/ac.enabled are not chart settings: the old "in-memory" scenario
# set those ignored keys and only retested the default filesystem configuration.
memory_configs = render_and_validate(
    "raw-cas-in-memory-cms",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cas": {"backend": "blockDevice", "blockDevice": {"keyLocationMap": "inMemory"}},
                "cms": {"backend": "sharedCas", "keyLocationMap": {"type": "inMemory"}},
            }
        },
    },
)
cas = memory_configs["storage.jsonnet"]["contentAddressableStorageServer"]["contentAddressableStorage"]
assert cas["chunkStorage"]["local"]["blocksOnBlockDevice"]["source"]["devicePath"] == "/dev/bb/cas"
cms = cas["chunkMappingStorage"]["local"]
assert "blocksInMemory" in cms and "blocksOnBlockDevice" not in cms, cms
assert "inMemory" in cms["keyLocationMap"] and "persistent" not in cms, cms

# Assert persistence on evaluated stores, not just strings in a manifest. These
# cases deliberately omit the persistent overlay and all KLM selectors so a
# default regression (including a volatile shared CMS) cannot hide behind one.
def storage_stores(configs):
    storage = configs["storage.jsonnet"]
    cas = storage["contentAddressableStorageServer"]["contentAddressableStorage"]
    stores = {
        "cas": cas["chunkStorage"]["local"],
        "cms": cas["chunkMappingStorage"]["local"],
        "ac": storage["actionCache"]["backend"]["local"],
    }
    for name, field in (("iscc", "initialSizeClassCache"), ("fsac", "fileSystemAccessCache")):
        if field in storage:
            stores[name] = storage[field]["backend"]["local"]
    return stores


def assert_persistent_stores(configs):
    stores = storage_stores(configs)
    assert set(stores) == {"cas", "cms", "ac", "iscc", "fsac"}, stores.keys()
    for name, store in stores.items():
        assert "onBlockDevice" in store["keyLocationMap"], (name, store)
        assert "persistent" in store and "blocksOnBlockDevice" in store, (name, store)
        assert "blocksInMemory" not in store, (name, store)


for mode in ("pvc", "hostPath"):
    for dedicated_cms in (False, True):
        persistence = {"mode": mode}
        names = ["cas", "ac", "iscc", "fsac"]
        if dedicated_cms:
            names.append("cms")
        for name in names:
            store = {"backend": "blockDevice"}
            if name in ("iscc", "fsac"):
                store["enabled"] = True
            if mode == "hostPath":
                store["blockDevice"] = {
                    "hostPath": {"devicePath": f"/dev/ephemeral/{name}"},
                    "metadata": {"hostPath": {"path": f"/mnt/buildbarn/{name}-meta"}},
                }
            persistence[name] = store
        if mode == "hostPath":
            persistence["blockDevice"] = {"allowHostPath": True}
        overrides = {"storage": {"persistence": persistence}}
        label = f"persistent-raw-defaults-{mode}-{'dedicated' if dedicated_cms else 'shared'}-cms"
        rendered = render_and_validate(label, value_files=[ci_values], inline_overrides=overrides)
        assert_persistent_stores(rendered)

        # The actual opt-out file must remove checkpoint recovery from every
        # store, and does not require metadata paths even on node-local devices.
        if mode == "hostPath":
            for name in names:
                del persistence[name]["blockDevice"]["metadata"]
        ephemeral = render_and_validate(
            f"ephemeral-{label}",
            value_files=[ci_values, repo_root / "custom-values/buildbarn-values-ephemeral.yaml"],
            inline_overrides=overrides,
        )
        for name, store in storage_stores(ephemeral).items():
            assert "inMemory" in store["keyLocationMap"], (name, store)
            assert "persistent" not in store, (name, store)

filesystem = render_and_validate(
    "persistent-filesystem-defaults-all-stores",
    value_files=[ci_values],
    inline_overrides={"storage": {"persistence": {"iscc": {"enabled": True}, "fsac": {"enabled": True}}}},
)
assert_persistent_stores(filesystem)

# 7. Frontend existenceCaching=false branches (with and without readCache)
render_and_validate(
    "frontend-no-existence-cache-readcache",
    value_files=[ci_values],
    inline_overrides={
        "frontend": {
            "contentAddressableStorage": {"existenceCaching": {"enabled": False}},
            "readCache": {"enabled": True},
        }
    },
)
render_and_validate(
    "frontend-no-existence-cache-bare",
    value_files=[ci_values],
    inline_overrides={
        "frontend": {
            "contentAddressableStorage": {"existenceCaching": {"enabled": False}},
            "readCache": {"enabled": False},
        }
    },
)

# 8. In-cluster mTLS + tracing + browser internalService=false + actionResultExpiring
render_and_validate(
    "mtls-tracing-browser-fallback",
    value_files=[ci_values],
    inline_overrides={
        "portal": {"enabled": True},
        "remoteAsset": {"enabled": True},
        "tracing": {"enabled": True},
        "frontend": {"internalService": {"enabled": False}},
        "config": {"actionCache": {"actionResultExpiring": {"enabled": True}}},
        "security": {
            "grpcMtls": {
                "enabled": True,
                "certificateAuthorities": "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----\n",
            }
        },
    },
    expected_files=("storage.jsonnet", "frontend.jsonnet", "scheduler.jsonnet", "browser.jsonnet", "portal.jsonnet", "asset.jsonnet"),
)

# 9. Every custom-values/buildbarn-values*.yaml file (standalone + documented overlay)
custom_files = sorted((repo_root / "custom-values").glob("buildbarn-values*.yaml"))
assert custom_files, "expected at least one custom-values/buildbarn-values*.yaml file"
for cf in custom_files:
    render_and_validate(cf.name, value_files=[cf])
base_values = repo_root / "custom-values" / "buildbarn-values.yaml"
ssd_overlay = repo_root / "custom-values" / "buildbarn-values-local-ssd-block.yaml"
if base_values.exists() and ssd_overlay.exists():
    render_and_validate("overlay-buildbarn-values+local-ssd-block", value_files=[base_values, ssd_overlay])

# 10. Validate all supported combinations against the pinned CDC fork schema.
# Parsing against the upstream descriptor would reject the fork-only fields;
# checking only Jsonnet syntax previously missed CDC data under the legacy CAS.
for reload_enabled, handover_enabled in [(True, False), (False, True), (True, True)]:
    label = f"fork-reload-{reload_enabled}-handover-{handover_enabled}"
    configs = render_and_validate(
        label,
        value_files=[ci_values],
        inline_overrides={
            "images": {"scheduler": {"repository": "example.com/bb-scheduler"}},
            "scheduler": {
                "configurationReloadInterval": "30s" if reload_enabled else "",
                "handover": {
                    "enabled": handover_enabled,
                    "cdcCompatibleFork": True,
                    "coordinator": {"image": {
                        "repository": "example.com/bb-scheduler-coordinator", "tag": "test",
                    }},
                },
            },
        },
        scheduler_registry=fork_registry,
    )
    scheduler = configs["scheduler.jsonnet"]
    assert "legacyContentAddressableStorage" not in scheduler, scheduler
    assert "deprecatedPortalUrl" in scheduler, scheduler
    assert {"chunkStorage", "chunkMappingStorage", "cdcParameterCache"} <= set(scheduler["contentAddressableStorage"])
    assert ("configurationReloadInterval" in scheduler) == reload_enabled
    assert ("handoverGrpcServers" in scheduler) == handover_enabled
    assert ("coordinator" in scheduler) == handover_enabled
    # The stock image must continue rejecting these features: the fixture is
    # deliberately specific to the fork, not a permissive replacement schema.
    expect_invalid(
        label + "-not-upstream", "buildbarn.configuration.bb_scheduler.ApplicationConfiguration",
        scheduler, "configurationReloadInterval" if reload_enabled else "coordinator",
    )

print("All Buildbarn Jsonnet configurations validated against protobuf descriptors.")
PY
