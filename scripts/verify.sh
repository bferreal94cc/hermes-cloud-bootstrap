#!/usr/bin/env bash
set -Eeuo pipefail

STACK_ROOT="${HERMES_STACK_ROOT:-/opt/hermes-stack}"
RUNTIME_ENV="${HERMES_RUNTIME_ENV:-/etc/hermes-stack/runtime.env}"
COMPOSE_ENV="${HERMES_COMPOSE_ENV:-/etc/hermes-stack/compose.env}"
STATUS_FILE="/var/lib/hermes-stack/status.env"
HERMES_AGENT_SOURCE_DIR="$STACK_ROOT/sources/hermes-agent"
HERMES_WEBUI_SOURCE_DIR="$STACK_ROOT/sources/hermes-webui"

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Hermes verification must run as root.\n' >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$STACK_ROOT/versions.env"
# shellcheck source=/dev/null
source "$RUNTIME_ENV"
# shellcheck source=/dev/null
source "$COMPOSE_ENV"
set +a

assert_equal() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s mismatch: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_equal "$(git -C "$HERMES_AGENT_SOURCE_DIR" rev-parse HEAD)" "$HERMES_AGENT_REF" \
  'Hermes Agent source'
assert_equal "$(git -C "$HERMES_WEBUI_SOURCE_DIR" rev-parse HEAD)" "$HERMES_WEBUI_REF" \
  'Hermes WebUI source'

LOCAL_HEALTH='http://127.0.0.1:8787/health'
TAIL_HEALTH="http://$TAILSCALE_IP:8787/health"
HEALTHY=0
for _ in $(seq 1 180); do
  if curl -fsS --max-time 5 "$LOCAL_HEALTH" >/dev/null \
      && curl -fsS --max-time 5 "$TAIL_HEALTH" >/dev/null; then
    HEALTHY=1
    break
  fi
  sleep 5
done

if [[ "$HEALTHY" -ne 1 ]]; then
  docker compose --env-file "$COMPOSE_ENV" -f "$STACK_ROOT/compose.yaml" ps || true
  docker compose --env-file "$COMPOSE_ENV" -f "$STACK_ROOT/compose.yaml" logs --tail 200 || true
  exit 1
fi

CONTAINER_ID="$(docker compose --env-file "$COMPOSE_ENV" -f "$STACK_ROOT/compose.yaml" ps -q hermes-webui)"
[[ -n "$CONTAINER_ID" ]] || { printf 'Hermes WebUI container is missing.\n' >&2; exit 1; }
CONTAINER_HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_ID")"
assert_equal "$CONTAINER_HEALTH" 'healthy' 'Hermes WebUI container health'

WRONG_AUTH_CODE="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"password":"this-password-must-be-rejected"}' \
  http://127.0.0.1:8787/api/auth/login)"
if [[ "$WRONG_AUTH_CODE" != "401" && "$WRONG_AUTH_CODE" != "403" ]]; then
  printf 'Incorrect password was not rejected; HTTP %s.\n' "$WRONG_AUTH_CODE" >&2
  exit 1
fi

curl -fsS --max-time 5 \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg password "$HERMES_WEBUI_PASSWORD" '{password:$password}')" \
  http://127.0.0.1:8787/api/auth/login >/dev/null

SERVER_URL="http://$TAILSCALE_IP:8787"
DNS_NAME="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//' || true)"
if [[ -n "$DNS_NAME" ]] && tailscale serve --bg 8787 >/dev/null 2>&1; then
  SERVER_URL="https://$DNS_NAME"
fi

umask 077
{
  printf 'SERVER_URL=%s\n' "$SERVER_URL"
  printf 'TAILSCALE_IP=%s\n' "$TAILSCALE_IP"
  printf 'HERMES_AGENT_REF=%s\n' "$HERMES_AGENT_REF"
  printf 'HERMES_WEBUI_REF=%s\n' "$HERMES_WEBUI_REF"
  printf 'SERVICE_STATUS=%s\n' "$(systemctl is-active hermes-stack.service)"
} > "$STATUS_FILE"
chmod 0600 "$STATUS_FILE"

printf 'HERMES_STACK_VERIFIED\n'
printf 'SERVER_URL=%s\n' "$SERVER_URL"
printf 'TAILSCALE_IP=%s\n' "$TAILSCALE_IP"
printf 'HERMES_AGENT_REF=%s\n' "$HERMES_AGENT_REF"
printf 'HERMES_WEBUI_REF=%s\n' "$HERMES_WEBUI_REF"
printf 'PASSWORD_FILE=%s\n' "$RUNTIME_ENV"
curl -fsS --max-time 5 "$TAIL_HEALTH"
printf '\n'
