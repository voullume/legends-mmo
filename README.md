# Legends MMO

An MMORPG built on the combat engine and assets proven in the **Legends of the Arena**
prototype (`~/legends-arena`). Sports-fantasy classes (Baseball / Football / Volleyball /
Soccer, 2 each); server-authoritative real-time combat.

> **New here? Read [`HANDOFF.md`](HANDOFF.md) and [`CLAUDE.md`](CLAUDE.md) first.**

## Status
Scaffold. The deterministic combat engine and custom characters are in place; the
networked client/server is being built **one phase at a time** — currently **Phase 1:
a local, player-controlled character**.

## Quick start
```bash
godot --headless --import --path .        # first time: import the copied assets
# Client (windowed): open project.godot in Godot and press F5
godot --headless -- --server              # dedicated server (later phases)
```

## Layout
| Path | What |
|---|---|
| `shared/` | Deterministic combat engine (GameData, Sim, AI, Abilities, Combat, Geom, Rng) — client + server |
| `server/` | Authoritative host (skeleton) |
| `client/` | Client + player-controlled fighter (skeleton; Phase 1) |
| `models/meshy/` | 4 rigged + animated characters, clips, props |
| `models/kits/` | CC0 environment props (Kenney) |
| `docs/` | Combat design spec |

## Roadmap
1. Real-time player control (single-player) ← **here**
2. 2-player networked combat (server-authoritative)
3. Supabase accounts + character save
4. A shared zone / overworld
5. MMO systems (chat, parties, mobs, loot, progression)
