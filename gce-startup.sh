#!/usr/bin/env bash
set -Eeuo pipefail

# Safe for Compute Engine startup-script metadata: the validated bootstrap
# commit is fixed here instead of following the repository's main branch.
export HERMES_BOOTSTRAP_REF=1a0066cb0f6470becbf8796b65a1a5d08ccd2bb6
export TAILSCALE_HOSTNAME=hermes-agent-vm-v2

curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  "https://raw.githubusercontent.com/bferreal94cc/hermes-cloud-bootstrap/${HERMES_BOOTSTRAP_REF}/install.sh" \
  | bash
