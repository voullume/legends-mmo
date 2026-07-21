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
uniques+procs, salvage/forge/reforge/craft — only sockets+gems P4d deferred), **AI residents** (11
server-side companion "players"), **Builder Mode / Locker Rooms**, the **UI overhaul + DPS/HPS meter**,
the **combat-feel** pass, the **gameplay-length program** (XP economy, level-gated kits, talents,
Paragon, Bounty Board, Difficulty Pass v1 — `docs/gameplay-length-handoff.md`), **Phase 8 "The Away
Circuit"** (away_1-3 + boss + the Finals district; S4 slot owner-reserved for a special boss), the
**64 full-color ability icons** (v1.8.3), and the **Wildlife Expanse workstream** (below). *(The live
world is now **16 zones** + instance templates.)*

## 🐾 The Wildlife Expanse (2026-07-20..21, v1.8.4→v1.11.3) — COMPLETE
The away biome is the owner's **Wildlife Expanse**: all 7 owner-built creatures live (skink / grazer /
forager / magpie normals, warfrog + splinterback elites, the **Arrowbound Howler** pack-boss — shield-bird
Pack Call + Bristling Arrows parry-cycle puzzle, NO cores by design), **pure-wildlife roster** (legacy
elites retired to their GY/finals homes; rival_coach/rival_core/rally_cone defs dormant), **wild_gate**
(zone 2 entered through gy5_command; pre-W6 chars grandfathered at the old L8 floor), and the **Base Camp
hub** (`basecamp`: tier-2 shop ilvl 17 / rolls capped at 13, forge, quest giver #2 + WILD chain,
`World.SERVICE_PADS` registry replaced the HOME service hardcodes). Spec + open items:
`docs/wildlife-expanse-zone2-plan.md`. `bal_identity` stayed byte-identical across all 12 ships.

## ▶ Now — the owner's map flesh-out / art pass
Next focus is **owner-directed**: zone ground/props re-skins (ground DONE in art-pass A1;
~~sports-prop remap~~ DONE in A3 — client-only WILD_PROP_SWAP), ~~Base Camp decor~~ (DONE in A2 —
data/decals/basecamp.json, ships server+client), elite model differentiation,
death-anim pass-3 (warfrog/howler), and
the playtest feel-pass items listed in the plan doc. **Standing vetoes:** P7a sockets+gems is
**owner-deferred — do not build it**; the jump/verticality gate stays **closed** (cosmetic hop only —
`docs/jump-verticality-phase1-decision.md`). Tackle one phase per chat.

## Layout
- `shared/` — the **deterministic combat engine** (GameData, Sim, AI, Abilities, Combat, Geom, Rng)
  + `World.gd` (the 16-zone world: MAPS/PORTALS/MOBS/OBSTACLES + `SERVICE_PADS` per-map service
  registry + gates). `GameData.gd` = content source of truth (8 classes + 33 mob defs, abilities,
  stats, venues, **`FORMAT_MODS`**, recipes, dyes).
- `server/Server.gd` — the authoritative zone server (worlds, tick, snapshots, auth, persistence,
  loot, equip, parties, shop, admin).
- `client/` — `Client.gd` (base render / local sandbox), `NetClient.gd` (the networked client: HUD,
  chat, inventory, skill bar, party, shop, admin panel), `Player.gd` (input→intent), `Net.gd` (RPCs),
  `Supabase.gd` (REST auth + DB).
- `Main.gd` — boots the server with `--server`, else the client (`--online <ip>` connects).
- `supabase/migrations/` — schema (characters, inventory, admins; RLS). `deploy/setup.sh` — VPS deploy.
- `models/meshy/` — 4 rigged characters (+ `clips/`, `props/`) and `mobs/rigged/` (the 7 wildlife
  quadruped rigs + per-role clip `.res`; metadata in Client.gd `RIGGED_MOBS`). `models/kits/` — CC0 props.

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
- **Key suites** (all headless `--script`): `stab_away` (away biome + gates), `stab_basecamp` (hub
  services), `test_wildlife_normals` (wildlife defs/rosters/boss mechanics), `test_class_kits`
  (player kits + the **mob-def golden hash** — see conventions), `bal_identity` (player-sim
  byte-identity — run it for EVERY shared/ change and compare signatures).
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
- **Mob-def golden hash** (`test_class_kits.gd`): every mob def is fingerprinted. Adding/changing a
  def means REBASING the golden — always prove the untouched subset first (hash-minus-the-change must
  equal the prior golden) and record the chain in the const comment. Mobs tune via World.MOBS
  level/tier + per-def hpMult/dmgScale — **never** FORMAT_MODS entries.
- **Releases**: every deploy goes through `deploy/release.sh [patch|minor|major]` (tag + client
  publish — VERIFY `gh release view` after; the publish step can fail silently), then wait for CI
  before the droplet redeploy (it pulls `:latest` — check the image age). Shared changes ship server
  + client together.
- After each substantial feature: compile-check, a headless/connect test, then an **adversarial review**
  (Workflow) before considering it done. For **sourced/CC0 assets**, surface for approval first.
