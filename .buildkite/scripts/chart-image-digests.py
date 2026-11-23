#!/usr/bin/env python3
"""Write a release inventory of the chart's default image references.

With --pin, also pin the chart's default image values to the resolved digests.
Publication uses a temporary chart copy; maintainers can use the same command
on source charts to update their pins without rewriting comments or formatting.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import yaml


DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def image_references(values, app_version):
    """Find image values recursively, including optional and string images."""
    found = []

    def visit(value, path, enabled=True):
        if not isinstance(value, dict):
            return
        if isinstance(value.get("enabled"), bool):
            enabled = enabled and value["enabled"]
        if "repository" in value:
            repo = value["repository"]
            tags = [k for k in value if k == "tag" or k.endswith("Tag")]
            digest_keys = ["digest" if k == "tag" else k[:-3] + "Digest" for k in tags]
            if (
                not enabled
                and repo == ""
                and tags
                and all(value.get(k) == "" for k in tags)
                and all(k in value and (value[k] or "") == "" for k in digest_keys)
            ):
                return
            if not isinstance(repo, str) or not repo:
                raise ValueError(f"{'.'.join(path)}.repository is empty")
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
                visit(child, path + (key,), enabled)

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


def pin_values(source, images):
    """Replace only image scalar values, preserving YAML comments and layout."""
    root = yaml.compose(source)
    replacements = []
    for image in images:
        path = image["value"].split(".")
        if path[-1] == "image":
            replacement = image["image"] + "@" + image["digest"]
        else:
            path[-1] = "digest" if path[-1] == "tag" else path[-1][:-3] + "Digest"
            replacement = image["digest"]
        node = root
        for key in path:
            if not isinstance(node, yaml.MappingNode):
                raise ValueError(f"image value {'.'.join(path)} is not a mapping")
            node = next((value for name, value in node.value if name.value == key), None)
            if node is None:
                raise ValueError(f"missing image value {'.'.join(path)}")
        if not isinstance(node, yaml.ScalarNode):
            raise ValueError(f"image value {'.'.join(path)} is not a scalar")
        if node.value != replacement:
            encoded = json.dumps(replacement)
            if node.start_mark.index == node.end_mark.index:
                encoded = " " + encoded
            replacements.append((node.start_mark.index, node.end_mark.index, encoded))
    for start, end, replacement in sorted(replacements, reverse=True):
        source = source[:start] + replacement + source[end:]
    # Reject unsupported YAML structures (for example overlapping aliases)
    # before replacing a maintainer's source file.
    yaml.safe_load(source)
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("chart", type=Path, help="chart directory")
    parser.add_argument("--pin", action="store_true", help="also set default image digests in values.yaml")
    args = parser.parse_args()
    chart = yaml.safe_load((args.chart / "Chart.yaml").read_text())
    values_path = args.chart / "values.yaml"
    values_source = values_path.read_text()
    values = yaml.safe_load(values_source)
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
    # Resolve every image before writing anything: a missing release tag must
    # not leave the chart with only some of its defaults pinned.
    if args.pin:
        values_path.write_text(pin_values(values_source, images))
    (args.chart / "image-digests.yaml").write_text(
        yaml.safe_dump(output, sort_keys=False, default_flow_style=False)
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, yaml.YAMLError) as exc:
        sys.exit(f"image digest inventory failed: {exc}")
