#!/bin/bash
# Builds Chromium's chrome target on your Buildbarn and reports the build to
# Hermetiq. Run from chromium/src after `gn gen out/rbe` with ../args.gn.
#
#   <your-domain>       your Hermetiq installation's domain (hosts.domainBase)
#   $INSTANCE_NAME      your Hermetiq project ID
#   $CREDENTIAL_HELPER  path to your Hermetiq credential helper
set -euo pipefail

export SISO_CREDENTIAL_HELPER="$CREDENTIAL_HELPER"

siso-bep --bes_backend=grpcs://bep.<your-domain> --project="$INSTANCE_NAME" -- \
  autoninja -C out/rbe \
    -reapi_address=bb.<your-domain>:443 -reapi_instance="$INSTANCE_NAME" \
    --strict_remote --remote_jobs=800 \
    --config=no-remote-timeout,default-remote,googlechrome,remote-link \
    -output_local_strategy=greedy \
    chrome
