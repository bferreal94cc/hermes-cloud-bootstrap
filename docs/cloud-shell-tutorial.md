# Finish the Hermes VM deployment

<walkthrough-tutorial-duration duration="30"></walkthrough-tutorial-duration>

The 8-GB VM and reviewed GitHub sources already exist. This final Google-owned
Cloud Shell step attaches the startup metadata that the connected Compute tool
cannot set.

## Run the deployment

If Google asks you to authorize Cloud Shell, select **Authorize**. Then run:

```bash
bash cloud-shell-deploy.sh
```

The script checks the VM size, attaches the pinned startup script, restarts the
VM, and waits for the Tailscale URL.

## Approve Tailscale

Open the `https://login.tailscale.com/...` URL printed in the terminal and
approve `hermes-agent-vm-v2`. No terminal input is required after approval.

The same script waits for the upstream Docker build and all health/auth checks.
When it finishes, it prints exactly the `SERVER_URL` and `PASSWORD` to enter in
Hermex and saves them in `~/hermes-connection.txt`. The VM keeps installing if
the iPhone disconnects from Cloud Shell.
