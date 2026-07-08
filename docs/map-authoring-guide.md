# Map Authoring Guide — Legends MMO

How to make zones deeper **yourself**, safely, without spending Meshy credits.

## ⭐ The fast path: the in-game editor (F4)

You do **not** have to hand-edit code to place scenery. Launch with one command and decorate by clicking:

```bash
./play.sh dev          # starts the server AND your client together; parse-checks maps first
```
Log in (`legends_smoke1@testmail.dev` / `Testpass1234!`), walk to the zone you want, then:

| Key / action | Does |
|---|---|
| **F4** | toggle decorate mode (also turns on the F3 coord readout; the panel sits top-right) |
| **`[` / `]`** | cycle the prop to place (trees, rocks, fences, buildings, cone, …) |
| **Left-click** | place the current prop on the ground where you point |
| **G** | **grab** the placed prop nearest the cursor → it follows the mouse; click or **G** again to drop |
| **`,` / `.`** | rotate (the grabbed prop if you're holding one, else the next placed) |
| **`-` / `=`** | raise / lower height |
| **PgUp / PgDn** | **lift up / down** — vertical offset, so a prop can sit *on top of* another (stacking) |
| **X** | delete the placed prop nearest the cursor |
| **Ctrl+Z** | **undo** the last place / delete / move |
| **Ctrl+S** | save this zone → `data/decals/<map>.json` |

Placements appear instantly and save to a **JSON data file the game loads at runtime** — so a mistake here
can **never break the game's scripts** (worst case: that one zone's decor doesn't load, with a clear
console note). To push your decor to players, commit the `data/decals/*.json` and deploy (client re-export).

**To stack** (e.g. a rock on a crate): place both, **G** to grab the top one and slide it over, then
**PgUp** to lift it until it rests on the lower one. **Ctrl+Z** anytime you overlap something by mistake.

Everything below is the **manual** path (editing `shared/World.gd` directly) — useful for gameplay tables
(mob camps, cover, portals, new zones) that the visual editor doesn't cover, and for understanding how it
all fits together. If a hand-edit ever breaks, run `./play.sh check` for a one-line diagnosis.

---

## 1. The model

The game is a 2-D top-down simulation rendered in 3-D. Every position is a `Vector2` in that zone's
own space: **origin top-left, `x` = east, `y` = south**, bounded by the zone's `w × h`. A zone is
spread across parallel `const` dicts in `shared/World.gd`, all keyed by the same map-name string:

| Table | Holds | Reaches the client via |
|---|---|---|
| `MAPS` | size (`w`/`h`), spawn, regen, aggro, pvp | size only (`arenaW/arenaH` in snapshot) |
| `PORTALS` | teleport pads + destinations | slim `{x,y,label}` list |
| `MOBS` | camps: `{class, level, tier, x, y}` | as spawned fighters |
| `OBSTACLES` | cover panels → **collision + line-of-sight** | ❌ client reads its **own** `World.gd` |
| `DECALS` | rings / cones / props — **pure visual** | ❌ client reads its **own** `World.gd` |

3-D mapping: sim `(x, y)` → world `((x - w/2)·SCALE, 0, (y - h/2)·SCALE)`, `SCALE = 0.05`, Y is up.

---

## 2. The one rule that stops you breaking anything

`World.gd` lives in `shared/`, so it is compiled into **both** the server and the client. The client
draws walls and decals from **its own copy** (they are not sent over the wire). The only real failure
mode is a **version mismatch** — server and client running different `World.gd` → phantom or invisible
walls, wrong decals.

> **Rule: ship both halves from the same git commit.** For a *decals-only* edit the server genuinely
> ignores `DECALS`, so a client re-export alone is enough — but shipping both keeps them identical and
> is the habit that never bites.

**Risk ladder:** `DECALS` 🟢 → `MOBS` 🟡 → `MAPS` / `OBSTACLES` 🔴 (🔴 = client renders it locally, so a
drift shows up in-game).

---

## 3. Start here — free depth, zero gameplay risk (`DECALS`)

`DECALS[<map>]` is purely cosmetic (no collision, client-side). Three kinds:

```gdscript
{"kind": "ring", "x": 480.0, "y": 300.0, "r": 110.0}                          # painted yellow ground ring
{"kind": "cone", "x": 340.0, "y": 300.0}                                      # orange traffic cone
{"kind": "prop", "model": "tree_oak", "x": 110.0, "y": 470.0, "h": 3.4, "yaw": 0.3}   # any GLB, NO collision
```

- `h` = target height in world units (the loader auto-scales and auto-grounds from the model's bounds —
  you never hand-tune the vertical offset; just pick `h` and `yaw` in radians).
- A worked example lives in `World.gd` under `HOME:` (home had none) — copy/tweak it.
- `home` and `arena` are the easiest first canvases.

### Free props you can drop right now (no Meshy credits)

The prop loader searches, in order: `models/meshy/props/` → `models/kits/nature/` → `models/kits/city/`.
Reference any of these by **bare basename** in a `"prop"` decal (or an `OBSTACLES` panel):

**Meshy (heavy, PBR — good as focal cover, don't scatter):** `bag`, `barrier`, `rack`, `stadium`

**Kenney CC0 nature (tiny, vertex-colored — scatter freely):**
`tree_default`, `tree_oak`, `tree_thin`, `tree_pineRoundC`, `tree_palmDetailedTall`,
`rock_largeA`, `rock_largeC`, `rock_largeE`, `rock_tallC`, `stone_largeB`,
`plant_bush`, `plant_bushLarge`, `grass_large`, `flower_redA`, `flower_yellowB`, `log_stack`,
`fence_simple`, `fence_planks`, `fence_corner`

**Kenney CC0 city (industrial):**
`building-a`, `building-c`, `building-e`, `building-h`, `building-k`, `building-n`, `building-q`,
`building-t`, `chimney-small`, `chimney-medium`, `chimney-large`, `detail-tank`

> To add a **brand-new** GLB: drop `<name>.glb` into any of those three folders, run
> `godot --headless --path . --import`, keep the Godot-extracted `*_texture_*.png` sidecars (tracked
> deps — don't delete), then reference it by basename. New *sourced* assets should be surfaced for
> approval first (per `CLAUDE.md`); the existing kits are already vendored + CC0.

---

## 4. Finding coordinates — the F3 dev overlay

Press **F3** in-game (works in both the online client and the sandbox) to toggle a readout that prints
the **sim-space coordinate under your cursor** — the exact numbers you type into `World.gd`:

```
🗺  glitchyard_1    x 742    y 418    (bounds 1500×850)
```

Point at where you want a prop, read the `x`/`y`, paste. No guessing.

---

## 5. The safe test loop (never touch live until it looks right)

```bash
# 1) compile-check (boots through Main.gd, which parses Client + NetClient + World)
godot --headless --path . --import
timeout 20 godot --headless --path . -- --server 2>&1 | grep -i "script error" || echo "✓ clean"

# 2) run it locally and LOOK
./play.sh server         # terminal A — headless server that DOES load your zones
./play.sh online         # terminal B — a client on your local server
#   login (demo):  legends_smoke1@testmail.dev / Testpass1234!
#   jump zones:    log in as admin@legends.dev, press F1 → goto buttons
```

⚠️ **Do NOT** test with bare `./play.sh` or `--practice` — that path loads a fixed sandbox venue
("stadium"), **not** your real zones, so map edits look unchanged there no matter what.

---

## 6. Ship it (only after it looks right locally)

```bash
git add shared/World.gd client/Client.gd client/NetClient.gd
git commit -m "maps: ..."          # branch off main first if you like
git push origin main
gh run watch <run-id> --exit-status   # WAIT for CI to build the server image, or you deploy stale code
ssh root@159.89.132.86 'curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash'
# re-export + upload the clients:
godot --headless --path . --export-release "Linux"   dist/Legends-Linux-x86_64.x86_64
godot --headless --path . --export-release "Windows Desktop" dist/Legends-Windows-x86_64.exe
gh release upload v0.1.0-test dist/Legends-Linux-x86_64.x86_64 dist/Legends-Windows-x86_64.exe --clobber
./play.sh join 159.89.132.86       # verify against live
```

---

## 7. Going deeper — the gameplay tables (🔴 redeploy both halves)

- **`OBSTACLES[<map>]`** — real cover (blocks movement + boss line-of-sight). Panel shape
  `{x, y, "prop": "barrier"|"rack"|"bag", "len": <sim-length>, "yaw": <rad>}`; `yaw: 1.5708` = a N–S wall.
  `circles_from()` auto-builds the collision circles from the **same** data that renders the mesh, so
  they always align — never hand-place circles. A **new** obstacle prop id needs a row in `PROP_DIM`
  (its native footprint) or the collision won't match the model.
- **`MOBS[<map>]`** — camps (server-authoritative → server redeploy). `class` must exist in
  `GameData.CLASSES`; `tier` is `minion`/`elite`/`boss`; `level` sets difficulty (scaling is automatic —
  no new stat blocks). Keep camps **> 320 apart** (`AGGRO_RANGE`) so one pull doesn't chain the next.
  Add `"objective": true` to make a mob's death complete an instance run.
- **`MAPS[<map>].w/h`** — resize; re-check every camp/portal/prop still sits inside the new bounds.
- **A whole new zone:** add a name const + `MAPS` entry (all keys) + a spawn `Vector2` const +
  `PORTALS` in **both** directions (forward pad with `to`/`tx`/`ty`, back pad returning; keep each
  drop-point **> 42** = `PORTAL_RADIUS` from the return pad so you don't bounce) + optional
  `MOBS`/`OBSTACLES`/`DECALS`. Then also add the zone's display name in `NetClient._zone_name`, and
  (optional) an admin goto button + a music track. The server auto-creates the world from the new
  `MAPS` key on redeploy. Test the full portal round-trip locally first.

Home-base services (shop/forge/quest-giver/practice) are **home-only** hardcoded consts, and every
related server RPC hard-checks `map == HOME` — you can't add them to another zone by data alone.

---

## 8. Gotchas

- **GDScript uses TABS.** Copy an existing entry line and edit the numbers; verify with `sed -n … | cat -A`.
- Coordinates are in each zone's **own** space (see its `w`/`h` in `MAPS`). Keep everything inside the bounds.
- The online client does **not** run the sim (it renders server snapshots), so there's no lockstep/RNG
  desync to worry about — only the `World.gd` content-mismatch above.
- `DECALS`/`OBSTACLES` are read from the client's local `World.gd` (the snapshot omits them), so a stale
  client shows wrong geometry. Always deploy both halves from the same commit.
