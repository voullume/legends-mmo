# CLAUDE.md — Legends MMO

A **server-authoritative MMORPG** in **Godot 4.6** (GDScript), built on the deterministic combat
engine from the **Legends of the Arena** prototype (`~/legends-arena`). Sports-fantasy: 8 classes
(Baseball / Football / Volleyball / Soccer). **`HANDOFF.md`** holds the original design + the
still-accurate reusable-systems reference (Meshy pipeline, asset optimization). Combat spec:
`docs/legends-combat-design.md`.

## 🎯 Status — Phases 1–5 shipped, live + deployed
The original roadmap (real-time control → 2-player netcode → accounts/save → shared zone → MMO
systems) is **done**, each phase built, adversarially reviewed, and hardened:
- **Netcode** — server-authoritative ENet + **DTLS**, 30 Hz tick, interest-managed snapshots.
- **Supabase** — auth + persistence (characters, inventory, xp/level/credits). Server writes via
  `service_role`; clients are RLS-scoped.
- **Two worlds** — `home` (safe base: shop, training dummy, no aggro, strong regen) and `combat`
  (spread mob camps, aggro, 4× arena). A portal pad teleports between them.
- **Combat/UX** — abilities on keys **1–8**, **Tab** enemy target + **Ctrl+Tab / click party-frame**
  ally target (flat pulsing ground ring), loot drops + equip, MMO **skill bar** (cooldown sweep +
  computed-stat tooltips).
- **Parties** — invite by **right-clicking** a player, HUD frames w/ live HP, heal/buff targeting,
  Leave button. Rate-limited + serialized RPCs.
- **Economy** — **Credits** earned from kills; a home-zone **shop** (fixed catalog / random roll /
  sell-with-confirmation). **No trading by design** (avoids dupe/exploit surface).
- **Admin tools** — **F1** panel, gated by a service-role `admins` table: set level/xp/credits,
  give/clear items, god-mode (per-tick restore), heal, teleport, spawn/clear/**reset** mobs.
- **Balance** — all 8 classes tuned to ~50% AI-duel win rate via `FORMAT_MODS[5]` (measured with a
  deterministic round-robin harness, not guessed; was a 61-pt spread, now ~9).

## ✅ Shipped since Phase 5 (post-original-roadmap work — all live + deployed)
The items the old "Next up" listed as unbuilt have **all landed and deployed**: **party-based open-PvP**
(Arena, party-key hostility model — byte-identical when `pvp=false`), the **Glitchyard** content arc
(5-zone leveling chain → Head Coach raid → gated secret boss Head Coach PRIME), the **endgame program**
(instanced Camp Circuit + Intensity ladder + Playbook-Pages/Master-Key attunement + **level cap 30** +
3-category leaderboards + Two-Minute Drill), the **7-phase item system** (10 slots, 6 rarities, sets,
uniques+procs, salvage/forge/reforge/craft — only sockets+gems P4d deferred), **AI residents** (6
server-side companion "players"), **Builder Mode / Locker Rooms**, the **UI overhaul + DPS/HPS meter**,
and the **combat-feel** pass. *(The live world is now 9 zones + instance templates, superseding the
two-world layout in the Phase-1–5 summary above.)*

## ▶ Now building — expand gameplay length
Work-stream: **make the game last longer to play** (`docs/gameplay-length-handoff.md`; core flaw from the
2026-07-09 audit — the build was *finished at level 1*). **Phases 1–7 (+3a/3b, 7b/7c/7d) and Difficulty
Pass v1 SHIPPED 2026-07-09..07-11** (`0d88148`..`f2fea90`, `ec4250f`): XP economy, level-gated kits,
Camp-Circuit v2 + roster remix, talent trees, Paragon/Audibles, Bounty Board, procs/boss-scaling/seasons.
**Remaining: Phase 8 (second biome, XL) and P7a sockets+gems (never shipped).** Tackle one phase per chat.
*Side gate (closed):* jump/verticality shipped as the cosmetic + networked hop (Phases 0+0.5, protocol v2);
the owner **closed the Phase-1 gate 2026-07-13** — true verticality is not a pillar, Phases 2–4 are not
authorized. Sole re-open path: the *named-moment test* at Phase-8 planning + the `hops/min` health-log
counter. See `docs/jump-verticality-phase1-decision.md`.

## Layout
- `shared/` — the **deterministic combat engine** (GameData, Sim, AI, Abilities, Combat, Geom, Rng)
  + `World.gd` (two-world layout: maps, spawns, portals, mob camps, shop pad). `GameData.gd` =
  content source of truth (8 classes, abilities, stats, venues, **`FORMAT_MODS`**).
- `server/Server.gd` — the authoritative zone server (worlds, tick, snapshots, auth, persistence,
  loot, equip, parties, shop, admin).
- `client/` — `Client.gd` (base render / local sandbox), `NetClient.gd` (the networked client: HUD,
  chat, inventory, skill bar, party, shop, admin panel), `Player.gd` (input→intent), `Net.gd` (RPCs),
  `Supabase.gd` (REST auth + DB).
- `Main.gd` — boots the server with `--server`, else the client (`--online <ip>` connects).
- `supabase/migrations/` — schema (characters, inventory, admins; RLS). `deploy/setup.sh` — VPS deploy.
- `models/meshy/` — 4 rigged+animated characters (+ `clips/`, `props/`). `models/kits/` — CC0 props.

## Operational (this environment)
- **Supabase project**: `reaiolskmzorymnrbtab` (connected via MCP). Anon key embedded in `Supabase.gd`
  (public, safe). The **`service_role` key is server-only** (env `SUPABASE_SERVICE_KEY`, never
  committed — `.env` is gitignored).
- **Live server**: DigitalOcean droplet **159.89.132.86** (UDP 7777, DTLS). **Redeploy:**
  `curl -fsSL https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh | sudo -E bash`
  (idempotent: pulls `main`, rebuilds, restarts). SSH from this env works (`~/.ssh/id_ed25519`).
- **Accounts**: admin = **`admin@legends.dev`** (registered in the `admins` table → F1 tools); test
  bots = `legends_smoke1@testmail.dev` etc. **Never touch `voullume@proton.me`** (the user's real
  shared account — its password is off-limits).
- A **shared-engine change** (anything in `shared/`) needs **both** a server redeploy and a client
  re-launch; client-only changes just need a re-launch.

## Run / test
- Client: open `project.godot`, F5. Server: `godot --headless -- --server` (needs `SUPABASE_SERVICE_KEY`).
- Headless test: `godot --headless --path . --script res://x.gd` (extend `SceneTree`; `preload(...)`
  shared scripts). Import assets: `godot --headless --import --path .`. Check `grep -c 'SCRIPT ERROR'`.
- **Balance harness** — build the match state with `GameData.create_fighter(cls, team, 0, rng, 5)`
  (force `team_size=5` to match live `ZONE_TEAM_SIZE`) and loop `Sim.sim_tick` to a winner; run a
  round-robin across seeds/maps to measure win rates, then tune `FORMAT_MODS[5]`.

## Conventions / gotchas
- **Server-authoritative**: clients send intents, the server validates everything. Every client→server
  RPC that mutates state is **rate-limited + serialized** (`_chat_next`, `_equipping`/`_equip_next`,
  `_shop_busy`/`_shop_next`, `_party_invite_next`). New mutating RPCs **must** follow this — a review
  caught a sell-dupe money-printer from omitting it.
- The combat engine is **deterministic** (mulberry32 RNG) — same inputs ⇒ same result (great for the
  server and for balance testing).
- `FORMAT_MODS[team_size]` scales each class's dmg/hp per format; the live game is **format 5**
  (`ZONE_TEAM_SIZE`). Balance lives there, not in base stats. (Mods apply to players **and** mobs.)
- `:=` can't infer from a Variant (dict access, `await` result) — annotate (`var x: T = ...`).
- GDScript uses **TABS** — match indentation exactly when editing (`sed -n ... | cat -A` to verify).
- **Meshy** AI 3D gen: key in `~/.meshy_env` (`source` it; never print it). Characters = image-to-3D
  (front T-pose) → rig → animate; props = text-to-3D. **Report the credit balance after any Meshy op.**
- **Optimize GLBs** with `~/.npm-global/bin/gltf-transform` (resize 1024 + simplify). **Never Draco**
  (Godot 4.6 can't import it). Don't delete Godot-extracted `*_texture_0.png` (tracked deps).
- After each substantial feature: compile-check, a headless/connect test, then an **adversarial review**
  (Workflow) before considering it done. For **sourced/CC0 assets**, surface for approval first.
