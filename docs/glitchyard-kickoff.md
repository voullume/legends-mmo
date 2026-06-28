# Glitchyard — new-chat kickoff prompt

Paste the block below into a fresh chat to start building **The Glitchyard Training Camp**. It points at the
full plan (`docs/glitchyard-handoff.md`) and front-loads the must-know context + gotchas so the new session
is productive without re-doing the engine audit.

---

```
Build the next content phase of Legends MMO: "The Glitchyard Training Camp" — a new starter
PvE area with 8 new sports-equipment enemies (+ a boss) and less-basic maps. This is a live,
shipped game (server-authoritative Godot 4.6 / GDScript, deterministic combat sim, Supabase).

START BY READING (in order):
1. CLAUDE.md (engine conventions, deploy, balance harness, Meshy/gltf rules).
2. docs/glitchyard-handoff.md — THE FULL PLAN. Capability matrix, mob architecture, the 5
   primitives to build, the 5-subzone layout, the boss, the phased build order, and a
   file-hook index (§10). It was written from a deep audit of the actual engine; treat it as
   the source of truth, but re-read the cited code (file:line may have drifted) before editing.
3. Your recalled memory, especially: legends-mmo-glitchyard-plan, legends-mmo-item-roadmap,
   legends-mmo-deploy-ops, legends-mmo-character-anim-deadend.

CURRENT STATUS:
- The item system (Phases 1–7) is shipped + live. main is at commit e199c97 (or later).
- Glitchyard Phase 0 is DONE + committed: 11 optimized enemy GLBs are in models/meshy/mobs/
  (cone, foam_dummy[/2], tackle_brute, shooting_dummy[/2], drill_sergeant[/2],
  sled_juggernaut, ball_machine, head_coach). They import clean. Boss2 (a deferred SECRET
  boss) and ShopGirl are intentionally NOT included.
- Your job: build Phase 1 next (see below), then 2→5 per the doc.

LOCKED DESIGN DECISIONS (already reflected in the doc):
- 5 SEPARATED sub-worlds glitchyard_1..5 chained by portals (MapleStory / Monster Hunter
  zoned-maps style — light on GFX/assets), REPLACING the current combat/frontier/depths
  chain as the new starter; keep home (hub) + arena (PvP).
- The *2 GLBs are alternate COSMETIC skins of a mob (pick randomly per spawn). Boss1 = the
  zone boss (build now). Boss2 = a future secret boss (asset kept, do NOT wire it).
- Reward loop (Practice Tokens + Rookie Camp set) is LAST and skippable.

CRITICAL ENGINE FACTS (so you don't have to rediscover them):
- A "mob" today is a reskinned PLAYER CLASS running a fully generic AI brain. Add each new
  enemy as a non-playable CLASSES entry in shared/GameData.gd (flag it mob:true, add a
  `model` field = its models/meshy/mobs/<id>.glb basename) → it inherits stats+abilities+AI.
  An unknown classId CRASHES client (client/Client.gd:~192, no .has guard) AND server
  (shared/GameData.gd:~239) — add guards, and KEEP mob entries OUT of client PLAYABLE and
  out of the AI-duel balance harness's player round-robin.
- The mob GLBs are STATIC (no rig/anim). Animate them PROCEDURALLY client-side (Transform3D
  bob / wind-up / lean / shake), driven by the same state the existing _drive_anim infers
  (moving/attacking via rising cooldowns/hit-flash/dead). Do NOT try skeletal rigging — that's
  the documented Meshy dead-end (legends-mmo-character-anim-deadend).
- The engine ALREADY has: melee+telegraph(cast), charge(dashAttack), knockback, homing
  projectiles, barrage, meleeAoe, slow/stun/knockdown, selfbuff DR stance, omni reflect,
  proximity aggro+leash, and obstacle collision+LOS+AI-cover. MUST BUILD (later phases):
  summon (sim→server event bridge), damaging/slow hazard zones (zones infra ~80% there),
  boss phases (HP-gated ability sets), + polish (pull, kbImmune, frontal-reflect, status
  stacks, bait-into-wall stun, spread/ricochet, clear-to-open gates).
- Maps are "basic" because the obstacle/cover/LOS system exists in the sim but is fed EMPTY
  data (all zones borrow the empty `stadium` venue). Wiring per-zone obstacles in
  shared/World.gd unlocks walls, cover, and "bait the Brute into a wall" for free. The client
  is fully procedural Node3D (no per-zone scenes, no prop system yet — props = a new render
  pass copying _render_portals).

PHASE 1 (do this first):
Build the mob FRAMEWORK + the 4 basic enemies end-to-end, using ONLY existing combat
primitives (no new combat code yet):
1. shared/GameData.gd: add CLASSES entries for cone_swarmer, foam_dummy, tackle_brute,
   shooting_dummy (mob:true, model, sport:"", lane, color, stats, abilities[] mapped to
   existing types per handoff §3). Add the .has() guards.
2. Guards: exclude mob:true from client PLAYABLE and from the balance-harness player loop and
   any CLASSES.keys() player-selection consumer.
3. client/Client.gd: in _make_character/_kit_for, branch on def.model → load
   models/meshy/mobs/<model>.glb + attach a NEW procedural animator (per-mob anim profile).
   The client preloads GameData, so classId in the snapshot is enough to look up def.model.
4. shared/World.gd: re-skin ONE existing camp (e.g. the combat zone) to spawn the new mob
   ids, to prove the pipeline live. Support random alt-skin selection (*2) at spawn.
5. Verify: headless compile (godot --headless --editor --quit, expect 0 SCRIPT ERROR; the
   AudioManager error under --check-only is a false positive). Re-run the 6-seed AI-duel
   balance harness (mobs excluded from the player round-robin; the 8 player classes must stay
   ~50%). Then adversarial review (Workflow) before deploying.

NON-NEGOTIABLES:
- Deterministic sim (mulberry32 state["rng"]): any new mechanic draws rng in a FIXED order or
  not at all (the P6 "procs draw zero rng" rule is the template). Re-run the harness at 6
  SEEDS after every combat-affecting change (2-seed runs are ±8 noise). Tune mobs via stats +
  _scale_mob, NEVER FORMAT_MODS.
- shared/ changes need a server redeploy AND a client re-export; client-only changes need only
  a re-export. New mutating client→server RPCs must be rate-limited + serialized (dupe-safety).
- GDScript uses TABS. Verify exact indentation when editing.
- gltf-transform for any new GLB: resize 1024 + simplify + prune, NEVER Draco. Report Meshy
  credit balance after any Meshy op; the key is in ~/.meshy_env (source it, never print it).
- CHECKPOINT WITH ME before each live deploy. Follow the per-phase rhythm: build →
  compile-check → balance harness (if combat) → adversarial review → show me → deploy when I
  approve. Deploy pipeline + droplet details are in CLAUDE.md / legends-mmo-deploy-ops.

Confirm you've read docs/glitchyard-handoff.md, then start Phase 1.
```

---

**Notes for whoever runs the new chat:**
- The new chat auto-loads the memory index + `CLAUDE.md`, and `docs/glitchyard-handoff.md` + `docs/glitchyard-kickoff.md` are committed on `main` — so this prompt is self-sufficient; it needs nothing from the chat that produced it.
- `docs/glitchyard-handoff.md` is the canonical plan; this file is just the launch prompt.
