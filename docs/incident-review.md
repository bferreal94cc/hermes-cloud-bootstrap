# Failed deployment review and replacement decision

Date: 2026-07-16

## Observed failures

The previous deployment never reached a verified serving state. The evidence
captured during troubleshooting showed several distinct failures:

- Browser-based Google SSH initially returned `403`, then later connected.
- The VM repeatedly received `504` from `pkgs.tailscale.com`, even though
  GitHub, PyPI, Astral, and the Hermes installer endpoint returned `200`.
- Tailscale authorization eventually succeeded and assigned the VM
  `100.109.167.52`.
- Tailscale Serve was disabled on the tailnet, so direct private-Tailscale HTTP
  was required.
- Local checks repeatedly returned `connection refused` on
  `127.0.0.1:8787`.
- `hermes-webui.service` remained `activating`; the WebUI process exited and
  restarted without ever establishing a listener.
- Reboot/SSH key churn made the repair loop difficult to observe and did not
  correct the application failure.

The old password visible during troubleshooting is intentionally not recorded
in this repository. The clean deployment generates a new credential.

## Root-cause assessment

The deployment combined three moving parts without an end-to-end gate:

1. an unpinned native Hermes Agent installer and managed virtual environment;
2. a separately updated WebUI checkout and foreground systemd wrapper; and
3. a Tailscale installation path that failed partway through on the package
   endpoint and was then repaired with copied binaries.

That left systemd able to restart a process whose runtime dependencies or
startup contract were not satisfied. A service state such as `activating` was
treated as progress, although the decisive network check still showed no
listener. Additional RAM could not fix that configuration/runtime mismatch.

## Replacement design

The rebuilt deployment removes those ambiguous states:

- Exact reviewed Agent and WebUI commits are the only accepted sources.
- WebUI's upstream-recommended single-container Docker path supplies its Python
  runtime and dependency installation behavior.
- The Agent source is mounted read-only into the WebUI container.
- Docker cannot publish `8787` until a valid `100.64.0.0/10` Tailscale address
  exists.
- No public Compute Engine firewall rule is created.
- A generated password is mandatory in Compose and saved mode `0600`.
- Verification requires exact source SHAs, local and Tailscale health,
  container health, wrong-password rejection, and correct-password acceptance.
- Only after every check passes is the server URL written to the status file.
- The existing VM remains intact until the replacement is proven from the
  iPhone.

## Recovery assets

Before repository synchronization, each existing default branch was preserved
as `backup/pre-rebuild-2026-07-16`.

The old VM is not deleted by the bootstrap code. Retirement is a separate,
explicit action after the replacement has passed verification and the Hermex
app connects successfully.
