#!/bin/bash
# Builds Chromium's chrome target on your Buildbarn and reports the build to
# Hermetiq. Run from chromium/src after copying this directory's args.gn to
# out/rbe/args.gn and running `gn gen out/rbe`.
#
#   DOMAIN             your installation's hosts.domainBase
#   INSTANCE_NAME      your Hermetiq project ID
#   CREDENTIAL_HELPER  path to your Hermetiq credential helper
set -euo pipefail
: "${DOMAIN:?set DOMAIN to your hosts.domainBase}"
: "${INSTANCE_NAME:?set INSTANCE_NAME to your Hermetiq project ID}"
: "${CREDENTIAL_HELPER:?set CREDENTIAL_HELPER to your credential helper path}"

export SISO_CREDENTIAL_HELPER="$CREDENTIAL_HELPER"

siso-bep --bes_backend="grpcs://bep.$DOMAIN" --project="$INSTANCE_NAME" \
  --results_url="https://dashboard.$DOMAIN/build/" -- \
  autoninja -C out/rbe \
    -reapi_address="bb.$DOMAIN:443" -reapi_instance="$INSTANCE_NAME" \
    --strict_remote --remote_jobs=800 \
    --config=no-remote-timeout,default-remote,googlechrome,remote-link \
    -output_local_strategy=greedy \
    chrome
