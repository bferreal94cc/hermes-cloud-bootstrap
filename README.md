# Hermes on Google Compute Engine

Deterministic deployment of the official Hermes Agent and Hermes WebUI for the
Hermex iPhone app. The WebUI is password-protected and reachable only through
Tailscale. Cloudflare and public port `8787` firewall rules are intentionally
not used.

## Reviewed source pins

The deployment consumes exact commits from the three upstream projects. See
[`versions.env`](versions.env) for the machine-readable pins.

| Component | Official source | Commit |
| --- | --- | --- |
| Hermes Agent | `NousResearch/hermes-agent` | `311a5b0a552be78f5c58807e2be1db02e3badcb0` |
| Hermes WebUI | `nesquena/hermes-webui` | `11773af0e3e4fcdcdbb1fde7a73c1c97ef208430` |
| Hermex iOS client | `uzairansaruzi/hermex` | `11c5ac5f4c4371df5ce70e33790e7bc95d7169f1` |

The installer checks out the Agent and WebUI in detached-HEAD mode and the
verification gate proves both deployed SHAs before writing a success status.

## Target VM

- Google Compute Engine, not App Engine
- Debian 12
- `e2-standard-2` (2 vCPU, 8 GB RAM)
- No public ingress rule for port `8787`
- Docker Engine and Compose from Docker's official Debian repository
- Tailscale from its official Linux installer, with a pinned official-image
  fallback for networks where `pkgs.tailscale.com` returns a gateway error

The old VM should remain available until this parallel replacement passes all
checks and the iPhone successfully connects.

## What the installer does

1. Installs Docker and Tailscale.
2. Clones the exact reviewed Hermes Agent and WebUI commits.
3. Generates a 64-character random WebUI password and saves it root-only at
   `/etc/hermes-stack/runtime.env`.
4. Builds the upstream WebUI single-container image with the pinned Agent
   source mounted read-only.
5. Publishes port `8787` only on `127.0.0.1` and the VM's `100.64.0.0/10`
   Tailscale address.
6. Verifies source SHAs, both health endpoints, container health, bad-password
   rejection, and correct-password acceptance.
7. Tries Tailscale Serve for HTTPS; direct Tailscale HTTP remains available for
   Hermex even if Serve is disabled on the tailnet.
8. Enables `hermes-stack.service` so the stack returns after reboot.

## Install

Run the installer from a pinned bootstrap commit in instance startup metadata:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
export HERMES_BOOTSTRAP_REF=BOOTSTRAP_COMMIT_SHA
curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  "https://raw.githubusercontent.com/bferreal94cc/hermes-cloud-bootstrap/${HERMES_BOOTSTRAP_REF}/install.sh" \
  | bash
```

`BOOTSTRAP_COMMIT_SHA` must be replaced with the exact reviewed commit. The VM
startup log prints a one-time Tailscale authorization URL if the node is not
already on the tailnet. No password or Tailscale auth key is committed to Git.

## Verification and credentials

After Tailscale is authorized, systemd automatically retries the stack. Inspect
the final result on the VM:

```bash
sudo /opt/hermes-stack/scripts/status.sh --show-password
```

Expected fields:

```text
SERVER_URL=http://100.x.y.z:8787
TAILSCALE_IP=100.x.y.z
SERVICE_STATUS=active
CONTAINER_STATUS=healthy
PASSWORD=<64-character generated value>
```

If Tailscale Serve is enabled, `SERVER_URL` will instead be the private
`https://<machine>.<tailnet>.ts.net` address.

For a direct independent check:

```bash
curl -fsS "http://$(tailscale ip -4):8787/health"
```

## iPhone / Hermex

1. Install Tailscale on the iPhone and sign in to the same tailnet.
2. Keep Tailscale connected.
3. In Hermex, add the exact `SERVER_URL` shown by the status command.
4. Paste the generated `PASSWORD` exactly.

Direct `http://100.x.y.z:8787` is private inside Tailscale; it is not public
internet HTTP. Hermex explicitly supports direct Tailscale IP addresses.

## Local validation

```bash
bash tests/test_repository.sh
bash tests/test_install.sh
git diff --check
```

The workflow in `.github/workflows/validate.yml` runs the same contract on each
push and pull request.
