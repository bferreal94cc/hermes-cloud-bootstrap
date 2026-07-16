#!/usr/bin/env bash
set -Eeuo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/hermes/.hermes"
WEBUI_DIR="/home/hermes/hermes-webui"
ENV_FILE="$WEBUI_DIR/.env"
HERMES_PYTHON="/home/hermes/.hermes/hermes-agent/venv/bin/python"
SERVICE_FILE="/etc/systemd/system/hermes-webui.service"

if [ "$(id -u)" -ne 0 ]; then
  printf 'Run this repair as root.\n' >&2
  exit 1
fi

for required in "$WEBUI_DIR/start.sh" "$ENV_FILE" "$HERMES_PYTHON"; do
  if [ ! -e "$required" ]; then
    printf 'Required Hermes file is missing: %s\n' "$required" >&2
    exit 1
  fi
done

if [ ! -x "$HERMES_PYTHON" ]; then
  printf 'Hermes managed Python is not executable: %s\n' "$HERMES_PYTHON" >&2
  exit 1
fi

if ! "$HERMES_PYTHON" -c \
  'import sys; raise SystemExit(0 if (3, 11) <= sys.version_info[:2] <= (3, 13) else 1)'; then
  printf 'Hermes WebUI requires Python 3.11 through 3.13.\n' >&2
  exit 1
fi

# Never bind remotely until the existing password setting is confirmed.
if ! grep -Eq '^HERMES_WEBUI_PASSWORD=.+$' "$ENV_FILE"; then
  printf 'Password authentication is not active; refusing network exposure.\n' >&2
  exit 1
fi

set_env() {
  local key="$1" value="$2"
  sed -i "/^${key}=/d" "$ENV_FILE"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

# Debian 11 ships Python 3.9. Pin startup to the Python 3.11 environment that
# the official Hermes installer created, then use the upstream Tailscale bind.
set_env HERMES_WEBUI_PYTHON "$HERMES_PYTHON"
set_env HERMES_WEBUI_HOST 0.0.0.0
set_env HERMES_WEBUI_PORT 8787
set_env HERMES_WEBUI_SECURE false
chown "$HERMES_USER:$HERMES_USER" "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# Follow Hermes WebUI's documented systemd foreground service. Keep the WebUI
# independent of Tailscale readiness; the private interface can reconnect
# without blocking the local HTTP process.
install -m 0644 /dev/null "$SERVICE_FILE"
printf '%s\n' \
  '[Unit]' \
  'Description=Hermes Web UI' \
  'After=network.target' \
  '' \
  '[Service]' \
  'Type=simple' \
  'User=hermes' \
  'Group=hermes' \
  'Environment=HOME=/home/hermes' \
  'Environment=PATH=/home/hermes/.local/bin:/home/hermes/.hermes/bin:/usr/local/bin:/usr/bin:/bin' \
  "Environment=HERMES_WEBUI_PYTHON=$HERMES_PYTHON" \
  'Environment=PYTHONUNBUFFERED=1' \
  'WorkingDirectory=/home/hermes/hermes-webui' \
  'ExecStart=/bin/bash /home/hermes/hermes-webui/start.sh --foreground' \
  'Restart=on-failure' \
  'RestartSec=5' \
  'StandardOutput=journal' \
  'StandardError=journal' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable hermes-webui.service
systemctl restart hermes-webui.service

HEALTH_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 3 http://127.0.0.1:8787/health >/dev/null; then
    HEALTH_OK=1
    break
  fi
  sleep 2
done

if [ "$HEALTH_OK" -ne 1 ]; then
  systemctl --no-pager --full status hermes-webui.service || true
  journalctl -u hermes-webui.service -n 120 --no-pager || true
  exit 1
fi

PASSWORD="$(sed -n 's/^HERMES_WEBUI_PASSWORD=//p' "$ENV_FILE" | head -n 1)"
WRONG_AUTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"password":"this-is-not-the-generated-password"}' \
  http://127.0.0.1:8787/api/auth/login)"
if [ "$WRONG_AUTH_CODE" != "401" ] && [ "$WRONG_AUTH_CODE" != "403" ]; then
  printf 'Password rejection check failed with HTTP %s.\n' "$WRONG_AUTH_CODE" >&2
  exit 1
fi

curl -fsS \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg password "$PASSWORD" '{password:$password}')" \
  http://127.0.0.1:8787/api/auth/login >/dev/null

if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" != "Running" ]; then
  printf 'Tailscale is not connected.\n' >&2
  exit 1
fi

TAIL_IP="$(tailscale ip -4 | head -n 1)"
if ! curl -fsS --max-time 5 "http://$TAIL_IP:8787/health" >/dev/null; then
  printf 'WebUI is healthy locally but not on the Tailscale address.\n' >&2
  exit 1
fi

SERVER_URL="http://$TAIL_IP:8787"
DNS_NAME="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
if [ -n "$DNS_NAME" ] && tailscale serve --bg 8787 >/dev/null 2>&1; then
  SERVER_URL="https://$DNS_NAME"
fi

printf 'HERMES_REPAIR_COMPLETE\n'
printf 'SERVER_URL=%s\n' "$SERVER_URL"
printf 'TAILSCALE_IP=%s\n' "$TAIL_IP"
printf 'PASSWORD_FILE=%s\n' "$HERMES_HOME/webui-password.txt"
printf 'SERVICE_STATUS=%s\n' "$(systemctl is-active hermes-webui.service)"
curl -fsS --max-time 5 "http://$TAIL_IP:8787/health"
printf '\n'
