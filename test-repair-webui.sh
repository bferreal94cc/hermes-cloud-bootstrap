#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-repair-webui.sh}"

require() {
  local pattern="$1" message="$2"
  if ! grep -Fq -- "$pattern" "$SCRIPT"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

reject() {
  local pattern="$1" message="$2"
  if grep -Fq -- "$pattern" "$SCRIPT"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

require '/home/hermes/.hermes/hermes-agent/venv/bin/python' \
  'repair must pin the supported Hermes Python 3.11 runtime'
require 'HERMES_WEBUI_PASSWORD=' \
  'repair must confirm password auth before network exposure'
require "'After=network.target'" \
  'repair must use upstream-supported systemd ordering'
require 'start.sh --foreground' \
  'repair must keep the WebUI process attached to systemd'
require 'http://127.0.0.1:8787/health' \
  'repair must verify local health'
require 'this-is-not-the-generated-password' \
  'repair must reject an incorrect password before success'
require 'tailscale ip -4' \
  'repair must resolve the private Tailscale address'
reject 'ufw allow 8787' \
  'repair must not expose port 8787 publicly'
reject 'PASSWORD=%s' \
  'repair must not print the saved password into logs'

bash -n "$SCRIPT"
printf 'PASS: repair regression checks\n'
