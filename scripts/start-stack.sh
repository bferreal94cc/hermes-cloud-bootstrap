#!/usr/bin/env bash
set -Eeuo pipefail

STACK_ROOT="${HERMES_STACK_ROOT:-/opt/hermes-stack}"
RUNTIME_ENV="${HERMES_RUNTIME_ENV:-/etc/hermes-stack/runtime.env}"
COMPOSE_ENV="${HERMES_COMPOSE_ENV:-/etc/hermes-stack/compose.env}"

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Hermes stack startup must run as root.\n' >&2
  exit 1
fi

for required in "$STACK_ROOT/versions.env" "$STACK_ROOT/compose.yaml" "$RUNTIME_ENV"; do
  if [[ ! -f "$required" ]]; then
    printf 'Missing required Hermes stack file: %s\n' "$required" >&2
    exit 1
  fi
done

set -a
# shellcheck source=/dev/null
source "$STACK_ROOT/versions.env"
# shellcheck source=/dev/null
source "$RUNTIME_ENV"
set +a

TAILSCALE_IP=""
for _ in $(seq 1 120); do
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  [[ -n "$TAILSCALE_IP" ]] && break
  sleep 5
done

if [[ -z "$TAILSCALE_IP" ]]; then
  printf 'Tailscale is not authorized yet. See /var/lib/hermes-stack/tailscale-auth.txt.\n' >&2
  exit 1
fi

IFS=. read -r ip1 ip2 ip3 ip4 <<< "$TAILSCALE_IP"
if [[ "$ip1" != "100" || ! "$ip2" =~ ^[0-9]+$ || "$ip2" -lt 64 || "$ip2" -gt 127 \
      || ! "$ip3" =~ ^[0-9]+$ || ! "$ip4" =~ ^[0-9]+$ ]]; then
  printf 'Refusing unexpected non-Tailscale IPv4 address: %s\n' "$TAILSCALE_IP" >&2
  exit 1
fi

install -d -m 0700 "$(dirname "$COMPOSE_ENV")"
umask 077
{
  printf 'TAILSCALE_IP=%s\n' "$TAILSCALE_IP"
  printf 'HERMES_WEBUI_PASSWORD=%s\n' "$HERMES_WEBUI_PASSWORD"
  printf 'HERMES_AGENT_REF=%s\n' "$HERMES_AGENT_REF"
  printf 'HERMES_WEBUI_REF=%s\n' "$HERMES_WEBUI_REF"
  printf 'HERMES_AGENT_SOURCE_DIR=%s/sources/hermes-agent\n' "$STACK_ROOT"
  printf 'HERMES_WEBUI_SOURCE_DIR=%s/sources/hermes-webui\n' "$STACK_ROOT"
  printf 'HERMES_HOME_DIR=/var/lib/hermes-stack/hermes-home\n'
  printf 'HERMES_WORKSPACE_DIR=/var/lib/hermes-stack/workspace\n'
} > "$COMPOSE_ENV"
chmod 0600 "$COMPOSE_ENV"

cd "$STACK_ROOT"
set -a
# shellcheck source=/dev/null
source "$COMPOSE_ENV"
set +a
docker compose build --pull
docker compose up -d --remove-orphans

"$STACK_ROOT/scripts/verify.sh"
