#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
COMPOSE="$ROOT/compose.yaml"
START="$ROOT/scripts/start-stack.sh"
VERIFY="$ROOT/scripts/verify.sh"
STATUS="$ROOT/scripts/status.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: ${1#"$ROOT/"}"
}

require_text() {
  local file="$1" text="$2" message="$3"
  grep -Fq -- "$text" "$file" || fail "$message"
}

reject_text() {
  local file="$1" text="$2" message="$3"
  if grep -Fq -- "$text" "$file"; then
    fail "$message"
  fi
}

for file in "$INSTALL" "$COMPOSE" "$START" "$VERIFY" "$STATUS"; do
  require_file "$file"
done

require_text "$INSTALL" 'source "$SCRIPT_DIR/versions.env"' \
  'installer must consume the reviewed source pins'
require_text "$INSTALL" 'https://download.docker.com/linux/debian/gpg' \
  'installer must use Docker official Debian signing key'
require_text "$INSTALL" 'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
  'installer must install Docker Engine and Compose from the official repository'
require_text "$INSTALL" 'https://tailscale.com/install.sh' \
  'installer must use Tailscale official Linux installer'
require_text "$INSTALL" 'openssl rand -hex 32' \
  'installer must generate a strong WebUI password'
require_text "$INSTALL" 'chmod 0600' \
  'installer must protect generated credentials'
require_text "$INSTALL" 'git checkout --detach "$HERMES_AGENT_REF"' \
  'installer must check out the exact Hermes Agent commit'
require_text "$INSTALL" 'git checkout --detach "$HERMES_WEBUI_REF"' \
  'installer must check out the exact Hermes WebUI commit'
require_text "$INSTALL" 'systemctl enable hermes-stack.service' \
  'installer must enable reboot auto-start'
require_text "$INSTALL" 'systemctl start --no-block hermes-stack.service' \
  'installer must not block startup while Tailscale authorization is pending'

require_text "$COMPOSE" '"127.0.0.1:8787:8787"' \
  'Compose must publish a loopback-only health/Serve endpoint'
require_text "$COMPOSE" '"${TAILSCALE_IP:?Tailscale IPv4 is required}:8787:8787"' \
  'Compose must publish directly on the private Tailscale address'
require_text "$COMPOSE" '${HERMES_AGENT_SOURCE_DIR:?Hermes Agent source is required}:/home/hermeswebui/.hermes/hermes-agent:ro' \
  'WebUI must mount the pinned Hermes Agent source read-only'
require_text "$COMPOSE" 'HERMES_WEBUI_PASSWORD: ${HERMES_WEBUI_PASSWORD:?WebUI password is required}' \
  'Compose must require password authentication'
require_text "$COMPOSE" 'test: ["CMD", "bash", "/app/scripts/lib/health_probe.sh", "localhost", "8787", "/health", "2"]' \
  'Compose must define a container health check'

require_text "$START" 'tailscale ip -4' \
  'startup must resolve the live Tailscale address'
require_text "$START" 'docker compose build --pull' \
  'startup must build the pinned WebUI source'
require_text "$START" 'docker compose up -d --remove-orphans' \
  'startup must launch the managed stack'
require_text "$START" 'scripts/verify.sh' \
  'startup must run the full verification gate'

require_text "$VERIFY" 'http://127.0.0.1:8787/health' \
  'verification must check local health'
require_text "$VERIFY" 'http://$TAILSCALE_IP:8787/health' \
  'verification must check Tailscale-IP health'
require_text "$VERIFY" 'this-password-must-be-rejected' \
  'verification must test incorrect-password rejection'
require_text "$VERIFY" '/api/auth/login' \
  'verification must test authentication'
require_text "$VERIFY" 'git -C "$HERMES_AGENT_SOURCE_DIR" rev-parse HEAD' \
  'verification must prove the deployed Hermes Agent SHA'
require_text "$VERIFY" 'git -C "$HERMES_WEBUI_SOURCE_DIR" rev-parse HEAD' \
  'verification must prove the deployed WebUI SHA'
require_text "$VERIFY" 'docker inspect' \
  'verification must inspect container health'

for file in "$INSTALL" "$COMPOSE" "$START" "$VERIFY" "$STATUS"; do
  reject_text "$file" '0.0.0.0:8787' \
    'port 8787 must never bind to every host interface'
  reject_text "$file" 'ufw allow 8787' \
    'installer must not create a public firewall opening'
  reject_text "$file" 'gcloud compute firewall-rules' \
    'installer must not create a public Compute Engine firewall opening'
  reject_text "$file" ':latest' \
    'floating latest image references are forbidden'
done

reject_text "$INSTALL" "printf 'PASSWORD=%s" \
  'installer must not print the generated password'

bash -n "$INSTALL" "$START" "$VERIFY" "$STATUS"
printf 'PASS: deterministic installer contract\n'
