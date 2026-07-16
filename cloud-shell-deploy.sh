#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_ID="${PROJECT_ID:-chatgpt-agent-502515}"
readonly INSTANCE_NAME="${INSTANCE_NAME:-hermes-agent-vm-v2}"
readonly ZONE="${ZONE:-us-west1-b}"
readonly STARTUP_WRAPPER_URL="https://raw.githubusercontent.com/bferreal94cc/hermes-cloud-bootstrap/main/gce-startup.sh"
readonly RESULT_FILE="${RESULT_FILE:-${HOME}/hermes-connection.txt}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v gcloud >/dev/null 2>&1 || die 'gcloud is required; run this from Google Cloud Shell'
if [[ -z "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)" ]]; then
  printf 'Google Cloud authorization is required once for this temporary shell.\n'
  gcloud auth login --brief
fi
[[ -n "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)" ]] \
  || die 'Google Cloud authorization did not complete'

machine_type="$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format='value(machineType.basename())')"
[[ "$machine_type" == 'e2-standard-2' ]] \
  || die "expected e2-standard-2 (8 GB), found ${machine_type:-unknown}"

startup_file="$(mktemp /tmp/hermes-gce-startup.XXXXXX)"
cleanup() {
  rm -f -- "$startup_file"
}
trap cleanup EXIT

curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  "$STARTUP_WRAPPER_URL" -o "$startup_file"
grep -Fq 'HERMES_BOOTSTRAP_REF=1a0066cb0f6470becbf8796b65a1a5d08ccd2bb6' "$startup_file" \
  || die 'downloaded startup wrapper does not contain the reviewed bootstrap pin'

printf 'Attaching the reviewed startup script to %s and restarting it.\n' "$INSTANCE_NAME"
gcloud compute instances add-metadata "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --metadata-from-file="startup-script=$startup_file" --quiet
gcloud compute instances reset "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" --quiet

printf 'Waiting for the one-time Tailscale authorization URL...\n'
auth_url=""
serial_output=""
for _ in $(seq 1 120); do
  serial_output="$(gcloud compute instances get-serial-port-output "$INSTANCE_NAME" \
    --project="$PROJECT_ID" --zone="$ZONE" --port=1 2>/dev/null || true)"
  auth_url="$(printf '%s\n' "$serial_output" \
    | grep -Eo 'https://login\.tailscale\.com/[a-zA-Z0-9/?=_&.-]+' \
    | tail -n 1 || true)"
  [[ -n "$auth_url" ]] && break
  sleep 10
done

if [[ -z "$auth_url" ]]; then
  printf '%s\n' "$serial_output" | tail -n 120 >&2
  die 'the VM did not emit a Tailscale authorization URL'
fi

printf '\nOpen this URL and approve %s:\n%s\n\n' "$INSTANCE_NAME" "$auth_url"
printf 'No terminal input is required. Approval is detected automatically.\n'

printf 'Waiting for Docker build, health, and password-auth verification...\n'
for _ in $(seq 1 120); do
  if result="$(gcloud compute ssh "$INSTANCE_NAME" \
      --project="$PROJECT_ID" --zone="$ZONE" --quiet \
      --command='sudo /opt/hermes-stack/scripts/status.sh --show-password' \
      2>/dev/null)"; then
    umask 077
    {
      printf 'HERMES_DEPLOYMENT_COMPLETE\n%s\n' "$result"
    } > "$RESULT_FILE"
    chmod 600 "$RESULT_FILE"
    printf '\n'
    cat "$RESULT_FILE"
    printf 'Saved securely at %s\n' "$RESULT_FILE"
    exit 0
  fi
  sleep 15
done

die 'Hermes did not complete verification within 30 minutes; inspect the VM serial log'
