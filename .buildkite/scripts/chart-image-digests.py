#!/usr/bin/env python3
"""Write a release inventory of the chart's default image references.

This runs against a temporary copy of the chart, before it is packaged and
signed. It never modifies the source values or changes Helm's override rules.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def image_references(values, app_version):
    """Find image values recursively, including optional and string images."""
    found = []

    def visit(value, path):
        if not isinstance(value, dict):
            return
        if "repository" in value:
            repo = value["repository"]
            if not isinstance(repo, str) or not repo:
                raise ValueError(f"{'.'.join(path)}.repository is empty")
            tags = [k for k in value if k == "tag" or k.endswith("Tag")]
            if not tags:
                raise ValueError(f"{'.'.join(path)}.repository has no tag")
            for key in tags:
                tag = value[key]
                if path == ("image",) and key == "tag" and not tag:
                    tag = app_version
                if not isinstance(tag, str) or not tag:
                    raise ValueError(f"{'.'.join(path + (key,))} is empty")
                digest_key = "digest" if key == "tag" else key[:-3] + "Digest"
                if digest_key not in value:
                    raise ValueError(f"{'.'.join(path)} is missing {digest_key}")
                digest = value[digest_key] or ""
                if digest and not DIGEST.fullmatch(digest):
                    raise ValueError(f"invalid digest at {'.'.join(path + (digest_key,))}")
                found.append((".".join(path + (key,)), f"{repo}:{tag}", digest))
        for key, child in value.items():
            if key == "image" and isinstance(child, str) and child:
                ref, separator, digest = child.partition("@")
                if separator and not DIGEST.fullmatch(digest):
                    raise ValueError(f"invalid digest at {'.'.join(path + (key,))}")
                found.append((".".join(path + (key,)), ref, digest))
            elif isinstance(child, dict):
                visit(child, path + (key,))

    visit(values, ())
    if not found:
        raise ValueError("no chart image defaults found")
    return found


def inspect_reference(ref):
    result = subprocess.run(
        ["crane", "digest", ref],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    # crane reports the top-level manifest or multi-platform index digest.
    digest = result.stdout.strip()
    if not DIGEST.fullmatch(digest):
        raise ValueError(f"invalid registry digest for {ref}: {digest}")
    return digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("chart", type=Path, help="temporary chart directory")
    args = parser.parse_args()
    chart = yaml.safe_load((args.chart / "Chart.yaml").read_text())
    values = yaml.safe_load((args.chart / "values.yaml").read_text())
    references = image_references(values, str(chart.get("appVersion", "")))
    cache = {}
    images = []
    for value_path, tag_ref, pinned in references:
        # With an explicit digest Kubernetes uses that digest instead of the
        # tag. A bare image name may contain a registry port but no tag.
        repo = tag_ref.rsplit(":", 1)[0] if tag_ref.rfind(":") > tag_ref.rfind("/") else tag_ref
        reference = repo + "@" + pinned if pinned else tag_ref
        if reference not in cache:
            print(f"Resolving {reference}", file=sys.stderr)
            cache[reference] = inspect_reference(reference)
        actual = cache[reference]
        if pinned and pinned != actual:
            raise ValueError(f"digest mismatch for {reference}: got {actual}")
        images.append({"value": value_path, "image": tag_ref, "digest": actual})
    output = {"schemaVersion": 1, "chart": chart["name"], "version": str(chart["version"]), "images": images}
    (args.chart / "image-digests.yaml").write_text(
        yaml.safe_dump(output, sort_keys=False, default_flow_style=False)
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, yaml.YAMLError) as exc:
        sys.exit(f"image digest inventory failed: {exc}")
