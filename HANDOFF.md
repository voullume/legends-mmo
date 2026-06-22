# Legends of the Arena — Handoff & MMORPG Roadmap

> **⚠️ HISTORICAL — read `CLAUDE.md` first for current status.** This document is the *original*
> handoff that kicked off the MMO. **The roadmap in §6 (phases 1–5) is now COMPLETE** — netcode,
> Supabase accounts/persistence, the shared zone, parties, economy, admin tools, and a measured
> balance pass are all built, reviewed, and deployed live. The sections below remain useful as the
> **reusable-systems reference** (the combat engine, the Meshy asset pipeline, gltf-transform rules,
> GDScript gotchas) — those are all still accurate. For *what exists now and what's next*, see `CLAUDE.md`.

> **Read this first.** This repo is a **prototype** built to conceptualize a sports-themed
> action game. The real goal is an **MMORPG**. This document captures everything worth
> carrying forward, plus a proposed architecture + incremental roadmap to build the MMO.
> The git history (`git log`) is the full build story; the code + assets are the real
> deliverable (not any chat transcript).

---

## 1. What this prototype is

A **deterministic, server-style combat simulation** with a 3D viewer in **Godot 4.6**.
You pick two teams of sports-classed fighters (1v1–5v5) on one of 5 venues and watch a
fully auto-resolved battle. It exists to validate the **class design, ability balance,
art direction, and asset pipeline** — all of which transfer to the MMO.

- Engine: **Godot 4.6.3-stable** (`~/.local/bin/godot`), GDScript only.
- Run: open `project.godot`, F5. Main scene: `main.tscn` (root script `scripts/Arena.gd`).
- It is **single-player / no networking / no persistence** — that's the MMO's job.

## 2. The vision (MMORPG)

Sports-fantasy world where classes are armored athlete-warriors (Baseball / Football /
Volleyball / Soccer, 2 classes each). The combat *feel* and *content* are proven here;
the MMO adds real-time control, many players, a shared world, and progression.

---

## 3. What exists and is reusable

### Combat engine (the gameplay brain — port this to the server)
| File | Lines | Role |
|---|---|---|
| `scripts/GameData.gd` | 218 | **Source of truth**: 8 classes, their stats + abilities, 5 venues (`MAPS`), arena dims. Start here. |
| `scripts/Sim.gd` | 392 | Match loop: `create_match(compA, compB, seed, mapId)` + `sim_tick(state, dt)`. Deterministic. |
| `scripts/AI.gd` | 273 | Targeting, movement, ability selection. |
| `scripts/Abilities.gd` | 208 | Ability resolution (projectile/melee/buff/heal/zone/barrier/dash…). |
| `scripts/Combat.gd` | 142 | Damage pipeline; emits `dmg`/`kill` events (used by viewer for FX + stats). |
| `scripts/Geom.gd`, `scripts/Rng.gd` | 29/34 | Geometry helpers; **mulberry32 RNG** (byte-identical determinism). |

- The sim is **deterministic**: same comps + seed + map ⇒ identical match. Great for a
  server-authoritative MMO (cheap to validate/replay). It runs **headless** already.
- Class/ability data is plain dictionaries — easy to extend or move to a DB.

### Art & content
- `models/meshy/` — **4 rigged, animated characters** (baseball/football/volleyball/soccer),
  each with clips: idle, run, walk, attack, hit, death, throw, cast (soccer also kick).
  Animations are stored as extracted `.res` clips (`models/meshy/clips/`) merged onto one
  AnimationPlayer at runtime. Made via **Meshy image-to-3D** from the user's concept art.
- `models/meshy/props/stadium.glb` — Phase-3 signature landmark (Meshy text-to-3D trophy).
- `models/kits/` — **CC0** Kenney Nature + City Industrial props (trees/rocks/fences/buildings).
  See `models/kits/CREDITS.txt`. CC0 = no attribution required.
- `models/kaykit/` — CC0 KayKit Adventurers (the original placeholder characters; fallback).

### 3D viewer (reference for the MMO client renderer)
- `scripts/Arena.gd` (1697 lines) — rendering, the **kit-character abstraction**
  (`_make_character`), animation driving (`_drive_anim`), **impact/skill FX** (flash,
  knockback, sparks, damage numbers, cast auras, projectile trails — all pooled/procedural),
  orbit camera, the menu/team-builder/venue-picker, scoreboards, hit log, and the
  **History/Balance** system (per-class win%/damage/K-D, persisted to `user://history.json`).
  Treat this as a *rendering & UX reference*, not something to port verbatim.

### Design docs
- `docs/legends-combat-design.md` — the engine-agnostic combat design spec.
- `README.md` — prototype build progress.

---

## 4. Critical technical knowledge (don't relearn the hard way)

### Meshy (AI 3D asset generation)
- API key lives in **`~/.meshy_env`** (chmod 600, **NOT committed**). `source ~/.meshy_env`
  then `curl -H "Authorization: Bearer $MESHY_API_KEY" ...`. **The key is in the old chat's
  transcript — rotate it at meshy.ai if that chat may be shared.** Balance was ~**9,783**.
- Pipelines (Python orchestrators were in `/tmp/meshy_*.py`):
  - **Characters**: image-to-3D (`pose_mode:"t-pose"` from a front T-pose concept image) →
    rigging (`/openapi/v1/rigging`, gives walk/run free) → animations (`/openapi/v1/animations`,
    action IDs: idle 0, run 16, walk 30, attack 4, hit 178, death 8, throw 421, kick 410,
    Charged_Spell_Cast 125) → extract clips → optimize.
  - **Props (static)**: text-to-3D preview → refine (`/openapi/v2/text-to-3d`). No rig. Cheaper.
- **Concept-image tip the user proved:** front-facing **T-pose, plain background, full body**
  ⇒ great image-to-3D + clean rig.

### Asset optimization (gltf-transform)
- Installed at `~/.npm-global/bin/gltf-transform`. Use **resize (1024) + simplify**, then prune.
- **Never Draco-compress** — Godot 4.6 cannot import Draco glTF (it fails to load). Mesh
  *simplify* is fine (standard glTF). Meshopt unverified — avoid.
- Godot extracts embedded textures to `*_texture_0.png` on import; those PNGs are tracked
  dependencies — **don't delete them** or the GLB import breaks (restore via `git checkout`).

### Godot / GDScript gotchas
- Headless run: `godot --headless --path . --script res://x.gd` (custom `SceneTree`).
  Reimport: `godot --headless --import --path .`. Nuke cache: `rm -rf .godot/imported`.
- Autoloaded singletons aren't visible to a standalone `--script`; `preload(...)` them.
- `:=` can't infer from a Variant (dict access) — annotate (`var x: bool = dict[...] > 0`).
- Sim runs at 30 Hz; the viewer interpolates bodies + smooths rotation to avoid jitter.

---

## 5. Proposed MMORPG architecture (a starting point, not gospel)

**Server-authoritative** is the right model (cheating-resistant; the deterministic sim helps).

```
 Godot client (player) ──input──▶  Godot headless dedicated server  ──▶  Supabase (Postgres)
        ▲                          (world tick + combat = this sim)        accounts / characters
        └──── state snapshots ─────┘                                       inventory / progression
```

- **Server**: a headless Godot build running the world + combat. Reuse `Sim`/`Abilities`/
  `Combat` as the authoritative combat engine (it's already headless + deterministic).
- **Client**: Godot. Real-time input → sends intents; renders snapshots. Reuse the character
  kit, animation driving, and FX from `Arena.gd`.
- **Networking**: Godot **high-level multiplayer** (ENet/`MultiplayerAPI`) for real-time
  movement/combat. Server is the host; clients are peers with no authority.
- **Persistence/auth**: **Supabase** (already connected to this environment) — Postgres +
  Auth + Realtime. Store accounts, characters, inventory, progression. Use Realtime/Postgres
  for non-twitch data (chat, social, listings); keep twitch combat on ENet.
- **Content**: keep using Meshy for characters/props; CC0 kits for environment.

## 6. Incremental roadmap (how to get a "basic version" without drowning)

Build **one phase at a time** — each is roughly a chat or two. Don't attempt the whole MMO at once.

1. **Real-time control (single-player)** — replace the auto-sim with a player-controlled
   character: WASD/click move + ability buttons, driving the *existing* abilities/animations.
   No networking yet. *This is the single most important first step.*
2. **2-player networked combat** — server-authoritative duel using Godot multiplayer. Two
   clients, one server tick, state sync. Proves the netcode with content you already have.
3. **Accounts + character save** — Supabase auth + a `characters` table; log in, create/load
   a character (class, name, stats, position).
4. **A shared zone** — a small persistent overworld where several players coexist + can start
   matches/encounters. Interest management for many entities.
5. **MMO systems** — chat, parties, NPCs/mobs, loot/inventory, progression, an economy.

## 7. Project structure recommendation

Start the MMO as a **new Godot project / repo** (e.g. `~/legends-mmo`) for clean
client/server architecture. **Copy in** the reusable bits: `scripts/GameData.gd` + the
combat engine scripts, `models/meshy/` + `models/kits/`, and `docs/`. Leave this prototype
(`legends-arena`) intact as reference. (Alternatively, branch this repo — but a fresh
project avoids dragging the single-player viewer architecture into a networked codebase.)

## 8. First message for the new chat (suggested)

> "I'm building an MMORPG. Read `HANDOFF.md` and `docs/legends-combat-design.md` in
> `/home/e/legends-arena` (the prototype). I want to start **Phase 1: real-time
> player-controlled character** reusing the existing classes/abilities/animations, in a
> new Godot project at `~/legends-mmo`. Plan it, then let's build."

---

*Prototype status at handoff: 22 commits, 8 classes, 5 venues, 4 custom animated
characters, full impact/skill FX, match history/balance tool, 1 Meshy landmark (stadium).
Meshy balance ~9,783.*
