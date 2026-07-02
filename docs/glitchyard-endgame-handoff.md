# The Glitchyard Endgame — Design + Implementation Handoff

> **Status: PROPOSAL (2026-07-02). Nothing built yet — awaiting approval.** Turns the Glitchyard's ~1–2 hr
> linear campaign into an "hours on hours" MMORPG loop: level through the 5 open zones → run an instanced,
> scalable **Camp Circuit** at ascending Intensity for gear + fragments → craft the **Master Key** → raid the
> **secret boss** → climb **leaderboards** and the **Two-Minute Drill**. Read `CLAUDE.md` + the security-audit
> memory first. Scope = the 7-feature "recommended slice" (#1 ladder, #2 attunement, #3 level cap, #12 HUD,
> #15 cosmetics, #9 leaderboards, #5 gauntlet).

---

## 0. The single most important property of this whole program

**It touches ZERO deterministic combat logic.** Every feature below is server orchestration + DB + client
render + `World.gd` DATA. No change to `Sim.gd` / `Combat.gd` / `Abilities.gd` / `AI.gd` combat paths, no new
sim RNG, no new mob abilities. Therefore:
- `bal_identity` stays **byte-identical** every phase (run it anyway as a cheap proof), and the 8-class
  ~50% balance **cannot** break.
- The only balance surface is **mob scaling** (Intensity multiplier through `_scale_mob`, mob-only) and
  **gear caps** (already bounded by `EQUIP_STAT_CAP`). Both are the safe, established levers.
- Every new client→server RPC follows the **dupe-safety contract** (own lock pair set before await,
  deduct-before-write, atomic conditional DB writes) — the same discipline the item system + the security
  audit hardened.

This is the big de-risker: a large content expansion with no risk to the combat engine.

---

## 1. The end-to-end loop (what a player actually does for hours)

1. **Level 1→cap in the open zones** (the current 5-zone chain, unchanged as the on-ramp). Learn the mobs,
   the classes, the gear.
2. **Hit the cap, and the campaign "opens up."** The Head Coach arena now also offers the **Camp Circuit**:
   an instanced, condensed run of the 5-zone content + the Head Coach, at a **selectable Intensity tier**.
3. **Grind the Circuit ladder.** Each Intensity tier scales mob HP/damage AND loot ilvl/rarity/drop-rate.
   Clearing the Circuit at your current max tier **unlocks the next** (Rookie → Varsity → Pro → All-Pro →
   Legendary → …). This is the Diablo-torment / MH-rank treadmill — the *same content* stays a real power
   check for dozens of hours. Every clear also drops **Playbook Pages** (the attunement currency), more at
   higher tiers.
4. **Chase the Master Key.** Spend Pages at the forge to craft the **Master Key** — a multi-hour collection
   that *is* the gate to the secret boss (replaces the current "all quests" gate). The higher-tier grind is
   the pilgrimage to the secret.
5. **Raid Head Coach PRIME** (the secret), now earned. Beating it drops the top-tier chase gear + a prestige
   cosmetic + a leaderboard entry.
6. **Compete + prestige.** The **Two-Minute Drill** (endless-wave survival) and **leaderboards** (fastest
   Circuit/boss clear per tier, deepest Drill wave, highest gear score) give the "one more run" hook, and
   **cosmetic dyes** let players show off. The determinism/server-authority makes scores trustworthy.

The five open zones become the *first chapter* of a loop that keeps going, instead of the whole game.

---

## 2. The enabling architecture — per-party instancing

Today `_worlds` is a static dict created at boot; all players share `glitchyard_1..5`. The endgame needs
**private, scalable copies**, so:

- **`_instances` registry** — worlds created on demand, keyed `camp@<owner>@i<tier>` / `drill@<owner>`.
  Entering the Circuit/Drill portal spins up a fresh instance from a template (mobs, obstacles, scaling),
  places the party in it, and **tears it down when empty** (all members left/disconnected).
- The tick loop, snapshots, portals, mob spawn/scale, loot, and death all already iterate `_worlds`
  generically — so instances "just work" once creation/teardown is dynamic. This is the **biggest single
  build** and the foundation for #1, #2, #5, #9.
- Determinism-safe: an instance is just another world running the same sim; no combat-logic change.
- **De-scope option (faster MVP):** a fixed pool of pre-created Circuit/Drill channels reused across parties
  instead of true per-party instances. Less clean (contention), but ~half the build. *Recommend true
  instancing for the demo feel; fall back to a pool only if we need to ship faster.*

---

## 3. Feature specs

### 3.1 Camp Circuit + Intensity ladder (#1)
- **Content:** a condensed instanced run — a handful of `World.gd` template rooms reusing the existing
  Glitchyard mob roster + obstacle geometry, ending at the Head Coach. (Data in `World.gd` → determinism-safe,
  needs redeploy + re-export.)
- **Intensity tiers** (starting proposal, harness-tuned): `I1 ×1.0 HP/×1.0 dmg`, `I2 ×1.6/×1.15`,
  `I3 ×2.5/×1.3`, `I4 ×4/×1.5`, `I5 ×6/×1.7`, then ~×1.6 HP / ×1.12 dmg per tier onward. Applied as an
  `intensity` multiplier in `_scale_mob` (mob-only, exactly like the boss `hpMult`/`dmgScale` already there).
- **Loot scaling:** drop ilvl `= base + tier*step`, rarity floor rises per tier, drop-rate up — so higher
  tiers are the gear faucet. Funnels through the existing `RARITY_CAP`/`EQUIP_STAT_CAP` chokepoint (balance
  stays bounded).
- **Ladder unlock:** clearing the Circuit at `max_intensity` sets `max_intensity += 1` (server-authoritative;
  a new `progression` table). Entering validates `chosen <= max_intensity`.
- **DB:** `progression.max_intensity int default 1`. **RPC:** `enter_camp(intensity)` (validated, spins the
  instance). Clear-reward writes are server-side (not a client claim) → no dupe surface.

### 3.2 Attunement — Playbook Pages → Master Key (#2)
- **Currency:** `progression.playbook_pages int default 0`, server-only writes (like materials), client reads.
  Dropped on Circuit clears (scaled by tier) + a big chunk from the Head Coach.
- **The Key:** a forge recipe `craft_master_key` spends N pages (proposal: enough for ~4–8 hrs of tier
  climbing) → sets `progression.has_master_key = true`. **RPC** under its own dupe-safe lock,
  deduct-before-write, atomic.
- **The gate:** `_portal_unlocked("secret")` returns `has_master_key` (keep the existing fail-closed +
  snapshot-hide machinery; the key replaces/augments the "all quests" check). Server-authoritative — a
  datamined client still can't teleport in.

### 3.3 Level cap raise + treadmill (#3)
- Cap 8 → **30** (proposal). Extend `_xp_to_next` (currently `level*100`) to a curve that stays meaningful
  across tiers; Circuit mobs scale with Intensity so high levels always have targets. `LEVEL_HP` flat per
  level — determinism/harness unaffected (level never enters the sim's class stats).
- **Optional treadmill depth (own sub-phase, can defer):** the deferred **sockets + gems** item phase — more
  build customization; shares the capped per-stat pool so it can't break balance. *Recommend deferring
  sockets to after the slice ships (it's self-contained).*
- **DB:** widen any level CHECK; the security-audit clamp already caps load at 99.

### 3.4 HUD indicators — Wobble + core-shield (#12)
- **Wobble:** ship `wobble` (0..`WOBBLE_MAX`) on the player's own fighter block in `_snapshot_for`; client
  renders a small stack-pip meter that flashes before the stumble. (Snapshot field reads existing state → no
  sim change.)
- **Core-shield:** ship a `shielded` bool on the boss block (computed from `Combat.core_shield_mult`); client
  renders an aura + a "SHIELDED — DESTROY THE CORES" banner. Makes the secret-boss fight legible — currently
  invisible.
- **Client-only render** + two snapshot fields. No sim risk. Re-export only (server field add → redeploy too).

### 3.5 Cosmetics — dyes (#15)
- **MVP = dyes** (tint the character's color / a small palette) — cheap, pure prestige, a real currency sink,
  zero balance/sim impact. (Full model-skins = alt GLBs later; the Meshy re-rig dead-end does NOT apply to
  recolor/retexture, but new skins are effort — defer.)
- **DB:** `character_cosmetics` (owned, server-written on purchase) + an equipped dye field; **RPCs**
  `buy_cosmetic(id)` / `equip_cosmetic(id)` (dupe-safe; buy spends currency deduct-before-write). Client
  applies the tint on the character material. A cosmetics vendor pad in home (mirror the Practice Vendor).

### 3.6 Two-Minute Drill — wave gauntlet (#5)
- **Instanced** single-arena endless survival; escalating waves spawned via the **existing summon bridge**
  (server emits, spawns, scales — no new sim rng). Score = waves cleared (+ time/kills). Rewards: pages +
  currency + a leaderboard entry.
- **Server-orchestrated** wave state; results written server-side on end → no client score claim → no dupe.

### 3.7 Leaderboards (#9)
- **Server-authoritative scores** (the server runs the sim, so results can't be client-forged; determinism is
  the bonus that makes replays/spectates verifiable later).
- **Categories:** fastest Head Coach / Circuit clear per Intensity, deepest Drill wave, highest gear score.
- **DB:** `leaderboards(category, character_id, name, score, meta, created_at)` — service-role writes, public
  read of top-N. **RPC:** `fetch_leaderboard(category)` (rate-limited read). Client: a leaderboard panel.

---

## 4. Phased build plan (each: implement → `--import` compile → `bal_identity` byte-identity proof →
   dupe-safe RPC review → adversarial Workflow → **checkpoint before deploy**)

- **Phase 0 — Instancing foundation.** Dynamic per-party world create/teardown; no new gameplay. Prove a
  party can enter/leave a throwaway instance cleanly (no leaks — the id-keyed dicts the audit mapped must be
  torn down per instance). *Biggest/riskiest piece; everything else rides it.*
- **Phase 1 — Camp Circuit + Intensity ladder + level cap.** The endgame spine: instanced condensed run,
  `_scale_mob` intensity multiplier, tier-scaled loot, ladder unlock, cap 8→30. Harness-tune the tier curve.
- **Phase 2 — Attunement gate.** Playbook Pages currency + Circuit drops + `craft_master_key` + the secret
  gate keyed on the Master Key.
- **Phase 3 — HUD indicators.** Wobble pips + core-shield aura (snapshot fields + client render).
- **Phase 4 — Cosmetics (dyes).** Vendor + owned/equipped + client tint.
- **Phase 5 — Two-Minute Drill + Leaderboards.** Wave-survival instance + leaderboard tables/UI (Circuit/boss
  clear times + Drill waves + gear score).

Deploy per phase: `shared/` (World.gd data) + server changes → redeploy + client re-export; client-only phases
→ re-export only. Migrations applied AFTER the matching server deploy (the security-audit ordering lesson).

## 5. Decisions — LOCKED (approved 2026-07-02)
1. **Instancing: TRUE per-party instances** (owner = party key or solo fid; members join the owner's instance).
2. **Level cap = 30**; **sockets/gems DEFERRED** to after this slice.
3. **Cosmetics = dyes/colors only** for now (no new model skins).
4. **Chase length: ~6 hours** for a fresh player to reach the secret boss in this demo build — tune the
   Playbook-Pages economy (Circuit drops per tier + Master Key cost) to that target via the harness.
5. **No trading** — kept (preserves the dupe-safe surface).
