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

- **VPN (recommended, and required for safety):** put both machines on a mesh VPN like
  [Tailscale](https://tailscale.com) or ZeroTier, then have the remote player
  `--online <host-tailscale-ip>`. Simple and private.
- **Port forwarding:** forward UDP **7777** on the host's router to the host machine, give the
  remote player your public IP: `--online <public-ip>`.

> ⚠️ **Security:** the ENet transport is **unencrypted** in this prototype, and the auth token
> crosses it (short-lived; the refresh token stays on the client). Only play over a **trusted
> network or VPN** — do **not** expose the server on the public internet as-is. Production needs
> ENet DTLS.

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
- Loot/inventory writes use the player's token + per-rarity stat caps; full server-only writes
  (service-role) are deferred production hardening.
- No chat rate abuse (1.4 msg/s/player) and equip is rate-limited + serialized.
- `--autowalk` is a debug flag (a bot that fights, chats, and equips) used by the test scripts.
