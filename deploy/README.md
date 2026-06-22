# Deploying the zone server to a VPS

One script (`deploy/setup.sh`) does everything: installs Docker, builds the server image, opens
the firewall, and runs the container (auto-restart, DTLS encryption). ~5 minutes on a fresh box.

## What you need
- A small **x86_64 / amd64** Ubuntu 22.04 or 24.04 VPS. 1 vCPU / 1 GB RAM is plenty for testing.
  ⚠️ **Not ARM.** The image uses the x86_64 Godot build, so pick an Intel/AMD instance. (Heads-up:
  Oracle Cloud's *free* tier is ARM — it won't work without changes. DigitalOcean/Hetzner/Vultr/
  Linode basic droplets are x86_64 and fine.)
- This repo on **GitHub** (public is simplest) so the box can clone it. Don't have it there yet?
  **Ask me — I can push it for you.**
- Your Supabase **`service_role`** key (Settings → API).

## Steps
1. Create the VPS, SSH in.
2. Run:
   ```bash
   export SUPABASE_SERVICE_KEY="eyJ...your-service-role-key..."
   export REPO_URL="https://github.com/voullume/legends-mmo.git"
   curl -fsSL "https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh" | sudo -E bash
   ```
3. It prints the connect command when it finishes.
4. **Also open UDP 7777 in your provider's firewall / security group** — most clouds (DigitalOcean,
   AWS, GCP, Oracle…) have a firewall in front of the VM, separate from the box's own `ufw`.

## Players connect
```bash
godot --path . -- --online <VPS-IP> --dtls
```
Each tester signs up their own account in-client (instant, no email). One character per account.

## Managing it
| | |
|---|---|
| Live logs | `docker logs -f legends-zone` |
| Restart / stop | `docker restart legends-zone` · `docker stop legends-zone` |
| Update to latest | re-run the one-liner — it pulls, rebuilds, restarts (the service key is remembered, so no env vars needed after the first time) |

## No GitHub? Upload the code instead
From your machine, copy the repo up and run the script without `REPO_URL`:
```bash
rsync -a --exclude .git --exclude .godot ./ root@<VPS-IP>:/opt/legends-mmo/
ssh root@<VPS-IP> 'SUPABASE_SERVICE_KEY="eyJ..." bash /opt/legends-mmo/deploy/setup.sh'
```

## Security reminders
- The `service_role` key is a secret — it only ever lives as the `-e SUPABASE_SERVICE_KEY` env var
  on the server (the script never writes it to disk). Rotate it before a real public launch.
- DTLS encrypts the link but doesn't verify server identity (no MITM protection yet) — fine for a
  box you control; for stronger guarantees, keep testers on a VPN.
