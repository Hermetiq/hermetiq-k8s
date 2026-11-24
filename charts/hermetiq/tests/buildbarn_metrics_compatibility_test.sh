#!/usr/bin/env bash
# Dashboard changes must keep passing the same metric compatibility fixtures
# as the Buildbarn chart's recording rules.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bash "${repo_root}/charts/buildbarn/tests/metrics_compatibility_test.sh"
