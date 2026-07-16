#!/usr/bin/env bash
set -Eeuo pipefail

HERMES_USER="hermes"
HERMES_HOME="/home/hermes/.hermes"
WEBUI_DIR="/home/hermes/hermes-webui"
PASSWORD=""

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git jq openssl python3 python3-pip python3-venv

if ! id -u "$HERMES_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$HERMES_USER"
fi

install -d -o "$HERMES_USER" -g "$HERMES_USER" \
  "$HERMES_HOME" \
  "$HERMES_HOME/webui" \
  "/home/hermes/workspace"

if [ -s "$HERMES_HOME/webui-password.txt" ]; then
  PASSWORD="$(head -n 1 "$HERMES_HOME/webui-password.txt")"
else
  PASSWORD="$(openssl rand -hex 24)"
fi

if ! command -v tailscale >/dev/null 2>&1; then
  if ! curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors \
    https://tailscale.com/install.sh | sh; then
    printf 'Tailscale package host is unavailable; installing official v1.98.8 binaries from its container image.\n'
    apt-get install -y docker.io
    systemctl enable --now docker
    TAILSCALE_IMAGE="docker.io/tailscale/tailscale:v1.98.8"
    if ! docker pull "$TAILSCALE_IMAGE"; then
      TAILSCALE_IMAGE="ghcr.io/tailscale/tailscale:v1.98.8"
      docker pull "$TAILSCALE_IMAGE"
    fi
    TAILSCALE_CONTAINER="$(docker create "$TAILSCALE_IMAGE")"
    docker cp "$TAILSCALE_CONTAINER:/usr/local/bin/tailscale" /usr/local/bin/tailscale
    docker cp "$TAILSCALE_CONTAINER:/usr/local/bin/tailscaled" /usr/local/bin/tailscaled
    docker rm "$TAILSCALE_CONTAINER"
    chmod 0755 /usr/local/bin/tailscale /usr/local/bin/tailscaled
    install -d -m 0755 /var/lib/tailscale

    install -m 0644 /dev/null /etc/systemd/system/tailscaled.service
    printf '%s\n' \
      '[Unit]' \
      'Description=Tailscale node agent' \
      'Documentation=https://tailscale.com/kb/' \
      'Wants=network-pre.target' \
      'After=network-pre.target' \
      '' \
      '[Service]' \
      'Type=notify' \
      'RuntimeDirectory=tailscale' \
      'RuntimeDirectoryMode=0755' \
      'ExecStart=/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock' \
      'Restart=on-failure' \
      'RestartSec=5' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' \
      > /etc/systemd/system/tailscaled.service
    systemctl daemon-reload
    systemctl disable --now docker || true
  fi
fi
systemctl enable --now tailscaled

if [ ! -f "$HERMES_HOME/hermes-agent/run_agent.py" ]; then
  HERMES_INSTALLED=0
  for ATTEMPT in $(seq 1 6); do
    if runuser -u "$HERMES_USER" -- env \
      HOME=/home/hermes \
      HERMES_HOME="$HERMES_HOME" \
      bash -lc 'curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --non-interactive --skip-browser'; then
      HERMES_INSTALLED=1
      break
    fi
    printf 'Hermes download attempt %s failed; retrying in 10 seconds.\n' "$ATTEMPT"
    sleep 10
  done
  if [ "$HERMES_INSTALLED" -ne 1 ]; then
    printf 'Hermes installation failed after six attempts.\n'
    exit 1
  fi
fi

if [ -d "$WEBUI_DIR/.git" ]; then
  runuser -u "$HERMES_USER" -- env HOME=/home/hermes \
    git -C "$WEBUI_DIR" pull --ff-only
else
  WEBUI_CLONED=0
  for ATTEMPT in $(seq 1 6); do
    if runuser -u "$HERMES_USER" -- env HOME=/home/hermes GIT_TERMINAL_PROMPT=0 \
      git clone --depth 1 https://github.com/nesquena/hermes-webui.git "$WEBUI_DIR"; then
      WEBUI_CLONED=1
      break
    fi
    rm -rf "$WEBUI_DIR"
    printf 'WebUI download attempt %s failed; retrying in 10 seconds.\n' "$ATTEMPT"
    sleep 10
  done
  if [ "$WEBUI_CLONED" -ne 1 ]; then
    printf 'WebUI download failed after six attempts.\n'
    exit 1
  fi
fi

install -o "$HERMES_USER" -g "$HERMES_USER" -m 600 /dev/null "$WEBUI_DIR/.env"
printf '%s\n' \
  "HERMES_HOME=$HERMES_HOME" \
  "HERMES_WEBUI_AGENT_DIR=$HERMES_HOME/hermes-agent" \
  "HERMES_WEBUI_STATE_DIR=$HERMES_HOME/webui" \
  "HERMES_WEBUI_DEFAULT_WORKSPACE=/home/hermes/workspace" \
  "HERMES_WEBUI_HOST=127.0.0.1" \
  "HERMES_WEBUI_PORT=8787" \
  "HERMES_WEBUI_PASSWORD=$PASSWORD" \
  "HERMES_WEBUI_SECURE=true" \
  "HERMES_WEBUI_TRUST_FORWARDED_HOST=true" \
  "HERMES_WEBUI_TRUST_FORWARDED_PROTO=true" \
  > "$WEBUI_DIR/.env"
chown "$HERMES_USER:$HERMES_USER" "$WEBUI_DIR/.env"

install -o "$HERMES_USER" -g "$HERMES_USER" -m 600 /dev/null "$HERMES_HOME/webui-password.txt"
printf '%s\n' "$PASSWORD" > "$HERMES_HOME/webui-password.txt"
chown "$HERMES_USER:$HERMES_USER" "$HERMES_HOME/webui-password.txt"

install -m 644 /dev/null /etc/systemd/system/hermes-webui.service
printf '%s\n' \
  '[Unit]' \
  'Description=Hermes Web UI' \
  'Wants=network-online.target' \
  'After=network-online.target tailscaled.service' \
  '' \
  '[Service]' \
  'Type=simple' \
  'User=hermes' \
  'Group=hermes' \
  'Environment=HOME=/home/hermes' \
  'Environment=PATH=/home/hermes/.local/bin:/home/hermes/.hermes/bin:/usr/local/bin:/usr/bin:/bin' \
  'WorkingDirectory=/home/hermes/hermes-webui' \
  'ExecStart=/bin/bash /home/hermes/hermes-webui/start.sh --foreground' \
  'Restart=on-failure' \
  'RestartSec=5' \
  'NoNewPrivileges=true' \
  'PrivateTmp=true' \
  'ProtectSystem=full' \
  'ReadWritePaths=/home/hermes' \
  'StandardOutput=journal' \
  'StandardError=journal' \
  '' \
  '[Install]' \
  'WantedBy=multi-user.target' \
  > /etc/systemd/system/hermes-webui.service

systemctl daemon-reload
systemctl enable hermes-webui.service
systemctl restart hermes-webui.service

for _ in $(seq 1 90); do
  if curl -fsS http://127.0.0.1:8787/health >/dev/null; then
    break
  fi
  sleep 2
done

if ! curl -fsS http://127.0.0.1:8787/health >/dev/null; then
  journalctl -u hermes-webui.service -n 100 --no-pager
  exit 1
fi

WRONG_AUTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d '{"password":"this-is-not-the-generated-password"}' \
  http://127.0.0.1:8787/api/auth/login)"
if [ "$WRONG_AUTH_CODE" != "401" ] && [ "$WRONG_AUTH_CODE" != "403" ]; then
  printf 'Password authentication check failed; refusing to expose the WebUI. HTTP %s\n' "$WRONG_AUTH_CODE"
  exit 1
fi

curl -fsS \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg password "$PASSWORD" '{password:$password}')" \
  http://127.0.0.1:8787/api/auth/login >/dev/null

if [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')" != "Running" ]; then
  printf '\nTailscale needs authorization. Open the URL printed below, approve this VM, then return here.\n\n'
  tailscale up --hostname=hermes-agent-vm
fi

TAIL_IP="$(tailscale ip -4 | head -n 1)"
DNS_NAME="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
SERVER_URL=""
SERVE_ACTIVE=0

if tailscale serve --bg 8787; then
  SERVE_ACTIVE=1
  SERVER_URL="https://$DNS_NAME"

  # Add a tailnet-only HTTP listener so the requested tail-IP health check works.
  tailscale serve --http=8787 --bg 8787 || true
fi

if [ "$SERVE_ACTIVE" -eq 0 ]; then
  # Password authentication was configured and verified before this non-loopback bind.
  sed -i 's/^HERMES_WEBUI_HOST=.*/HERMES_WEBUI_HOST=0.0.0.0/' "$WEBUI_DIR/.env"
  sed -i 's/^HERMES_WEBUI_SECURE=.*/HERMES_WEBUI_SECURE=false/' "$WEBUI_DIR/.env"
  systemctl restart hermes-webui.service
  SERVER_URL="http://$TAIL_IP:8787"
fi

for _ in $(seq 1 30); do
  if curl -fsS "http://$TAIL_IP:8787/health" >/dev/null; then
    break
  fi
  sleep 2
done

if ! curl -fsS "http://$TAIL_IP:8787/health"; then
  if [ "$SERVE_ACTIVE" -eq 1 ]; then
    # Keep HTTPS Serve as the primary URL; this tailnet bind only satisfies direct IP health checks.
    sed -i 's/^HERMES_WEBUI_HOST=.*/HERMES_WEBUI_HOST=0.0.0.0/' "$WEBUI_DIR/.env"
    systemctl restart hermes-webui.service
    sleep 3
  fi
fi

if ! curl -fsS "http://$TAIL_IP:8787/health"; then
  journalctl -u hermes-webui.service -n 100 --no-pager
  exit 1
fi

printf '\n\nHERMES_SETUP_COMPLETE\n'
printf 'SERVER_URL=%s\n' "$SERVER_URL"
printf 'TAILSCALE_IP=%s\n' "$TAIL_IP"
printf 'PASSWORD=%s\n' "$PASSWORD"
printf 'PASSWORD_FILE=%s\n' "$HERMES_HOME/webui-password.txt"
printf 'SERVICE_STATUS=%s\n' "$(systemctl is-active hermes-webui.service)"
