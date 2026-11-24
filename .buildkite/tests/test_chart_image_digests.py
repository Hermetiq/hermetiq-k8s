import importlib.util
import os
import re
import shutil
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
            "buildbarn": {"images.storage.tag", "images.scheduler.tag", "images.worker.tag", "images.runnerInstaller.tag", "images.browser.tag", "images.remoteAsset.tag", "images.busybox.image", "images.oauth2Proxy.tag", "images.grpcCacheProxy.tag", "images.portal.tag", "frontend.jwks.sync.image.tag"},
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

    def test_disabled_unconfigured_feature_image_hook_is_skipped(self):
        values = {
            "images": {"api": {"repository": "example/api", "tag": "v1", "digest": ""}},
            "feature": {
                "enabled": False,
                "sidecar": {"image": {"repository": "", "tag": "", "digest": ""}},
            },
        }
        self.assertEqual(
            inventory.image_references(values, "v1"),
            [("images.api.tag", "example/api:v1", "")],
        )

    def test_enabled_or_partial_empty_image_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "feature.sidecar.image.repository is empty"):
            inventory.image_references(
                {
                    "feature": {
                        "enabled": True,
                        "sidecar": {"image": {"repository": "", "tag": "", "digest": ""}},
                    }
                },
                "v1",
            )
        with self.assertRaisesRegex(ValueError, "feature.sidecar.image.repository is empty"):
            inventory.image_references(
                {
                    "feature": {
                        "enabled": False,
                        "sidecar": {"image": {"repository": "", "tag": "v1", "digest": ""}},
                    }
                },
                "v1",
            )

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

    def test_pin_preserves_comments_and_sets_all_image_shapes(self):
        digest = "sha256:" + "a" * 64
        source = """# Keep release guidance.
images:
  api:
    repository: example.com/api
    apiTag: v1
    apiDigest: "" # API pin
    pubTag: v1
    pubDigest: ''
  init:
    image: busybox:1.0 # Init helper
"""
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / "Chart.yaml").write_text("name: example\nversion: 1.0.0\nappVersion: v1\n")
            (chart / "values.yaml").write_text(source)
            with mock.patch.object(inventory.sys, "argv", [str(SCRIPT), "--pin", str(chart)]), mock.patch.object(
                inventory, "inspect_reference", return_value=digest
            ):
                inventory.main()
            pinned = (chart / "values.yaml").read_text()
            self.assertEqual(pinned, source.replace('apiDigest: ""', f'apiDigest: "{digest}"')
                             .replace("pubDigest: ''", f'pubDigest: "{digest}"')
                             .replace("image: busybox:1.0", f'image: "busybox:1.0@{digest}"'))
            images = yaml.safe_load((chart / "image-digests.yaml").read_text())["images"]
            self.assertEqual(inventory.pin_values(pinned, images), pinned)

    def test_pin_registry_failure_leaves_values_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / "Chart.yaml").write_text("name: example\nversion: 1.0.0\nappVersion: v1\n")
            source = """images:
  api:
    repository: example/api
    tag: v1
    digest: ''
  worker:
    repository: example/worker
    tag: v1
    digest: ''
"""
            (chart / "values.yaml").write_text(source)
            with mock.patch.object(inventory.sys, "argv", [str(SCRIPT), "--pin", str(chart)]), mock.patch.object(
                inventory, "inspect_reference", side_effect=["sha256:" + "a" * 64, subprocess.CalledProcessError(1, "crane")]
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    inventory.main()
            self.assertEqual((chart / "values.yaml").read_text(), source)
            self.assertFalse((chart / "image-digests.yaml").exists())

    def test_pin_accepts_an_implicit_null_digest(self):
        digest = "sha256:" + "a" * 64
        source = "images:\n  api:\n    repository: example/api\n    tag: v1\n    digest:\n"
        pinned = inventory.pin_values(source, [
            {"value": "images.api.tag", "image": "example/api:v1", "digest": digest},
        ])
        self.assertEqual(yaml.safe_load(pinned)["images"]["api"]["digest"], digest)

    @unittest.skipUnless(shutil.which("helm"), "helm is required for rendering")
    def test_pinned_chart_defaults_and_explicit_tag_override_render(self):
        digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp) / "hermetiq"
            shutil.copytree(ROOT / "charts/hermetiq", chart)
            # Release preparation pins the source values, and an existing digest
            # stays authoritative. Start this copy from an unpinned API image so
            # the test proves --pin writes the resolved digest either way.
            values = chart / "values.yaml"
            unpinned, count = re.subn(r'(?m)^(\s+apiDigest:).*$', r'\1 ""', values.read_text())
            self.assertEqual(count, 1)
            # Give the other required workloads digests of their own while
            # leaving the API unpinned for the release command under test, so
            # the render below also shows existing digests are kept.
            unpinned = inventory.pin_values(unpinned, [
                {"value": image_path, "digest": "sha256:" + "c" * 64}
                for image_path in (
                    "images.bepNats.pubTag",
                    "images.bepNats.bootstrapTag",
                    "images.dashboard.tag",
                )
            ])
            values.write_text(unpinned)
            with mock.patch.object(inventory.sys, "argv", [str(SCRIPT), "--pin", str(chart)]), mock.patch.object(
                inventory, "inspect_reference", side_effect=lambda ref: ref.partition("@")[2] or digest
            ):
                inventory.main()
            self.assertEqual(yaml.safe_load(values.read_text())["images"]["bepNats"]["apiDigest"], digest)
            # Drop any image selection from the render fixture so the rendered
            # API uses the source digest written above.
            runtime_values = yaml.safe_load((chart / "ci-values/ci.yaml").read_text())
            runtime_values.pop("images", None)
            runtime_fixture = Path(tmp) / "runtime-values.yaml"
            runtime_fixture.write_text(yaml.safe_dump(runtime_values))
            command = ["helm", "template", "test", str(chart), "-f", str(runtime_fixture)]
            rendered = subprocess.check_output(command, text=True)
            containers = [container for document in yaml.safe_load_all(rendered)
                          if document and document["kind"] == "Deployment"
                          for container in document["spec"]["template"]["spec"]["containers"]]
            api = next(container for container in containers if container["name"] == "api")
            self.assertTrue(api["image"].endswith("@" + digest), api["image"])
            overridden = subprocess.check_output(command + [
                "--set", "global.imageRegistry=mirror.example", "--set", "images.bepNats.apiTag=custom",
                "--set-string", "images.bepNats.apiDigest=",
            ], text=True)
            containers = [container for document in yaml.safe_load_all(overridden)
                          if document and document["kind"] == "Deployment"
                          for container in document["spec"]["template"]["spec"]["containers"]]
            api = next(container for container in containers if container["name"] == "api")
            self.assertEqual(api["image"], "mirror.example/hermetiq-cloud/hermetiq-public/bep-nats:custom")

    def test_pinned_images_resolve_by_digest_and_preserve_readable_references(self):
        digest = "sha256:" + "a" * 64
        values = {
            "images": {
                "api": {"repository": "registry.example:5000/api", "tag": "v1", "digest": digest},
                "worker": {"image": "registry.example:5000/worker@" + digest},
                "init": {"image": "registry.example:5000/worker:latest@" + digest},
            },
        }
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / "Chart.yaml").write_text("name: example\nversion: 1.0.0\nappVersion: v1\n")
            original_values = yaml.safe_dump(values, sort_keys=False)
            (chart / "values.yaml").write_text(original_values)
            with mock.patch.object(inventory.sys, "argv", [str(SCRIPT), str(chart)]), mock.patch.object(
                inventory, "inspect_reference", return_value=digest
            ) as inspect:
                inventory.main()
            self.assertEqual(inspect.call_args_list, [
                mock.call("registry.example:5000/api@" + digest),
                mock.call("registry.example:5000/worker@" + digest),
            ])
            output = yaml.safe_load((chart / "image-digests.yaml").read_text())
            self.assertEqual(output["images"], [
                {"value": "images.api.tag", "image": "registry.example:5000/api:v1", "digest": digest},
                {"value": "images.worker.image", "image": "registry.example:5000/worker", "digest": digest},
                {"value": "images.init.image", "image": "registry.example:5000/worker:latest", "digest": digest},
            ])
            self.assertEqual((chart / "values.yaml").read_text(), original_values)

    def test_pinned_digest_mismatch_does_not_write_an_inventory(self):
        pinned = "sha256:" + "a" * 64
        actual = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / "Chart.yaml").write_text("name: example\nversion: 1.0.0\nappVersion: v1\n")
            (chart / "values.yaml").write_text(yaml.safe_dump({
                "images": {"api": {"repository": "example/api", "tag": "v1", "digest": pinned}},
            }))
            with mock.patch.object(inventory.sys, "argv", [str(SCRIPT), str(chart)]), mock.patch.object(
                inventory, "inspect_reference", return_value=actual
            ) as inspect:
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    inventory.main()
            inspect.assert_called_once_with("example/api@" + pinned)
            self.assertFalse((chart / "image-digests.yaml").exists())

    def test_invalid_registry_digest_is_rejected(self):
        with mock.patch.object(inventory.subprocess, "run", return_value=mock.Mock(stdout="latest\n")):
            with self.assertRaisesRegex(ValueError, "invalid registry digest"):
                inventory.inspect_reference("example.com/api:v1")


def sys_executable():
    import sys

    return sys.executable


if __name__ == "__main__":
    unittest.main()
