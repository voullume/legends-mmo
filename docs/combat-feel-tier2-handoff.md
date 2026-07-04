# Combat-Feel Pass — Tier 2 Handoff

**Goal:** the four Tier-2 juice items deferred from the Tier-1 pass (see `docs/combat-feel-handoff.md`,
now SHIPPED + LIVE): **(A) heal/shield combat text, (B) procedural recoil + squash-stretch,
(C) per-class signature VFX colors, (D) debris shards.** Read `CLAUDE.md` first. Line numbers are
as-of-writing (2026-07-04, commit `704d592`) — verify before editing.

## What Tier 1 already built (don't rebuild it — ride it)
The impact stack lives in `client/Client.gd` and is event-driven from `_handle_events` (~:975):
dealt/taken `dmg` events fire punch-audio + directional cam kick + FOV punch + render-only hitstop
(`n["hold"]`) + hit-flash (`_start_flash`, shares `material_overlay` with the dye — restore via
`n["dye_applied"]`). Predicted press lives in `_predict_cast`/`_pred_cds`/`n["pred_cast"]`.
**Proc/DOT damage is different:** events tagged `"proc": true` are PASSIVE — they render as small
ember-orange drifting numbers only (see the `burn` param of `_spawn_num`) and must NEVER trigger the
impact stack. Sub-frame DOT/hazard slices coalesce sim-side (`deal_damage` `opts.tick` → `tgt["_dotAcc"]`
→ ~1/sec flush in `Sim.sim_tick`). Every motion effect obeys the **`reduce_fx`** toggle and has a
**tunable const** at the top of `Client.gd`. Keep both conventions for everything below.

## HARD CONSTRAINTS (same as Tier 1)
- **Server stays authoritative; determinism is sacred.** A/C touch `shared/`+`server/` but ONLY by
  appending presentation **events** / snapshot **fields** — never sim math, never an rng draw.
  `tools/bal_identity.gd` must still print `sig_w=175623132 sig_d=351654260` (event-append-only changes
  provably keep it — the Tier-1 proc work verified this twice).
- **MMO scale:** everything pooled/transform-only; cap concurrent effects; `reduce_fx` gates all motion.
- **GDScript:** TABS; `:=` can't infer from Variant (dict access) — annotate.
- **Verify with a REAL headless boot**, not a `--script` load: a bare `--script` SceneTree cannot resolve
  the AudioManager autoload, so Client/NetClient "fail" to load there — false alarm. Runbook:
  `timeout 12 godot --headless --path . > boot.log 2>&1` then grep `SCRIPT ERROR|Failed to load|Parse
  Error|Compile Error` (expect 0) and the `ACCOUNT` boot marker (expect 1).

---

## A. Heal / shield combat text *(S — do first; the info layer. Touches shared/, events only)*
Today heals/shields are invisible in the world (only party frames move).
- **Where:** `shared/Combat.gd` — `apply_heal` (~:286) computes `real` (post-cap); `apply_shield`
  (~:295) computes `boosted`. Emit presentation events, gated on amount > 0:
  `{"type": "heal", "src": src["id"], "tgt": tgt["id"], "amt": int(round(real)), "t": state["t"]}` and
  the same with `"type": "shield"`. Events don't feed the sim → identity-safe (same pattern as the
  proc-tagged burn events).
- **What deliberately does NOT event** (would spam or is invisible-by-design): `meleeLifesteal`
  (Combat ~:209) + vampiric proc (~:270) per-hit micro-heals; the home-zone regen (`server/Server.gd`
  ~:2031 writes hp directly); clean-sheet shield regen (`shared/Sim.gd` ~:288 direct write). If per-hit
  lifesteal text is ever wanted, coalesce it exactly like `_dotAcc` (a `_healAcc` + 1/sec flush) — do
  NOT emit per hit.
- **Client:** new `elif t == "heal"` / `"shield"` branches in `_handle_events`; render via `_spawn_num`
  — refactor its `burn := false` flag into a `style` (e.g. "dmg"/"burn"/"heal"/"shield") while you're
  there. Green (#6fe08a-ish) heal, shield-blue (#7fb8ff) absorb, smaller than damage, gentle drift like
  the burn numbers. Self-heals (`src == tgt == you`) should read quieter than incoming ally heals.
- **Compat:** old clients ignore unknown event types (`if t=="dmg" elif t=="kill"` falls through — the
  summon events already ride this safely). Deploy server-first, no risk.

## B. Procedural recoil + squash-stretch *(M — the feel core. CLIENT-ONLY)*
A struck body should give: a brief lean AWAY from the hit + a squash pulse; a killing blow harder.
Note the sim already has real knockback (`shared/Abilities.gd` ~:263 moves x/y server-side) — this item
is pure render reaction layered on top; touch NOTHING sim-side.
- **Trigger:** in `_handle_events`, on non-proc `dmg` events, for the TARGET node: store a decaying
  `n["recoil_t"] = 1.0` + the world-space hit direction `n["recoil_dir"]` (src→tgt, both resolvable via
  `_world(_find_fighter(...))` — the cam-kick code right there already computes it; crit/kill scale it).
- **TRANSFORM OWNERSHIP (the gotcha — learn Tier 1's lesson):** `holder.position` belongs to the sim
  lerp (~:790); `model.rotation.y` belongs to facing (~:800); `model.scale` is CONSTANT `mscale` set at
  spawn; mob kits' `anim_node` transform is rewritten EVERY frame by `_drive_mob_anim` (and mobs already
  recoil via its `q` channel — **skip mob-kit nodes entirely**, or you'll fight it). For skeletal
  fighters apply recoil each frame in the `_render_world` loop as: a small model-local X/Z offset +
  pitch lean (compose onto `model.rotation.x` which nothing else owns) + scale
  `Vector3(mscale*(1+k*.08), mscale*(1-k*.12), mscale*(1+k*.08))`, decaying `recoil_t` fast (~0.15 s)
  and RESTORING exactly (offset→0, rotation.x→0, scale→mscale) when it hits 0.
- **Hitstop interplay:** during `n["hold"]` the loop `continue`s early — put the recoil application
  BEFORE the hold skip (frozen recoil pose reads great) or after (recoil starts on release/snap); pick
  in tuning, but decay `recoil_t` in `_update_fx` (which always runs) so it can't stick.
- Tunables: `RECOIL_LEAN`, `RECOIL_OFS`, `SQUASH_AMT`, `RECOIL_DECAY`. `reduce_fx` halves lean/offset,
  keeps a subtle squash (it's readability, not motion sickness).

## C. Per-class signature VFX colors *(S/M — identity. Client + ONE server snapshot field)*
Every class carries `GameData.CLASSES[cid]["color"]` (hex, all 8 + mobs).
- **Hit bursts:** `_spawn_pop` already sets its pooled material color per spawn — pass the ATTACKER's
  class color (resolve `src` classId in `_handle_events`) instead of the fixed white/gold; keep crit
  gold as an override so crits stay legible.
- **Cast flourish:** `_detect_cast` knows `classId` at the cast edge (and `_predict_cast` for the local
  player's predicted press) — spawn a small class-colored ground ring / hand flash from the pop pool.
- **Projectiles:** snapshots ship only `{x, y, delay}` (`server/Server.gd` `_snapshot_for` ~:3048) — the
  client cannot know the owner's class. **Server-only additive change:** include the owner's classId
  (projectile dicts server-side know their owner) → tint the pooled projectile material per shot, old
  clients ignore the extra key. The LOCAL sandbox's full proj dicts already carry owner info — same
  lookup works there. Fallback: the current yellow when the field is absent (old server).
- Pool note: the pop/projectile pools share materials — color is already set per-spawn (existing
  pattern), so no new materials; zero allocation.

## D. Debris shards on kill/crit *(S — garnish, do last. CLIENT-ONLY)*
- 3 shards on a crit, 6–8 on a kill you're involved in, at the victim's position: tiny dark box meshes
  from a dedicated pool (mirror `_pop_pool`), tossed with random up-fanned velocities + gravity in
  `_update_fx` (new kind `"shard"`; they already get delta there), fade + repool ≤0.6 s. Hard-cap the
  pool (~24) — an AoE multi-kill must recycle, never allocate. `reduce_fx`: skip entirely. Tint with the
  victim's class color if C landed first (nice cohesion, optional).

---

## Suggested sequencing (each independently shippable)
1. **A** — smallest, completes the information layer; needs the one both-sides deploy.
2. **B** — the biggest feel gain; pure client, tune with the Tier-1 stack live.
3. **C** — identity pass (client + the one server snapshot field).
4. **D** — garnish.

## Verification / discipline (per slice — the Tier-1 runbook, proven)
1. Real-boot grep (see HARD CONSTRAINTS) — NOT `--script` loads.
2. `bal_identity` byte-identical if `shared/` was touched (A, and C only touches server; run it anyway).
3. A sim-side event change gets a headless test in the `tools/test_procs.gd` style (build a state,
   tick, assert events/coalescing) — e.g. "heal cast emits exactly one heal event, regen emits none".
4. **Adversarial review (Workflow)** before commit. Tier-2 risk spots: transform-ownership fights +
   restore-exactly bugs (B), event spam from unconsidered heal paths (A), pool exhaustion / leak under
   AoE multi-kill (D), stale-client compat for the new event types + projectile field (A/C).
5. CHECKPOINT before deploy. Client-only slices (B/D) = re-export + `gh release upload v0.1.0-test
   dist/Legends-Linux-x86_64.x86_64 dist/Legends-Windows-x86_64.exe --clobber` (public publish — needs
   user approval). A/C = push → CI image → droplet redeploy one-liner → verify via the smoke client
   (`godot --headless --path . -- --online 159.89.132.86 --dtls --token <access>`; token = Supabase REST
   password login as `legends_smoke1@testmail.dev`, password in `docs/item-system-handoff.md:271`;
   expect `[netclient] connected` + `assigned fighter`), THEN the client export/upload. Server first —
   old client vs new server is safe in both A and C.

## Files in play
- `client/Client.gd` — `_handle_events`, `_spawn_num` (style refactor), `_spawn_pop` (color param),
  `_render_world` (recoil apply), `_update_fx` (decays + shards), the tunable consts block, `_spawn`
  (pool init). `client/NetClient.gd` — nothing expected beyond what rides Client.
- `shared/Combat.gd` — `apply_heal`/`apply_shield` event appends (A).
- `server/Server.gd` — `_snapshot_for` projectile field (C).
- Tunables reference (Tier 1, top of Client.gd): `FLASH_*`, `KICK_*`, `FOV_KICK_*`, `HITSTOP_*`,
  `PRED_CD_WINDOW`, `REDUCED_SHAKE` — add the Tier-2 consts beside them.
