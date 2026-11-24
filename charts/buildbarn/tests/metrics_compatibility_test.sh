#!/usr/bin/env bash
# Run real recording-rule and shipped-dashboard PromQL against legacy, CDC,
# and mixed-version samples. Requires promtool and Python's PyYAML package.
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v promtool >/dev/null || { echo 'promtool is required for metrics compatibility tests' >&2; exit 1; }
python3 "${test_dir}/metrics_compatibility.py"
