#!/usr/bin/env bash
set -Eeuo pipefail

STACK_ROOT="${HERMES_STACK_ROOT:-/opt/hermes-stack}"
RUNTIME_ENV="${HERMES_RUNTIME_ENV:-/etc/hermes-stack/runtime.env}"
STATUS_FILE="/var/lib/hermes-stack/status.env"

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Hermes status must run as root.\n' >&2
  exit 1
fi

[[ -f "$STATUS_FILE" ]] || { printf 'Hermes has not completed verification.\n' >&2; exit 1; }
[[ -f "$RUNTIME_ENV" ]] || { printf 'Hermes credentials are missing.\n' >&2; exit 1; }

# shellcheck source=/dev/null
source "$STATUS_FILE"
printf 'SERVER_URL=%s\n' "$SERVER_URL"
printf 'TAILSCALE_IP=%s\n' "$TAILSCALE_IP"
printf 'SERVICE_STATUS=%s\n' "$(systemctl is-active hermes-stack.service)"
printf 'CONTAINER_STATUS=%s\n' "$(docker inspect --format '{{.State.Health.Status}}' hermes-webui 2>/dev/null || echo unavailable)"

if [[ "${1:-}" == "--show-password" ]]; then
  # shellcheck source=/dev/null
  source "$RUNTIME_ENV"
  printf 'PASSWORD=%s\n' "$HERMES_WEBUI_PASSWORD"
else
  printf 'PASSWORD=hidden (rerun with --show-password as root)\n'
fi
