# Testing Legends MMO

`./play.sh` is the launcher. It assumes Godot at `~/.local/bin/godot`; override with
`GODOT=/path/to/godot ./play.sh …`.

## 1. Quickest — single player (no server, no network)
```
./play.sh            # or: open project.godot in Godot and press F5
```
Log in, pick a class + name (first time), and you're in a local practice world as your
character. Good for trying movement, abilities, and the camera.

Demo account that already has a character:
**`legends_smoke1@testmail.dev` / `Testpass1234!`** — or click **Sign Up** (signups log you
straight in, no email confirmation).

## 2. Two players on one machine
```
./play.sh zone       # starts a headless zone server + opens two player windows
```
Log into **a different account in each window** (sign up a fresh one in the second). You'll see
both characters in the same world. Each account has exactly one character (one class).

To do it by hand instead:
```
godot --headless --path . -- --server        # terminal 1: the zone (no window — that's normal)
godot --path . -- --online                    # terminal 2: player 1 (connects to 127.0.0.1)
godot --path . -- --online                    # terminal 3: player 2
```

## 3. Another person / another machine (LAN)
On the **host** machine:
```
godot --headless --path . -- --server         # find the host's LAN IP, e.g. 192.168.1.50
```
Open **UDP port 7777** in the host's firewall. Everyone else (on the same network) runs:
```
godot --path . -- --online 192.168.1.50
```
Each player signs up their own account in their client.

## 4. A remote user over the internet
There is **no matchmaking/relay** — clients connect straight to the host over ENet/UDP. Two options:

- **VPN (simplest):** put both machines on a mesh VPN like [Tailscale](https://tailscale.com) or
  ZeroTier, then `--online <host-tailscale-ip>`. The VPN encrypts everything; no `--dtls` needed.
- **Public host + DTLS:** if you expose a port to the internet, **encrypt the transport** by
  passing `--dtls` on the server **and** every client. The server self-generates a certificate;
  clients encrypt but don't verify it (stops passive snooping of the auth token — see the note).
  ```
  # host (forward UDP 7777 to this machine, or run on a cloud VM):
  godot --headless --path . -- --server --dtls
  # remote player:
  godot --path . -- --online <public-ip> --dtls
  ```

> ⚠️ **Security:** `--dtls` encrypts the link. It does **not** verify the server identity (no MITM
> protection yet), so prefer a VPN or a host you control. The short-lived access token crosses the
> wire; the refresh token never leaves the client. Don't run a wide-open public server long-term.

## 5. Hosting the server (Docker / cloud)
A `Dockerfile` builds a self-contained headless server (downloads Godot, imports assets, runs `--server --dtls`):
```
docker build -t legends-zone .
docker run -e SUPABASE_SERVICE_KEY=<service_role> -p 7777:7777/udp legends-zone
```
**`SUPABASE_SERVICE_KEY`** (Supabase → Settings → API → `service_role`) is required for loot and
equipment to persist: the server is the only writer of the `inventory` table — clients are denied
direct writes, so items can't be forged. Without the key the server still runs but warns and loot
won't save. On Fly: `fly secrets set SUPABASE_SERVICE_KEY=<key>`. Locally: put it in a gitignored
`.env` (see `.env.example`) — `play.sh` loads it.
Deploy that image anywhere that runs containers with a **UDP** port:
- **A VPS** (Hetzner / Oracle Cloud free ARM / DigitalOcean) — `docker run -p 7777:7777/udp` it,
  open UDP 7777. Simplest and most reliable (binds `0.0.0.0`, no special config).
- **Fly.io** — a starting `fly.toml` is included (`fly apps create … && fly ips allocate-v4 && fly
  deploy`). UDP on Fly needs a **dedicated IPv4** and the `fly-global-services` bind (the toml sets
  `BIND` for that). If routing misbehaves, fall back to the VPS path.
- **Scale-up:** the same image runs on a game-server orchestrator (Hathora, Edgegap, or Agones/K8s).
  Run several zone instances and put a small lobby/gateway in front — the engine, netcode, and
  Supabase persistence don't change.

Common flags: `--port <n>` (bind/connect port), `--dtls` (encrypt), `--bind <ip>` (server bind
address, for hosts that need one), `--online <ip>` (client target).

## In-world controls (zone)
`WASD` move · `1`–`5` abilities · `LMB` basic · `RMB`-drag camera · wheel zoom ·
`Enter` chat · `I` inventory (click items to equip/unequip).

## What works right now (all 5 phases)
Accounts + one locked class per character · a shared persistent zone where players coexist with
interest-managed snapshots · active mobs with aggro/leash on a level/tier gradient · kill → XP →
level-up (+HP) · loot drops that persist · equip gear to boost your stats · zone chat ·
server-authoritative position/XP/loot/equipment persistence to Supabase.

## Notes & known limits (prototype)
- One character per account (class is permanent).
- Inventory is **server-authoritative**: only the zone server writes it (service_role via
  `SUPABASE_SERVICE_KEY`) — clients can't forge items. Set that env var or loot/equip won't persist.
- No chat rate abuse (1.4 msg/s/player) and equip is rate-limited + serialized.
- `--autowalk` is a debug flag (a bot that fights, chats, and equips) used by the test scripts.
