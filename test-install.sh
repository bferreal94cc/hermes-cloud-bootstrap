#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-gcp-hermes-bootstrap.sh}"

assert_contains() {
  local pattern="$1" message="$2"
  if ! grep -Fq -- "$pattern" "$SCRIPT"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

assert_not_contains() {
  local pattern="$1" message="$2"
  if grep -Fq -- "$pattern" "$SCRIPT"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

assert_before() {
  local first="$1" second="$2" message="$3"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$SCRIPT" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$SCRIPT" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

assert_contains \
  'HERMES_WEBUI_PYTHON=$HERMES_HOME/hermes-agent/venv/bin/python' \
  'WebUI must use Hermes managed Python 3.11 instead of Debian 11 Python 3.9'

assert_contains \
  "'After=network.target'" \
  'WebUI systemd unit must use the upstream-supported network.target ordering'

assert_not_contains \
  "'Wants=network-online.target'" \
  'WebUI must not wait indefinitely for network-online.target'

assert_not_contains \
  "'After=network-online.target tailscaled.service'" \
  'WebUI startup must not be blocked by tailscaled readiness'

assert_contains \
  "'Type=simple'" \
  'The foreground Tailscale daemon must use a non-blocking systemd service type'

assert_contains \
  '/etc/apt/sources.list.d/tailscale.list.disabled' \
  'A stale Tailscale apt source must be disabled before apt update'

assert_before \
  '/etc/apt/sources.list.d/tailscale.list.disabled' \
  'apt-get update' \
  'The stale Tailscale source must be disabled before apt-get update runs'

bash -n "$SCRIPT"
printf 'PASS: bootstrap regression checks\n'
