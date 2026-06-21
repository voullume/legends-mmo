# CLAUDE.md — Legends MMO

An **MMORPG** in **Godot 4.6**, built on the proven combat engine + assets from the
**Legends of the Arena** prototype (`~/legends-arena`). **Read `HANDOFF.md`** for the full
design, the reusable systems, the architecture, and the phased roadmap. Combat spec:
`docs/legends-combat-design.md`. The prototype's 3D viewer (`~/legends-arena/scripts/Arena.gd`)
is the reference for rendering, the character/animation kit, and the impact/skill FX.

## 🎯 Current focus — Phase 1
A **single, local, player-controlled fighter** (no networking yet): real-time movement +
abilities reusing the existing classes (`shared/GameData.gd`) and Meshy characters/animations.
Build this before any netcode. Roadmap (HANDOFF.md): ① real-time control → ② 2-player netcode
→ ③ Supabase accounts/save → ④ shared zone → ⑤ MMO systems.

## Layout
- `shared/` — the **deterministic combat engine** copied from the prototype (GameData, Sim,
  AI, Abilities, Combat, Geom, Rng). Used by both client and server. `GameData.gd` = content
  source of truth (8 classes, abilities, stats, 5 venues).
- `server/Server.gd` — authoritative host skeleton (ENet + world tick via `shared/Sim.gd`).
- `client/Client.gd`, `client/Player.gd` — client + player skeletons (Phase 1 lives here).
- `Main.gd` / `Main.tscn` — boots server with `--server`, else client.
- `models/meshy/` — 4 rigged+animated characters (+ `clips/`, + `props/`). `models/kits/` — CC0 props.

## Architecture (target)
**Server-authoritative**: Godot headless dedicated server owns world+combat (reuse the
deterministic `shared/` engine); clients send input, render snapshots (Godot high-level
multiplayer / ENet). **Supabase** (connected in this environment) for auth + Postgres +
realtime (accounts, characters, inventory, progression).

## Run / test
- Client: open `project.godot` in Godot, F5. Server: `godot --headless -- --server`.
- Headless test: `godot --headless --path . --script res://x.gd` (extend `SceneTree`;
  `preload(...)` shared scripts). Import assets: `godot --headless --import --path .`.
  **Run `--import` first** (assets were copied without import metadata). Check `grep -c 'SCRIPT ERROR'`.

## Conventions / gotchas (carried from the prototype — don't relearn)
- **Meshy** AI 3D gen: key in `~/.meshy_env` (not committed; `source` it). Characters =
  image-to-3D (front T-pose concept art) → rig → animate; props = text-to-3D → refine.
  **Report the credit balance after any Meshy op.** Rig hand bone = `RightHand` (tiny ~0.02 scale).
- **Optimize GLBs** with `~/.npm-global/bin/gltf-transform` (resize 1024 + simplify). **Never
  Draco** (Godot 4.6 can't import it). Don't delete Godot-extracted `*_texture_0.png` (tracked deps).
- `:=` can't infer from dict access (Variant) — annotate types.
- The combat engine is deterministic (mulberry32 RNG) — same inputs ⇒ same result (great for a server).
- For **sourced/CC0 assets**, surface for approval before integrating.
