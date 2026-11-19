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


def render_and_validate(label, value_files=(), inline_overrides=None, scheduler_registry=None):
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
        assert "storage.jsonnet" in validated and "frontend.jsonnet" in validated and "scheduler.jsonnet" in validated, (
            f"{label}: missing expected core jsonnet files: {validated}"
        )
        print(f"PASS {label}: {', '.join(validated)}")
        return validated


ci_values = chart / "ci-values" / "ci.yaml"

# 1. Default values (with ci-values image repository fixtures)
render_and_validate("defaults", value_files=[ci_values])

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
)

# 4. Dedicated CMS raw block-device PVC mode
render_and_validate(
    "cms-block-device-pvc",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cms": {"backend": "blockDevice", "blockDevice": {"size": "10Gi"}},
            }
        },
    },
)

# 5. Raw CAS without a filesystem mount uses the actual in-memory CMS fallback.
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

# 6. Every custom-values/buildbarn-values*.yaml file in the repository
custom_files = sorted((repo_root / "custom-values").glob("buildbarn-values*.yaml"))
assert custom_files, "expected at least one custom-values/buildbarn-values*.yaml file"
for cf in custom_files:
    render_and_validate(cf.name, value_files=[cf])

# 7. Validate all supported combinations against the pinned CDC fork schema.
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
