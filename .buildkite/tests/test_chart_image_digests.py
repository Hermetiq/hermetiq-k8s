import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".buildkite/scripts/chart-image-digests.py"
SPEC = importlib.util.spec_from_file_location("chart_image_digests", SCRIPT)
inventory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(inventory)


class ChartImageDigestsTest(unittest.TestCase):
    def test_real_chart_defaults_cover_image_shapes(self):
        expected = {
            "hermetiq": {"images.bepNats.apiTag", "images.bepNats.pubTag", "images.bepNats.subTag", "images.bepNats.bootstrapTag", "images.authProxy.tag", "images.dashboard.tag", "images.promptRuntime.tag", "images.oauth2Proxy.tag"},
            "buildbarn": {"images.storage.tag", "images.scheduler.tag", "images.browser.tag", "images.remoteAsset.tag", "images.busybox.image", "images.oauth2Proxy.tag", "images.grpcCacheProxy.tag", "images.portal.tag", "frontend.jwks.sync.image.tag"},
            "bb-worker-operator": {"image.tag"},
        }
        for name, paths in expected.items():
            with self.subTest(chart=name):
                chart_dir = ROOT / "charts" / name
                chart = yaml.safe_load((chart_dir / "Chart.yaml").read_text())
                values = yaml.safe_load((chart_dir / "values.yaml").read_text())
                refs = inventory.image_references(values, chart["appVersion"])
                self.assertTrue(paths.issubset({item[0] for item in refs}))
                if name == "bb-worker-operator":
                    self.assertTrue(refs[0][1].endswith(":" + chart["appVersion"]))

    def test_missing_digest_field_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing digest"):
            inventory.image_references({"images": {"api": {"repository": "example/api", "tag": "v1"}}}, "v1")

    def test_manifest_digest_and_duplicate_lookups(self):
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp) / "chart"
            chart.mkdir()
            (chart / "Chart.yaml").write_text("name: example\nversion: 1.0.0\nappVersion: v1\n")
            (chart / "values.yaml").write_text("""images:
  api:
    repository: example.com/api
    apiTag: v1
    apiDigest: ''
    pubTag: v1
    pubDigest: ''
  init:
    image: busybox:1.0
""")
            crane = Path(tmp) / "crane"
            crane.write_text("#!/bin/sh\nprintf '%s\\n' \"$2\" >> \"$CALLS\"\nprintf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n'\n")
            crane.chmod(0o755)
            calls = Path(tmp) / "calls"
            env = {**os.environ, "PATH": tmp + os.pathsep + os.environ["PATH"], "CALLS": str(calls)}
            subprocess.run([sys_executable(), str(SCRIPT), str(chart)], env=env, check=True)
            output = yaml.safe_load((chart / "image-digests.yaml").read_text())
            expected = "sha256:" + "a" * 64
            self.assertEqual([item["digest"] for item in output["images"]], [expected] * 3)
            self.assertEqual(calls.read_text().splitlines(), ["example.com/api:v1", "busybox:1.0"])
            self.assertEqual(yaml.safe_load((chart / "values.yaml").read_text())["images"]["api"]["apiDigest"], "")

    def test_registry_failures_propagate(self):
        with mock.patch.object(inventory.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "crane")):
            with self.assertRaises(subprocess.CalledProcessError):
                inventory.inspect_reference("example.com/api:v1")

    def test_invalid_registry_digest_is_rejected(self):
        with mock.patch.object(inventory.subprocess, "run", return_value=mock.Mock(stdout="latest\n")):
            with self.assertRaisesRegex(ValueError, "invalid registry digest"):
                inventory.inspect_reference("example.com/api:v1")


def sys_executable():
    import sys

    return sys.executable


if __name__ == "__main__":
    unittest.main()
