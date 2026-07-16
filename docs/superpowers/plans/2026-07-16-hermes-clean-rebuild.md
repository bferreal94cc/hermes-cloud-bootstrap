# Hermes Clean Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the user-owned Hermes forks and failed VM deployment with a reproducible, password-protected Hermes Agent + Hermes WebUI stack reachable from Hermex over Tailscale.

**Architecture:** Preserve each current GitHub default branch on a dated backup branch, synchronize the Hermes Agent and Hermex forks to exact reviewed upstream commits, and replace the bootstrap repository with a pinned Docker Compose deployment. The VM host runs official Tailscale and Docker services; the WebUI runs in the upstream Python 3.12 image, mounts the pinned Hermes Agent source read-only, and publishes port 8787 only on loopback and the VM's Tailscale IPv4 address.

**Tech Stack:** Bash, Docker Engine and Compose, Python 3.12 upstream WebUI image, systemd, Tailscale, Google Compute Engine `e2-standard-2`, GitHub.

## Global Constraints

- Preserve recoverable GitHub backup branches before force-updating any default branch.
- Keep the existing VM until the replacement passes health and authentication verification.
- Use exact commit SHAs for Hermes Agent, Hermes WebUI, and Hermex; never deploy a floating `main`, `master`, or `latest` reference.
- Generate the WebUI password on the VM, store it mode `0600`, and never commit it.
- Never bind port 8787 to the VM's public interface.
- Bind port 8787 only to `127.0.0.1` and the active Tailscale IPv4 address.
- Verify incorrect-password rejection and correct-password acceptance before reporting a server URL.
- Do not use Cloudflare.

---

### Task 1: Pin reviewed upstream sources

**Files:**
- Create: `versions.env`
- Test: `tests/test_repository.sh`

**Interfaces:**
- Produces exact `HERMES_AGENT_REF`, `HERMES_WEBUI_REF`, and `HERMEX_REF` values consumed by installation and repository synchronization.

- [x] **Step 1: Add a failing repository check**

  Require all three references to be 40-character lowercase hexadecimal SHAs and reject floating branches/tags.

- [x] **Step 2: Run the check and confirm it fails because `versions.env` is absent**

  Run: `bash tests/test_repository.sh`

- [x] **Step 3: Add the reviewed repositories and exact commit SHAs**

  Pin Hermes Agent `311a5b0a552be78f5c58807e2be1db02e3badcb0`, Hermes WebUI `11773af0e3e4fcdcdbb1fde7a73c1c97ef208430`, and Hermex `11c5ac5f4c4371df5ce70e33790e7bc95d7169f1`.

- [x] **Step 4: Run the repository check and confirm it passes**

  Run: `bash tests/test_repository.sh`

### Task 2: Build the deterministic VM installer

**Files:**
- Replace: `install.sh`
- Create: `compose.yaml`
- Create: `scripts/start-stack.sh`
- Create: `scripts/verify.sh`
- Create: `scripts/status.sh`
- Test: `tests/test_install.sh`
- Remove: `repair-webui.sh`
- Remove: `test-install.sh`
- Remove: `test-repair-webui.sh`

**Interfaces:**
- Consumes: `versions.env`.
- Produces: `/opt/hermes-stack`, `hermes-stack.service`, a root-only generated credential file, a Tailscale authentication URL when needed, and a verified health/status report.

- [x] **Step 1: Add failing installer contract tests**

  Require supported Debian, official Docker and Tailscale installation paths, exact Git checkouts, a generated password, loopback/Tailscale-only port bindings, systemd auto-start, and health/auth checks. Reject `0.0.0.0:8787`, public firewall changes, floating image tags, and password logging.

- [x] **Step 2: Run the contract tests and confirm the legacy installer fails**

  Run: `bash tests/test_install.sh`

- [x] **Step 3: Replace the legacy native-Python service with the pinned container stack**

  Install Docker from its official Debian repository, install Tailscale from its official Linux path with retries, clone both upstream repositories at the pinned SHAs, generate the password, install the Compose and helper files under `/opt/hermes-stack`, and enable a systemd oneshot service that retries until Tailscale is authenticated.

- [x] **Step 4: Implement verified startup**

  Resolve the live Tailscale IPv4 address, render the root-only Compose environment, build the pinned WebUI image, start it, check container health, reject a wrong password, accept the generated password, verify `http://<tailscale-ip>:8787/health`, and attempt persistent Tailscale Serve without making it mandatory.

- [x] **Step 5: Run all installer tests and shell syntax checks**

  Run: `bash tests/test_install.sh && bash -n install.sh scripts/start-stack.sh scripts/verify.sh scripts/status.sh`

### Task 3: Document deployment and recovery

**Files:**
- Replace: `README.md`
- Create: `.github/workflows/validate.yml`

**Interfaces:**
- Documents the exact Google Cloud machine type, startup-script URL, Tailscale approval step, verification output, credential retrieval, update procedure, and rollback branches.

- [x] **Step 1: Replace the previous repair instructions with clean-deployment instructions**

  Document `e2-standard-2` (2 vCPU, 8 GB), Debian, the startup script, Tailscale approval, `/health`, authentication checks, and the Hermex URL formats.

- [x] **Step 2: Add CI validation**

  Run the repository and installer contract tests plus Bash syntax validation on pushes and pull requests.

- [x] **Step 3: Run the complete local suite**

  Run: `bash tests/test_repository.sh && bash tests/test_install.sh && git diff --check`

### Task 4: Preserve and synchronize GitHub repositories

**Files:**
- GitHub refs only; no additional local files.

**Interfaces:**
- Produces dated backup refs and synchronized default branches.

- [x] **Step 1: Create `backup/pre-rebuild-2026-07-16` in all three user repositories**

- [ ] **Step 2: Synchronize `bferreal94cc/hermes-agent:main` to the pinned Nous Research commit**

- [x] **Step 3: Synchronize `bferreal94cc/hermex:master` to the pinned upstream Hermex commit**

- [ ] **Step 4: Publish the validated bootstrap replacement to `bferreal94cc/hermes-cloud-bootstrap:main`**

- [ ] **Step 5: Fetch each resulting ref and verify its exact commit SHA**

### Task 5: Build and verify the replacement Google Compute Engine VM

**Files:**
- Google Cloud resources only.

**Interfaces:**
- Produces an `e2-standard-2` replacement VM and, after Tailscale approval, a verified Hermex server URL and password.

- [ ] **Step 1: Create a parallel replacement VM and preserve the current VM**

  Use project `chatgpt-agent-502515`, zone `us-west1-b`, and machine type `e2-standard-2`.

- [ ] **Step 2: Attach the reviewed startup script from the bootstrap repository**

  Use a non-floating commit URL so future repository changes cannot silently alter a running deployment.

- [ ] **Step 3: Complete the one-time Tailscale authorization**

  Open only the URL emitted by `tailscale up`; no authentication key is stored in GitHub.

- [ ] **Step 4: Verify the running deployment**

  Require container health, local health, Tailscale-IP health, wrong-password rejection, correct-password acceptance, auto-start enablement, exact source SHAs, and 8 GB machine type evidence.

- [ ] **Step 5: Retire the old VM only after all replacement checks pass**

  Stop the old VM first. Delete it only after the replacement remains healthy and the user confirms the iPhone app connects.

## Self-Review

- Scope covers all three requested GitHub repositories, the VM, Compute Engine sizing, Tailscale, password authentication, auto-start, Hermex compatibility, verification, and rollback.
- No destructive GitHub or VM operation occurs before a recoverable backup or verified replacement exists.
- The plan contains no floating dependency references and no Cloudflare dependency.
- The only unavoidable human step is approving the new Tailscale node through Tailscale's own authentication URL.
