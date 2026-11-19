"""Reject duplicate input keys before Helm silently drops configuration.

A clean Git merge can introduce two policy blocks without a conflict marker.
Helm and normal YAML/JSON loaders keep only the last block, including when
that discards a default allowlist or disables an upgrade preflight.
"""

import json
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


class UniqueKeyLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        keys = set()
        for key_node, _ in node.value:
            # Validate explicit keys before SafeLoader expands YAML merge
            # keys. An explicit value may legitimately override an anchor.
            key = (
                "<<" if key_node.tag == "tag:yaml.org,2002:merge"
                else self.construct_object(key_node, deep=deep)
            )
            if key in keys:
                raise yaml.constructor.ConstructorError(
                    "while reading a mapping", node.start_mark,
                    f"duplicate key {key!r}", key_node.start_mark,
                )
            keys.add(key)
        return super().construct_mapping(node, deep=deep)


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


class ChartSourceIntegrityTest(unittest.TestCase):
    def test_yaml_anchor_overrides_remain_supported(self):
        values = yaml.load(
            "defaults: &defaults {enabled: true}\n"
            "custom: {<<: *defaults, enabled: false}\n",
            Loader=UniqueKeyLoader,
        )
        self.assertEqual(values["custom"], {"enabled": False})

    def test_duplicate_explicit_keys_are_rejected(self):
        with self.assertRaisesRegex(yaml.YAMLError, "duplicate key 'specPolicy'"):
            yaml.load("specPolicy: {checkExistingRbeWorkers: true}\nspecPolicy: {}\n",
                      Loader=UniqueKeyLoader)
        with self.assertRaisesRegex(ValueError, "duplicate JSON key 'specPolicy'"):
            json.loads('{"properties": {"specPolicy": {}, "specPolicy": {}}}',
                       object_pairs_hook=unique_json_object)

    def test_chart_and_starter_yaml_has_unique_keys(self):
        paths = sorted({
            *ROOT.glob("charts/*/Chart.yaml"),
            *ROOT.glob("charts/*/values.yaml"),
            *ROOT.glob("charts/*/ci-values/*.yaml"),
            *ROOT.glob("custom-values/**/*.yaml"),
        })
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(file=str(path.relative_to(ROOT))):
                list(yaml.load_all(path.read_text(), Loader=UniqueKeyLoader))

    def test_chart_schemas_have_unique_keys(self):
        paths = sorted(ROOT.glob("charts/*/values.schema.json"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(file=str(path.relative_to(ROOT))):
                json.loads(path.read_text(), object_pairs_hook=unique_json_object)


if __name__ == "__main__":
    unittest.main()
