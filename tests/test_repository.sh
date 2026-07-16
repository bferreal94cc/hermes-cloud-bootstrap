#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS="$ROOT/versions.env"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -f "$VERSIONS" ]] || fail 'versions.env is required'

set -a
# shellcheck source=/dev/null
source "$VERSIONS"
set +a

[[ "${HERMES_AGENT_REPO:-}" == "https://github.com/NousResearch/hermes-agent.git" ]] \
  || fail 'Hermes Agent must use the official Nous Research repository'
[[ "${HERMES_WEBUI_REPO:-}" == "https://github.com/nesquena/hermes-webui.git" ]] \
  || fail 'Hermes WebUI must use the official nesquena repository'
[[ "${HERMEX_REPO:-}" == "https://github.com/uzairansaruzi/hermex.git" ]] \
  || fail 'Hermex must use the official upstream repository'

for ref_name in HERMES_AGENT_REF HERMES_WEBUI_REF HERMEX_REF; do
  ref_value="${!ref_name:-}"
  [[ "$ref_value" =~ ^[0-9a-f]{40}$ ]] \
    || fail "$ref_name must be an exact 40-character commit SHA"
done

[[ "${TAILSCALE_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail 'TAILSCALE_VERSION must be an exact semantic version'

if grep -Eq '=(main|master|latest|stable)$' "$VERSIONS"; then
  fail 'floating branches, tags, and image labels are forbidden'
fi

printf 'PASS: repository source pins\n'
