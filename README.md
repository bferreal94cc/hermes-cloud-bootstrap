# Hermes Cloud Bootstrap

Installs Hermes Core and `nesquena/hermes-webui` on a Debian Google Compute
Engine VM, protects the WebUI with a generated password, and exposes it only
through Tailscale.

## Install

Run as root:

```bash
curl -fsSL https://raw.githubusercontent.com/bferreal94cc/hermes-cloud-bootstrap/main/install.sh | bash
```

The installer preserves an existing WebUI password, configures systemd
auto-start, tries Tailscale Serve first, and falls back to the VM's private
Tailscale IPv4 address only after password authentication passes.

## Repair an existing VM

`repair-webui.sh` is an idempotent repair for an installed VM. It pins the
WebUI to Hermes Core's managed Python 3.11 runtime, rebuilds the upstream-style
foreground systemd unit, verifies password rejection and acceptance, and
checks both localhost and Tailscale health.

```bash
curl -fsSL https://raw.githubusercontent.com/bferreal94cc/hermes-cloud-bootstrap/main/repair-webui.sh | bash
```

The repair never opens a public firewall port and does not print the saved
password into service logs.

## Regression checks

```bash
bash test-install.sh install.sh
bash test-repair-webui.sh repair-webui.sh
```
