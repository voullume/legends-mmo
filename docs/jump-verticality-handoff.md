# Jump / Verticality — Guided Handoff

**Created:** 2026-07-13 · **Status:** PLAN drafted, not started · **Predecessor state:** all systems
through the props + ground-textures pass are **shipped** (release `v1.0.1`, commit `09d1551`). This is
the next candidate work-stream, split out of the props handoff §D as its own project — as recommended,
because it is the **highest-risk change in the codebase.**

> Produced from a full parallel audit of the six subsystems verticality touches (sim/movement,
> AI/separation, abilities/LOS/projectiles, netcode/snapshots, client render/camera, maps/balance).
> Every claim below is cited to `file:line` and was spot-verified against live code on 2026-07-13.

---

## 1. The diagnosis — one line

**The combat engine is a *deterministic 2-D top-down simulation*, and "jump" means two completely
different projects with a 100× cost gap between them.**

A fighter is a plain Dictionary holding two scalar floats `x`, `y` (plus a 2-D heading `hx`/`hy` and an
int `facing`) — **there is no `z`, no height, and not even a velocity vector; movement is per-tick
position *accumulation*, not integration** (`shared/GameData.gd:699-702`, `shared/AI.gd:75-118`,
`shared/Sim.gd:711-762`). The 3-D view is a thin projection: `_world()` maps `(x,y) → (x, 0, y)` with the
middle component **hardcoded to `0.0`** (`client/Client.gd:628`). `Y` never round-trips into the sim.

So there are two "jumps":

| | **Cosmetic hop** | **True climbable height** |
|---|---|---|
| What it is | A visual bob/leap on the character mesh — juice | Real elevation that affects movement, reach, cover, LOS |
| Touches | `client/` only | `shared/` sim + netcode + balance + map authoring + content |
| Sim / determinism | **none** | rewrites the load-bearing core |
| Balance (`FORMAT_MODS[5]`) | **untouched** | **fully invalidated → mandatory re-tune** |
| Effort | ~1 session | multi-phase, weeks; fights the foundation |
| Risk | ~zero | very high (desync + balance + boss arenas) |

**The honest recommendation: ship the cosmetic hop, *then* decide whether true verticality is worth it.**
Most of what "jump" delivers to *feel* is the cosmetic hop. True height is a sim rewrite that the whole
deterministic-2-D design actively resists — do it only if verticality is a real *gameplay* pillar
(traversal puzzles, high-ground combat), not just because a jump button feels missing.

---

## 2. Guardrails (non-negotiable — every phase respects these)

1. **Determinism byte-identity is sacred.** `FORMAT_MODS[5]` was tuned to ~50% win rate on a deterministic
   AI-duel round-robin over a **flat 960×540** harness (`shared/GameData.gd:391-420`). Floats are
   single-precision `real_t`; **op *order* is load-bearing** and the tick already sub-steps up to ~5×
   (`shared/Sim.gd:245`). Any change to the sim's float math — above all `Geom.dist`
   (`shared/Geom.gd:7-8`), the single primitive behind ~30 range/aggro/AoE/LOS call sites — must keep
   **AI-only matches byte-identical** (i.e. `z==0` everywhere in the harness) or a **full re-measure +
   re-tune is mandatory.** Add a regression test that proves a `z`-enabled build reproduces the pre-change
   duel results bit-for-bit before merging any sim phase.
2. **No cosmetic-lie.** A client-only hop must **not** appear to clear cover, reach an elevated target, or
   dodge an AoE — the sim is still 2-D, so any of those reads as a bug (`abilities` mapper: "cosmetic-lie
   risk"). Keep the hop on the *mesh*, not the *footprint*: the shadow, the ground target-ring, and the
   camera focus stay at ground level.
3. **Server-authoritative or it doesn't exist.** Any height that affects gameplay MUST be computed in the
   deterministic Sim, snapshot-encoded, and client-predicted — never client-invented. Snapshots are
   deliberately META-slim (x/y only, netcode memo `382f60f`) and prediction reconciles 2-D only
   (`da0917a`); adding real `z` re-inflates the 30 Hz snapshot and needs a vertical predictor.
4. **Protocol version bump** on any change to the intent or snapshot shape (`shared/Protocol.gd:11`;
   intent built at `server/Server.gd:3092`, `client/Player.gd`).
5. **Protect the boss arenas.** GY_BOSS / GY_SECRET are *designed* around 2-D line-of-sight: their cover
   rings break the Head Coach "Full/Total Camp Reset" ult (`shared/World.gd` OBSTACLES + `Geom.has_los`
   `shared/Geom.gd:29`). Height-aware LOS silently changes who those ults hit → re-validate every boss.
6. **`h` is not height.** The decal/prop `h` field is **model scale**, not elevation
   (`shared/GameData.gd:133`, `client/Client.gd:443-463`). Never reuse it as sim height.

---

## 3. The roadmap

Sizes: **S**≈half-session, **M**≈1, **L**≈2-3, **XL**≈multi-session. Tags = size · scope · risk.

### Phase 0 — Cosmetic hop · **S · client-only · ZERO sim risk** — *START HERE*
A visual jump: press **Space** → the local avatar's mesh rises on a short parabola and lands with a
squash. Pure juice, invisible to the sim.
- **Injection point:** drive `model.position.y` (the mesh pivot, baselined at `client/Client.gd:1249`
  `model.position.y = CHAR_Y + yoff`). The recoil/squash system touches only `model.position.x/z` +
  `rotation.x` (`client/Client.gd:2480-2495`), so **`model.position.y` is free** — no conflict.
- Keep `_world()` (`:628`) at `Y=0` so the **holder/shadow/target-ring/camera focus stay grounded** →
  satisfies guardrail 2 automatically (the hop can't imply traversal).
- Add the Space input beside the existing ability presses; a per-avatar hop clock (`t0`, `dur`), height
  `y = 4*H*t*(1-t)`. Optionally fire the existing squash on land. Optionally reuse the `airborne` tag
  (`shared/Combat.gd:107`, cosmetic only) for a leap-on-cast bob.
- **Deliverable:** it feels like you can jump; nothing else changes. Client re-export only.

### Phase 0.5 — Networked cosmetic hop · **S · +1 snapshot bit · no sim/balance** — *optional*
So *other* players see your hop (Phase 0 is local-only; the mapper flagged "invisible to others"). Add a
single `hop` flag (or a cosmetic `hopY` byte) to the fighter snapshot (`server/Server.gd:4721`) set from a
jump intent; the client renders remote avatars' `model.position.y` from it. Still **no** sim/collision/LOS
/balance effect. Costs a Protocol bump (guardrail 4) + a few snapshot bytes.

### Phase 1 — DECISION GATE: do we actually need *true* verticality? · **design, not code**
Before any `shared/` work, answer: **what is height *for*?** Traversal (reach places)? Combat (high-ground
advantage, jump-dodge)? Or just feel (→ you're already done at Phase 0)? Only "traversal" or "combat"
justify Phases 2-4. Write down the specific gameplay it enables; if you can't, stop at Phase 0.5.

### Phase 2 — Sim Z-axis behind a flag · **XL · shared/ + netcode · HIGH risk**
Give fighters real height. Add `z` (+ `vz` + deterministic gravity) to `create_fighter`
(`shared/GameData.gd:699`) and integrate it in the tick alongside the x/y accumulation
(`shared/AI.gd:75`, `shared/Sim.gd:711`) with a **fixed, sub-step-safe** integration order. Thread `z`
into the snapshot (trivial add, `server/Server.gd:4721`) and build a **vertical predictor** mirroring the
2-D one (`client/Client.gd:639-664`). **Gate verticality OFF in the AI-duel harness so `z==0` and the
balance byte-identity holds** (guardrail 1) — the regression test is the merge gate. This phase is where
all the desync risk concentrates: gravity is the first *acceleration* term in a loop that has only ever
done position accumulation.

### Phase 3 — Map height + height-aware collision/LOS · **XL · shared/ + client + content · VERY HIGH risk**
Make height *mean* something. Add a height-field / ramps / climb-targets authoring concept to `MAPS`
(`shared/World.gd:56`, today flat `w×h`); give obstacles a vertical extent (upgrade `circles_from` /
`collision_from_decals` from 2-D circles to volumes, `shared/World.gd:271,327`); make `Geom.dist`
(`:7`) and `has_los`/`seg_blocked` (`:19-33`) height-aware **per call site** (decide which of the ~30
consumers go spherical vs stay planar). Also: height-aware mouse picking replaces the single `y=0` ground
intersect (`client/Client.gd:713`), and the camera stops forcing `focus.y=1.4` (`:1386`). **This is the
phase that rewrites the tuned cover model and the boss-arena LOS** (guardrail 5).

### Phase 4 — Rebalance · **L · GameData + harness · required if 2-3 land**
Extend the duel harness venues (`shared/GameData.gd:9`, `422`) with a `z` dimension + jump-capable AI,
**full re-measure**, and re-tune `FORMAT_MODS[5]`. Re-validate GY_BOSS/GY_SECRET cover rings and every
ability range/kite interaction. Non-optional: Phases 2-3 invalidate the current tuning by construction.

---

## 4. First session — exact starting task (Phase 0)

**All in `client/` — no `shared/`, no server, no re-tune, no protocol bump:**
1. Add a **Space** press (a client input, beside ability presses; it does *not* go into the sim intent).
2. Per local avatar, keep a hop clock; while active, set
   `model.position.y = CHAR_Y + yoff + 4*HOP_H*t*(1-t)` (t∈[0,1] over `HOP_DUR`). `model.position.y` is
   unowned by recoil/squash (`client/Client.gd:2480-2495`), so just add to the baseline from `:1249`.
3. On land (t→1) optionally trigger the existing squash for a landing pop.
4. **Do not touch `_world()` (`:628`)** — leaving `Y=0` keeps the shadow, ground ring, and camera at
   ground, which is exactly what makes it read as juice, not a broken jump.
5. Tune `HOP_H`/`HOP_DUR` in-client (F5), then ship client-only.

That gets a satisfying jump into players' hands in one session at zero risk — and buys the time to make
the Phase 1 decision deliberately instead of under a "jump is missing" reflex.

---

## 5. Appendix — the 2-D-assumption ledger (audit output, for reference)

Everything a real `z` axis has to change, by subsystem (difficulty in brackets):

**Sim / movement / geometry**
- `shared/Geom.gd:8` — `dist()` is `Vector2(...).length()`, the *sole* distance primitive. [very-hard to make 3-D]
- `shared/Geom.gd:10` — `clamp_arena` clamps x,y to a rectangle; no floor/ceiling/height bound.
- `shared/Geom.gd:19-33` — `seg_blocked`/`has_los`: obstacles are infinite-height 2-D circles.
- `shared/AI.gd:75-118` — `step_toward` integrates x,y only (obstacle-hug via atan2 in the plane).
- `shared/AI.gd:121-148` — `separation` pushes on x,y + `clamp_arena`; stacked-height fighters would shove.
- `shared/Sim.gd:31-62,170-195` — projectiles (spread/ricochet + homing) travel + collide in 2-D only.
- `shared/Sim.gd:333-356` — knockback/pull/leap/dash displace x,y then clamp; no knock-*up*.
- `shared/Sim.gd:130-152`, `Combat.gd:122` — hazard/buff zones are flat discs (`dx²+dy² vs r²`).

**AI / aggro / separation** — `AI.gd:16,29,59,165,214,244` (kill-score, focus centroid, peel, support LOS)
all consume `Geom.dist`/`has_los`; server aggro/leash is a 2-D length (`server/Server.gd:3405,3417,3424`,
AGGRO 320 / LEASH 1600). Cross-height fighters currently aggro/collide/AoE each other (all 2-D).

**Abilities / LOS / projectiles** — range gates are planar `dist` (`Abilities.gd:36,50,61,81,108,161,187,
194,207`), fan aim is 2-D atan2 (`:219`), frontal arc is a 2-D heading dot (`Combat.gd:64`), boss
bait-into-wall depends on 2-D `has_los` (`Abilities.gd:239`). RNG stream is fragile: `leapAttack` draws 2
rng (`Abilities.gd:124-125`), crit draws 1/hit (`Combat.gd:151`) — a jump must not add/reorder draws.

**Netcode** — position serialized as `{x,y}` only (`server/Server.gd:4721`; projectiles `:4770`, zones
`:4776`); interest cull is 2-D (`:4718`); intent coerces to `{mx,my}` (`:3092`); client predicts/reconciles
2-D (`client/Client.gd:628,652,655,664,1385`). Adding `z` = snapshot bytes + vertical predictor +
Protocol bump. *(Snapshot `z` add itself is trivial; the predictor is hard.)*

**Client render / camera** — the one projection is `_world()` `client/Client.gd:628` (Y=0); duplicated at
`:664,1385`; camera focus forced to `y=1.4` (`:1386`); mouse pick intersects a single `y=0` plane (`:713`);
ground/field/obstacle/zone geometry all built at y=0 (`:673,1084,1578,1585`). Intent is `{mx,my}` on the
ground basis (`client/Player.gd:37-42`).

**Maps / balance** — maps are flat `w×h` dicts (`shared/World.gd:56`), cover is XY panels expanded to 2-D
circle rows (`:271`), decals carry render-only `h` (`:426`). `FORMAT_MODS[5]` (`shared/GameData.gd:391`)
is tuned on the flat 960×540 harness — the balance surface a real `z` invalidates.

---

## 6. Open decisions for the owner
- **Ship Phase 0 (cosmetic hop) now?** (Recommended — 1 session, zero risk, satisfies most "jump" desire.)
- **Networked hop (0.5) — do others need to see it?** (Small netcode add; protocol bump.)
- **Is true verticality a real gameplay pillar?** (The Phase 1 gate. If "no / just feel" → stop at 0/0.5.)
- If **yes**: accept that Phases 2-4 mean a **mandatory `FORMAT_MODS` re-tune** and a boss-arena
  re-validation, and that determinism/netcode is the hard part — budget accordingly.
