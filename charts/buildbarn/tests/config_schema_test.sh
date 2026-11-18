#!/usr/bin/env bash
# Evaluate every rendered Buildbarn Jsonnet config across default values,
# optional feature flags, and all custom-values/buildbarn-values-*.yaml files,
# and validate the evaluated JSON against the Buildbarn protobuf
# FileDescriptorSets (buildbarn_descriptors_cdc.pb for CDC services,
# buildbarn_descriptors.pb for legacy bb-browser) with unknown-field rejection.
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

chart = pathlib.Path(sys.argv[1])
repo_root = chart.parent.parent
testdata = chart / "tests" / "testdata"

# Protobuf wire-type constants and DescriptorProto field numbers from
# google/protobuf/descriptor.proto (pure-stdlib reader so CI does not need
# python3-protobuf).
TYPE_DOUBLE = 1
TYPE_FLOAT = 2
TYPE_INT64 = 3
TYPE_UINT64 = 4
TYPE_INT32 = 5
TYPE_FIXED64 = 6
TYPE_FIXED32 = 7
TYPE_BOOL = 8
TYPE_STRING = 9
TYPE_GROUP = 10
TYPE_MESSAGE = 11
TYPE_BYTES = 12
TYPE_UINT32 = 13
TYPE_ENUM = 14
TYPE_SFIXED32 = 15
TYPE_SFIXED64 = 16
TYPE_SINT32 = 17
TYPE_SINT64 = 18

LABEL_REPEATED = 3

INT_TYPES = {
    TYPE_INT64, TYPE_UINT64, TYPE_INT32, TYPE_FIXED64, TYPE_FIXED32,
    TYPE_UINT32, TYPE_SFIXED32, TYPE_SFIXED64, TYPE_SINT32, TYPE_SINT64,
}
FLOAT_TYPES = {TYPE_DOUBLE, TYPE_FLOAT}


def _read_varint(buf, pos):
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def _iter_fields(buf):
    pos = 0
    n = len(buf)
    while pos < n:
        tag, pos = _read_varint(buf, pos)
        field_num = tag >> 3
        wire_type = tag & 0x7
        if wire_type == 0:
            val, pos = _read_varint(buf, pos)
        elif wire_type == 1:
            val = buf[pos:pos + 8]
            pos += 8
        elif wire_type == 2:
            length, pos = _read_varint(buf, pos)
            val = buf[pos:pos + length]
            pos += length
        elif wire_type == 5:
            val = buf[pos:pos + 4]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire_type}")
        yield field_num, val


def _camel_case(snake):
    parts = snake.split("_")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def _parse_field_descriptor(buf):
    field = {
        "name": "",
        "json_name": "",
        "number": 0,
        "label": 1,
        "type": 0,
        "type_name": "",
    }
    for num, val in _iter_fields(buf):
        if num == 1:
            field["name"] = val.decode("utf-8")
        elif num == 3:
            field["number"] = val
        elif num == 4:
            field["label"] = val
        elif num == 5:
            field["type"] = val
        elif num == 6:
            field["type_name"] = val.decode("utf-8").lstrip(".")
        elif num == 10:
            field["json_name"] = val.decode("utf-8")
    if not field["json_name"] and field["name"]:
        field["json_name"] = _camel_case(field["name"])
    return field


def _parse_enum_descriptor(buf):
    name = ""
    values = set()
    value_numbers = set()
    for num, val in _iter_fields(buf):
        if num == 1:
            name = val.decode("utf-8")
        elif num == 2:
            v_name = ""
            v_num = 0
            for vnum, vval in _iter_fields(val):
                if vnum == 1:
                    v_name = vval.decode("utf-8")
                elif vnum == 2:
                    v_num = vval
            if v_name:
                values.add(v_name)
            value_numbers.add(v_num)
    return name, {"values": values, "numbers": value_numbers}


def _parse_message_options_map_entry(buf):
    for num, val in _iter_fields(buf):
        if num == 7:
            return bool(val)
    return False


def _parse_descriptor_proto(buf, prefix, messages, enums):
    name = ""
    fields = []
    nested_raw = []
    enums_raw = []
    map_entry = False
    for num, val in _iter_fields(buf):
        if num == 1:
            name = val.decode("utf-8")
        elif num == 2:
            fields.append(_parse_field_descriptor(val))
        elif num == 3:
            nested_raw.append(val)
        elif num == 4:
            enums_raw.append(val)
        elif num == 7:
            map_entry = _parse_message_options_map_entry(val)
    fqn = f"{prefix}.{name}" if prefix else name
    by_name = {}
    by_num = {}
    for f in fields:
        by_name[f["name"]] = f
        by_name[f["json_name"]] = f
        by_num[f["number"]] = f
    messages[fqn] = {
        "fqn": fqn,
        "fields": by_name,
        "fields_by_num": by_num,
        "map_entry": map_entry,
    }
    for nbuf in nested_raw:
        _parse_descriptor_proto(nbuf, fqn, messages, enums)
    for ebuf in enums_raw:
        ename, edesc = _parse_enum_descriptor(ebuf)
        enums[f"{fqn}.{ename}"] = edesc


def load_descriptor_set(path):
    raw = path.read_bytes()
    messages = {}
    enums = {}
    for num, val in _iter_fields(raw):
        if num != 1:
            continue
        pkg = ""
        msg_raw = []
        enum_raw = []
        for fnum, fval in _iter_fields(val):
            if fnum == 2:
                pkg = fval.decode("utf-8")
            elif fnum == 4:
                msg_raw.append(fval)
            elif fnum == 5:
                enum_raw.append(fval)
        for mbuf in msg_raw:
            _parse_descriptor_proto(mbuf, pkg, messages, enums)
        for ebuf in enum_raw:
            ename, edesc = _parse_enum_descriptor(ebuf)
            efqn = f"{pkg}.{ename}" if pkg else ename
            enums[efqn] = edesc
    return {"messages": messages, "enums": enums}


WELL_KNOWN_SCALARS = {
    "google.protobuf.Duration": str,
    "google.protobuf.Timestamp": str,
    "google.protobuf.FieldMask": str,
}


def validate_scalar(field, value, registry, path):
    ftype = field["type"]
    if ftype == TYPE_BOOL:
        if not isinstance(value, bool):
            raise AssertionError(f"{path}: expected bool, got {type(value).__name__}")
    elif ftype in INT_TYPES:
        # protojson accepts integers or numeric strings for 64-bit integer types
        if isinstance(value, bool):
            raise AssertionError(f"{path}: expected integer, got bool")
        if isinstance(value, int):
            return
        if isinstance(value, str):
            try:
                int(value)
                return
            except ValueError as exc:
                raise AssertionError(f"{path}: invalid integer string {value!r}") from exc
        raise AssertionError(f"{path}: expected integer, got {type(value).__name__}")
    elif ftype in FLOAT_TYPES:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise AssertionError(f"{path}: expected float, got {type(value).__name__}")
    elif ftype in (TYPE_STRING, TYPE_BYTES):
        if not isinstance(value, str):
            raise AssertionError(f"{path}: expected string, got {type(value).__name__}")
    elif ftype == TYPE_ENUM:
        enum_desc = registry["enums"].get(field["type_name"])
        if enum_desc is None:
            raise AssertionError(f"{path}: unknown enum {field['type_name']}")
        if isinstance(value, str):
            if value not in enum_desc["values"]:
                raise AssertionError(
                    f"{path}: invalid enum value {value!r} for {field['type_name']}"
                )
        elif isinstance(value, int) and not isinstance(value, bool):
            if value not in enum_desc["numbers"]:
                raise AssertionError(
                    f"{path}: invalid enum number {value!r} for {field['type_name']}"
                )
        else:
            raise AssertionError(f"{path}: invalid enum type {type(value).__name__}")
    elif ftype == TYPE_MESSAGE:
        validate_message(field["type_name"], value, registry, path)
    else:
        raise AssertionError(f"{path}: unsupported field type {ftype}")


def validate_message(fqn, obj, registry, path=""):
    if fqn in WELL_KNOWN_SCALARS:
        expected_type = WELL_KNOWN_SCALARS[fqn]
        if not isinstance(obj, expected_type):
            raise AssertionError(
                f"{path}: expected {expected_type.__name__} for {fqn}, got {type(obj).__name__}"
            )
        return
    if fqn in ("google.protobuf.Struct", "google.protobuf.Value", "google.protobuf.Any"):
        return
    if fqn == "google.protobuf.Empty":
        if not isinstance(obj, dict) or obj:
            raise AssertionError(f"{path}: expected empty object for google.protobuf.Empty, got {obj!r}")
        return

    msg_desc = registry["messages"].get(fqn)
    if msg_desc is None:
        raise AssertionError(f"{path or '<root>'}: unknown proto message {fqn}")
    if not isinstance(obj, dict):
        raise AssertionError(f"{path or fqn}: expected JSON object for {fqn}, got {type(obj).__name__}")

    for key, val in obj.items():
        if val is None:
            continue
        field_path = f"{path}.{key}" if path else key
        field = msg_desc["fields"].get(key)
        if field is None:
            raise AssertionError(
                f"{field_path}: unknown field {key!r} on proto message {fqn}"
            )
        if field["label"] == LABEL_REPEATED:
            # Check if this repeated field is a protobuf map<K, V> entry
            nested = (
                registry["messages"].get(field["type_name"])
                if field["type"] == TYPE_MESSAGE
                else None
            )
            if nested and nested["map_entry"]:
                if not isinstance(val, dict):
                    raise AssertionError(
                        f"{field_path}: expected map object, got {type(val).__name__}"
                    )
                val_field = nested["fields_by_num"][2]
                for mkey, mval in val.items():
                    if not isinstance(mkey, str):
                        raise AssertionError(f"{field_path}: map key must be string")
                    validate_scalar(val_field, mval, registry, f"{field_path}[{mkey!r}]")
            else:
                if not isinstance(val, list):
                    raise AssertionError(
                        f"{field_path}: expected array for repeated field, got {type(val).__name__}"
                    )
                for idx, elem in enumerate(val):
                    validate_scalar(field, elem, registry, f"{field_path}[{idx}]")
        else:
            validate_scalar(field, val, registry, field_path)


# These are copies of cloud-native bep-nats/bbproto/buildbarn_descriptors*.pb,
# which bep-nats validates against at runtime (buildbarn-forms ships the same
# bytes). A refreshed copy must come from there, with these hashes updated in
# the same change, so the chart is never tested against a different schema.
import hashlib
EXPECTED_DESCRIPTOR_SHA256 = {
    "buildbarn_descriptors.pb": "3c7760bcddbc0516efdfc33f667a5e2c2382e461dac91713d87bfdeeaab60aa0",
    "buildbarn_descriptors_cdc.pb": "e08e0b969d71f8dd41f52063de2e252a9ac77c85a5e3681d62109ab20f73b5b4",
}
for name, expected in EXPECTED_DESCRIPTOR_SHA256.items():
    actual = hashlib.sha256((testdata / name).read_bytes()).hexdigest()
    if actual != expected:
        raise AssertionError(
            f"tests/testdata/{name} has sha256 {actual}, expected {expected}; copy it from "
            "cloud-native bep-nats/bbproto and update EXPECTED_DESCRIPTOR_SHA256"
        )

cdc_registry = load_descriptor_set(testdata / "buildbarn_descriptors_cdc.pb")
pre_cdc_registry = load_descriptor_set(testdata / "buildbarn_descriptors.pb")

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


def render_and_validate(label, value_files=(), inline_overrides=None):
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

        validated = []
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
            validate_message(fqn, rendered_json, reg, f"{label}:{filename}")
            validated.append(filename)
        assert "storage.jsonnet" in validated and "frontend.jsonnet" in validated and "scheduler.jsonnet" in validated, (
            f"{label}: missing expected core jsonnet files: {validated}"
        )
        print(f"PASS {label}: {', '.join(validated)}")


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
                "cms": {"backend": "filesystem", "enabled": True, "size": "10Gi"},
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
                "cms": {"backend": "blockDevice", "enabled": True, "size": "10Gi"},
            }
        },
    },
)

# 5. In-memory CAS + CMS (persistence disabled)
render_and_validate(
    "in-memory-cas-cms",
    value_files=[ci_values],
    inline_overrides={
        "storage": {
            "persistence": {
                "cas": {"enabled": False},
                "ac": {"enabled": False},
            }
        },
    },
)

# 6. Every custom-values/buildbarn-values*.yaml file in the repository
custom_files = sorted((repo_root / "custom-values").glob("buildbarn-values*.yaml"))
assert custom_files, "expected at least one custom-values/buildbarn-values*.yaml file"
for cf in custom_files:
    render_and_validate(cf.name, value_files=[cf])

print("All Buildbarn Jsonnet configurations validated against protobuf descriptors.")
PY
