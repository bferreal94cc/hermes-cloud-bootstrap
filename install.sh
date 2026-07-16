#!/usr/bin/env bash
set -Eeuo pipefail

readonly BOOTSTRAP_REPOSITORY="bferreal94cc/hermes-cloud-bootstrap"
readonly HERMES_STACK_ROOT="${HERMES_STACK_ROOT:-/opt/hermes-stack}"
readonly HERMES_CONFIG_ROOT="${HERMES_CONFIG_ROOT:-/etc/hermes-stack}"
readonly HERMES_STATE_ROOT="${HERMES_STATE_ROOT:-/var/lib/hermes-stack}"
readonly HERMES_BOOTSTRAP_REF="${HERMES_BOOTSTRAP_REF:-main}"
readonly TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-hermes-agent-vm-v2}"
readonly ORIGINAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR"
TEMP_BOOTSTRAP_DIR=""
export DEBIAN_FRONTEND=noninteractive

log() {
  printf '[hermes-bootstrap] %s\n' "$*"
}

die() {
  printf '[hermes-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_BOOTSTRAP_DIR" && -d "$TEMP_BOOTSTRAP_DIR" ]]; then
    rm -rf -- "$TEMP_BOOTSTRAP_DIR"
  fi
}
trap cleanup EXIT

if [[ "$(id -u)" -ne 0 ]]; then
  die 'run this installer as root'
fi

download_bootstrap_file() {
  local relative_path="$1" destination="$2"
  local url="https://raw.githubusercontent.com/${BOOTSTRAP_REPOSITORY}/${HERMES_BOOTSTRAP_REF}/${relative_path}"
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
    --connect-timeout 20 --max-time 180 \
    "$url" -o "$destination"
}

if [[ ! -f "$SCRIPT_DIR/versions.env" ]]; then
  TEMP_BOOTSTRAP_DIR="$(mktemp -d /tmp/hermes-bootstrap.XXXXXX)"
  SCRIPT_DIR="$TEMP_BOOTSTRAP_DIR"
  download_bootstrap_file versions.env "$SCRIPT_DIR/versions.env"
fi

# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

for variable_name in HERMES_AGENT_REPO HERMES_AGENT_REF HERMES_WEBUI_REPO HERMES_WEBUI_REF TAILSCALE_VERSION; do
  [[ -n "${!variable_name:-}" ]] || die "missing ${variable_name} in versions.env"
done
[[ "$HERMES_AGENT_REF" =~ ^[0-9a-f]{40}$ ]] || die 'Hermes Agent ref must be an exact commit SHA'
[[ "$HERMES_WEBUI_REF" =~ ^[0-9a-f]{40}$ ]] || die 'Hermes WebUI ref must be an exact commit SHA'

ensure_bootstrap_asset() {
  local relative_path="$1"
  if [[ ! -f "$SCRIPT_DIR/$relative_path" ]]; then
    install -d -m 0755 "$(dirname "$SCRIPT_DIR/$relative_path")"
    download_bootstrap_file "$relative_path" "$SCRIPT_DIR/$relative_path"
  fi
}

for asset in compose.yaml scripts/start-stack.sh scripts/verify.sh scripts/status.sh; do
  ensure_bootstrap_asset "$asset"
done

install_docker() {
  log 'Installing Docker Engine from Docker’s official Debian repository.'
  apt-get update
  apt-get install -y ca-certificates curl git jq openssl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
    https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck source=/dev/null
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "this installer requires Debian; detected ${ID:-unknown}"
  local architecture codename
  architecture="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:-}"
  [[ -n "$codename" ]] || die 'could not determine the Debian codename'

  printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/debian' \
    "Suites: $codename" \
    'Components: stable' \
    "Architectures: $architecture" \
    'Signed-By: /etc/apt/keyrings/docker.asc' \
    > /etc/apt/sources.list.d/docker.sources

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker.service containerd.service
  docker compose version >/dev/null
}

install_tailscale_binary_fallback() {
  local image="docker.io/tailscale/tailscale:v${TAILSCALE_VERSION}"
  local container_id=""

  log "Official Tailscale package endpoint was unavailable; using official pinned container v${TAILSCALE_VERSION}."
  docker pull "$image"
  container_id="$(docker create "$image")"
  trap '[[ -z "${container_id:-}" ]] || docker rm -f "$container_id" >/dev/null 2>&1 || true; cleanup' EXIT
  docker cp "$container_id:/usr/local/bin/tailscale" /usr/local/bin/tailscale
  docker cp "$container_id:/usr/local/bin/tailscaled" /usr/local/bin/tailscaled
  docker rm "$container_id" >/dev/null
  container_id=""
  chmod 0755 /usr/local/bin/tailscale /usr/local/bin/tailscaled

  # A failed package installer can leave a repository that makes every later
  # apt update fail with the same gateway error. The pinned binary fallback is
  # self-contained, so disable only those incomplete Tailscale source files.
  for source_file in \
      /etc/apt/sources.list.d/tailscale.list \
      /etc/apt/sources.list.d/tailscale.sources; do
    if [[ -f "$source_file" ]]; then
      mv "$source_file" "${source_file}.disabled"
    fi
  done

  install -d -m 0700 /var/lib/tailscale
  install -d -m 0755 /run/tailscale
  install -m 0644 /dev/null /etc/systemd/system/tailscaled.service
  printf '%s\n' \
    '[Unit]' \
    'Description=Tailscale node agent' \
    'Documentation=https://tailscale.com/kb/' \
    'Wants=network-pre.target' \
    'After=network-pre.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    'RuntimeDirectory=tailscale' \
    'RuntimeDirectoryMode=0755' \
    'ExecStart=/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock' \
    'Restart=on-failure' \
    'RestartSec=5' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > /etc/systemd/system/tailscaled.service
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
    log 'Tailscale binaries are already installed.'
  else
    log 'Installing Tailscale with its official Linux installer.'
    local installer=""
    installer="$(mktemp /tmp/tailscale-install.XXXXXX)"
    if curl -fsSL --retry 5 --retry-delay 6 --retry-all-errors \
        --connect-timeout 20 --max-time 180 \
        https://tailscale.com/install.sh -o "$installer" \
        && sh "$installer"; then
      rm -f -- "$installer"
    else
      rm -f -- "$installer"
      install_tailscale_binary_fallback
    fi
  fi

  systemctl daemon-reload
  systemctl enable --now tailscaled.service
}

install_pinned_checkout() {
  local repository="$1" ref="$2" destination="$3" label="$4"
  local staging="${destination}.new"
  local previous="${destination}.previous"

  case "$destination" in
    "$HERMES_STACK_ROOT"/sources/*) ;;
    *) die "refusing unmanaged source destination: $destination" ;;
  esac

  rm -rf -- "$staging"
  git clone --filter=blob:none --no-checkout "$repository" "$staging"
  (
    cd "$staging"
    if [[ "$label" == 'Hermes Agent' ]]; then
      git checkout --detach "$HERMES_AGENT_REF"
    else
      git checkout --detach "$HERMES_WEBUI_REF"
    fi
    [[ "$(git rev-parse HEAD)" == "$ref" ]] || exit 1
  ) || die "$label checkout did not resolve to $ref"

  rm -rf -- "$previous"
  if [[ -e "$destination" ]]; then
    mv "$destination" "$previous"
  fi
  mv "$staging" "$destination"
  rm -rf -- "$previous"
}

install_stack_sources() {
  log 'Installing reviewed Hermes sources at exact commits.'
  install -d -m 0755 "$HERMES_STACK_ROOT/sources"
  install_pinned_checkout "$HERMES_AGENT_REPO" "$HERMES_AGENT_REF" \
    "$HERMES_STACK_ROOT/sources/hermes-agent" 'Hermes Agent'
  install_pinned_checkout "$HERMES_WEBUI_REPO" "$HERMES_WEBUI_REF" \
    "$HERMES_STACK_ROOT/sources/hermes-webui" 'Hermes WebUI'
}

install_stack_files() {
  log 'Installing the Compose definition and lifecycle scripts.'
  install -d -m 0755 "$HERMES_STACK_ROOT/scripts" "$HERMES_CONFIG_ROOT"
  install -d -m 0750 "$HERMES_STATE_ROOT/hermes-home" "$HERMES_STATE_ROOT/workspace"
  chown -R 1000:1000 "$HERMES_STATE_ROOT/hermes-home" "$HERMES_STATE_ROOT/workspace"

  install -m 0644 "$SCRIPT_DIR/versions.env" "$HERMES_STACK_ROOT/versions.env"
  install -m 0644 "$SCRIPT_DIR/compose.yaml" "$HERMES_STACK_ROOT/compose.yaml"
  install -m 0755 "$SCRIPT_DIR/scripts/start-stack.sh" "$HERMES_STACK_ROOT/scripts/start-stack.sh"
  install -m 0755 "$SCRIPT_DIR/scripts/verify.sh" "$HERMES_STACK_ROOT/scripts/verify.sh"
  install -m 0755 "$SCRIPT_DIR/scripts/status.sh" "$HERMES_STACK_ROOT/scripts/status.sh"

  local runtime_env="$HERMES_CONFIG_ROOT/runtime.env"
  if [[ -f "$runtime_env" ]]; then
    # shellcheck source=/dev/null
    source "$runtime_env"
  fi
  if [[ ! "${HERMES_WEBUI_PASSWORD:-}" =~ ^[0-9a-f]{64}$ ]]; then
    HERMES_WEBUI_PASSWORD="$(openssl rand -hex 32)"
  fi
  umask 077
  printf 'HERMES_WEBUI_PASSWORD=%s\n' "$HERMES_WEBUI_PASSWORD" > "$runtime_env"
  chmod 0600 "$runtime_env"
}

install_systemd_service() {
  log 'Configuring reboot-safe Hermes stack startup.'
  install -m 0644 /dev/null /etc/systemd/system/hermes-stack.service
  printf '%s\n' \
    '[Unit]' \
    'Description=Hermes Agent WebUI stack' \
    'Wants=network-online.target' \
    'After=network-online.target docker.service tailscaled.service' \
    'Requires=docker.service tailscaled.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'EnvironmentFile=/etc/hermes-stack/runtime.env' \
    'ExecStart=/opt/hermes-stack/scripts/start-stack.sh' \
    'ExecStop=/usr/bin/docker compose --env-file /etc/hermes-stack/compose.env -f /opt/hermes-stack/compose.yaml down' \
    'RemainAfterExit=yes' \
    'Restart=on-failure' \
    'RestartSec=15' \
    'TimeoutStartSec=1800' \
    'TimeoutStopSec=120' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > /etc/systemd/system/hermes-stack.service

  systemctl daemon-reload
  systemctl enable hermes-stack.service
}

request_tailscale_authorization() {
  install -d -m 0700 "$HERMES_STATE_ROOT"
  local auth_file="$HERMES_STATE_ROOT/tailscale-auth.txt"
  local backend_state=""
  backend_state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)"
  if [[ "$backend_state" == 'Running' ]]; then
    : > "$auth_file"
    chmod 0600 "$auth_file"
    return 0
  fi

  log 'Tailscale needs one-time authorization.'
  timeout 25 tailscale up --hostname="$TAILSCALE_HOSTNAME" > "$auth_file" 2>&1 || true
  chmod 0600 "$auth_file"
  local login_url=""
  login_url="$(grep -Eo 'https://login\.tailscale\.com/[a-zA-Z0-9/?=_&.-]+' "$auth_file" | head -n 1 || true)"
  if [[ -n "$login_url" ]]; then
    printf '\nTAILSCALE_AUTH_URL=%s\n\n' "$login_url"
  else
    log "Authorization output is saved at $auth_file."
  fi
}

install_docker
install_tailscale
install_stack_sources
install_stack_files
install_systemd_service
request_tailscale_authorization

# This is intentionally non-blocking: on a new node, systemd keeps retrying
# until the owner approves the one-time Tailscale URL.
systemctl start --no-block hermes-stack.service

log 'Installation staged successfully.'
log 'The current VM has not been modified or deleted by this repository.'
log 'After Tailscale authorization, status is available with:'
printf '  sudo %s/scripts/status.sh --show-password\n' "$HERMES_STACK_ROOT"
