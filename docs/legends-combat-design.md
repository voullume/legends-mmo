# Legends of the Arena — Combat Design Spec

**Engine-agnostic.** Extracted verbatim from the working v1.0 "Stadium" simulator
(`build/apps/legends/app.jsx`). This is the *design*, not the code — the document
we build the Godot version straight from. Every number here is the real, tuned
value from the sim, not a guess.

> **Status:** the sim is a deterministic **AI-vs-AI team auto-battler** (1v1–5v5).
> "Player control" and "online" are *future layers added on top of this* — the
> combat rules below don't change when we add them.
>
> **Golden rule for the port:** reuse the numbers, formulas, and AI exactly.
> Only the *rendering* (SVG → 3D), the *tick host* (JS interval → Godot
> `_physics_process`), and *who drives a fighter* (AI → optionally a player) change.

---

## 0. Glossary of what carries over vs. changes

| Layer | Status in port |
|---|---|
| Stats, derived stats, format mods | **Reuse as-is** |
| All 8 class kits (abilities + numbers) | **Reuse as-is** |
| Damage pipeline (order + multipliers) | **Reuse as-is** — parity matters |
| Status effects / buffs | **Reuse as-is** |
| Team AI (focus, peel, support, movement) | **Reuse as-is** (port logic to GDScript) |
| Maps / obstacles / line-of-sight | **Reuse as-is** |
| Rendering (the SVG arena, plates, feed) | **Replace** with 3D scene |
| Tick host (`setInterval`/React) | **Replace** with `_physics_process(delta)` |
| Determinism (seeded RNG) | **Keep** (port `mulberry32` → a Rng class) |
| Player input | **New** (replaces the AI driver for one fighter) |
| Netcode | **New** (the sim is already deterministic — a big head start) |

---

## 1. Core loop & timing

- **Fixed tick: 30 Hz.** `dt = 1/30`. Everything is `dt`-scaled, so 60 Hz also works — just feed the real delta. In Godot: run the sim in `_physics_process(delta)`.
- **One tick = `simTick(state, dt)`**, in this exact order:
  1. Refresh Quarterback "Pocket DR" auras.
  2. Re-evaluate each team's **focus target** (only every **0.5 s**, not every tick).
  3. Tick zones (Strike Zone) down; cull expired.
  4. Advance projectiles (home toward target id; resolve hits; rigs eat shots).
  5. **Per living fighter:** decay all timers → clean-sheet regen → barrier-expiry blast → if stunned skip → finish casts → support routing → pick target → offensive ability → movement → separation.
  6. Win check.
- **Match length:** `TIME_LIMIT = 95 s`. **Sudden-death overtime** starts at `OT_START = 50 s` (all damage ramps — see pipeline step OT).
- **Win:** last team with a living fighter; or, at the time limit, the team with the higher **summed HP fraction** wins (`timeout = true`). Mutual wipe → coin flip on RNG.

---

## 2. Arena & space

- **Logical field: 960 × 540 units**, `PAD = 50` (fighters clamp inside `[PAD, W-PAD] × [PAD, H-PAD]`). Pure top-down 2D positions `(x, y)`. *(In 3D this becomes the ground plane: map x→X, y→Z, keep Y for jump/airborne.)*
- **Teams spawn on opposite sides in lanes.** Team 0 (HOME) left, Team 1 (AWAY) right. Lane X anchors: HOME `[150, 235, 320]`, AWAY mirrored (`W-150…`). Rows are centered vertically by slot.
- **Obstacles = circular "equipment rigs"** `{x, y, r}`. A rig **blocks movement, projectiles, AND line-of-sight** — this is the core of "pillar play."
- **Line of sight (`hasLOS`)**: segment from A to B is blocked if it grazes any rig (rig radius + 6px pad). Denies ranged casts, charges, and target acquisition.

**Maps (5):**

| id | name | tag | obstacles (x, y, r) |
|---|---|---|---|
| `stadium` | Champions Stadium | CLASSIC | none |
| `rooftop` | Training Tower Rooftop | LOS | (400,196,42) (560,344,42) (480,96,24) (480,444,24) |
| `centerfield` | Center Field Park | PILLAR | (480,270,58) |
| `sandcourt` | The Sand Court | NET | (480,140,30) (480,270,30) (480,400,30) |
| `trenches` | Gridiron Trenches | LANES | (410,120,30) (410,193,30) (550,347,30) (550,420,30) |

---

## 3. Stats system

**6 primary stats, 250-point budget per class.** (Names are the in-fiction labels.)

| Stat | Drives |
|---|---|
| **PWR** Power | Damage multiplier |
| **PRE** Precision | Crit chance |
| **SPD** Speed | Move speed |
| **END** Endurance | Max HP |
| **INS** Instinct | Crit (minor), cooldown reduction |
| **CLU** Clutch | Bonus damage **and** damage reduction while below 35% HP |

**Derived stats (`derive`)** — exact formulas:

```
maxHP    = 600 + END * 9
dmgMult  = 1 + PWR / 100
crit     = 0.05 + PRE * 0.0035 + INS * 0.001
critMult = 1.6
ms       = 95 + SPD * 1.1          (move speed, units/sec)
cdr      = INS * 0.003             (cooldown reduction, fraction)
clutchDmg = CLU * 0.004            (extra dmg mult when self < 35% HP)
clutchDR  = CLU * 0.002            (extra DR when self < 35% HP)
```

**Format (bracket) mods** — kits are tuned for 5v5; smaller brackets get per-class
`dmg`/`hp`/`ms` multipliers applied at fighter creation. Full tables live in
`FORMAT_MODS` (brackets 1, 2, 3; bracket 5 = baseline, only `batter dmg ×1.12`).
*Port note: keep these as a lookup applied in the fighter factory.*

---

## 4. The 8 classes

Lane: **0 = frontline, 1 = midline, 2 = backline.** Stats order = PWR/PRE/SPD/END/INS/CLU.
Abilities list every tuned number. `basic` fires on cooldown as the auto-attack;
`ult` is the long-cooldown finisher. `cd` = cooldown (s), `cast` = wind-up (s).

### Baseball
**Pitcher** — Zone Artillery · backline · `60/70/35/30/35/20` · color #58C6FF
- Passive: *Strike Zone* boosts ally projectiles **+30%** (self +35%) inside the zone — team enabler.
- `Fastball` projectile **basic** dmg46 cd1.25 range330 speed430
- `Curveball` projectile dmg64 cd5 range310 speed330 slow{30%,1.5s}
- `Strike Zone` zone cd12 dur5 radius95
- `Beanball` projectile dmg40 cd9 range290 speed480 stun0.9
- `Perfect Game` **ult** barrage dmg82 ×3 cd26 range350 speed460

**Batter** — Melee Burst · midline · `75/37/40/48/25/25` · #2F86FF
- Passive: *Shield Crusher* +25% vs shielded/DR targets · 20% melee lifesteal.
- `Swing` melee **basic** dmg57 cd1.3 range62
- `Power Swing` melee dmg124 cd6 range70 cast0.4 knockback60
- `Slide` dash cd4.2 dist175 evade0.4 gapClose
- `Stolen Base` selfbuff cd9 buff{ms ×1.45, 2.5s}
- `Grand Slam` **ult** meleeAoe dmg235 cd26 radius110 knockback80 cast0.5

### Football
**Quarterback** — Support Tank · frontline · `40/40/35/65/45/25` · #51E08A
- Passive: *Field General* — buffs route to most-threatened ally · **Pocket DR aura** (+4.5% DR to allies within 165u).
- `Shoulder Check` melee **basic** dmg50 cd1.35 range60
- `Huddle Up` allybuff cd6.5 shield 22% for 4s
- `Blitz` allybuff cd7.5 buff{atkspd ×1.32, 2.4s}
- `Tackle` dashAttack dmg56 cd7 dist150 slow{25%,1.2s}
- `Sack` melee dmg16 cd11 range66 stun1.1
- `Hail Mary` **ult** projectile dmg195 cd28 range420 speed520 + team shield 8%

**Linebacker** — Bruiser · frontline · `55/25/30/80/35/25` · #1FA864
- Passive: *Momentum* +5% dmg per melee hit (max 5 stacks, decays out of combat).
- `Shed Block` melee **basic** dmg50 cd1.35 range62
- `Tackle` dashAttack dmg70 cd7 dist165 knockdown0.8
- `Block` selfbuff cd9.8 buff{DR 30%, 2s}
- `Bull Rush` dashAttack dmg55 cd8 dist140 knockback70
- `Fourth & Goal` **ult** dashAttack dmg220 cd28 dist220 knockdown1.0 cast0.4

### Volleyball
**Setter** — Support · backline · `30/50/40/50/55/25` · #C792EA
- Passive: *Six-Pack* — every 6th support ability echoes at 50%. supportBoost ×1.28.
- `Bump` projectile **basic** dmg45 cd1.3 range280 speed380
- `Set` allybuff cd5 buff{next dmg ×1.70}
- `Rally` allybuff cd9 buff{crit +30%, atkspd ×1.20, 2.6s}
- `Dig` allyheal cd7 heal 15% of target maxHP
- `Rotation` **ult** teamheal cd30 heal 18% + cleanse

**Spiker** — Burst Assassin · midline · `70/55/50/30/25/20` · #9D5CFF
- Passive: *Vertical* +12% dmg while airborne · pierces 40% of shields during Tool the Block.
- `Jump Serve` projectile **basic** dmg44 cd1.3 range260 speed400
- `Thunderspike` leapAttack dmg98 cd6 dist190 airborne
- `Tool the Block` selfbuff cd12 buff{bypass, 3s}
- `Pancake` dash cd7 dist150 evade0.35
- `Kill Shot` **ult** leapAttack dmg330 cd27 dist240 airborne untargetable0.6 cast0.35

### Soccer
**Striker** — Finisher · midline · `60/55/65/25/25/20` · #FF8A4C
- Passive: *Hat Trick* every 2nd hit on the same target +30% · +25% MS & +10% DR while chain live · *Clinical* +50% vs targets <40% HP.
- `Finesse Shot` projectile **basic** dmg46 cd1.25 range240 speed420
- `Dribble` dash cd3.25 dist155
- `Yellow Card` melee dmg30 cd7 range64 stun1.0
- `Clinical Finish` projectile dmg84 cd6 range220 speed460
- `Golden Goal` **ult** projectile dmg255 cd27 range300 speed500 cast0.4 + stealth 2s on kill

**Goalkeeper** — Guardian · frontline · `35/35/30/75/50/25` · #E4572E
- Passive: *Clean Sheet* — regenerating shield after 5s without damage (20/s, cap 190) · *Punching Save* returns 1.6× the blocked hit.
- `Distribution` projectile **basic** dmg47 cd1.35 range270 speed400
- `Punching Save` selfbuff cd9 buff{reflect, 1.2s}
- `Diving Save` allybuff cd8 shield 20% for 2s (dashes to ally)
- `Sweeper` meleeAoe dmg50 cd6 radius90 slow{30%,1.5s}
- `Penalty Save` **ult** barrier cd30 dur3 DR70% → blast 320 dmg in radius130 on expiry

---

## 5. Ability types & how each resolves

Every ability has a `type` that defines its resolution. The AI's job is just to
pick *which* ability; `tryCast` handles the rest. Types:

- **projectile** — needs range + LOS. Spawns a homing shot (targets a fighter id) that flies at `speed`, deals `dmg` on contact, may `stun`/`slow`. Rigs block it. Firing sets `atkCommitT = 0.35` (you move at 45% speed briefly — "firing on the move costs speed").
- **barrage** — like projectile but fires `count` shots staggered by 0.22 s (Perfect Game).
- **melee** — needs range. Instant `dmg`; if it has `cast`, becomes a wind-up that resolves on completion. May `stun`, may `knockback`, builds Linebacker momentum.
- **meleeAoe** — hits all enemies within `radius` (Grand Slam, Sweeper). May have `cast`.
- **dashAttack** — needs LOS + within `dist+40`. Lunges to the target, deals `dmg` if it lands within 70u, may `knockdown`/`slow`/`knockback` (Tackle, Bull Rush).
- **leapAttack** — needs LOS + within `dist+30`. Teleport-leaps onto the target, deals `dmg` (Spiker spikes; airborne flag triggers Vertical bonus). May grant brief `untargetable`.
- **dash** — two modes: **gap-close** (lunges toward a far target, Batter Slide) or **escape** (dashes away from the nearest enemy if one is within 110u). May grant `evade`.
- **selfbuff** — DR / move-speed / bypass / reflect. AI only casts defensive ones (`dr`/`reflect`) when actually pressured (enemy within 160u) or below 60% HP.
- **allybuff** — shield % or stat buff routed to an ally (see AI routing).
- **allyheal / teamheal** — heal a hurt ally / the whole team (+cleanse). supportBoost-scaled.
- **zone** — drops a Strike Zone at the focus target's position (LOS required).
- **barrier** — Penalty Save: heavy DR window that ends in an AoE blast scaled by damage absorbed.

**Cooldowns:** `cd × (1 - cdr)`; basics are additionally sped up by atkspd buffs.
Casts lock movement until they finish (a cast bar).

---

## 6. Damage pipeline (`dealDamage`) — exact order

Parity-critical. Apply multipliers in **this order**, then mitigation:

```
0. If target dead OR evading OR untargetable → 0 damage.
1. dmg = raw * source.dmgMult
2. Momentum (Linebacker, melee):      dmg *= 1 + momentum * 0.05
3. Clutch (source < 35% HP):          dmg *= 1 + source.clutchDmg
4. Airborne (Spiker):                 dmg *= 1.12
5. Overtime (t > 50s):                dmg *= 1 + (t - 50) * 0.035
6. Strike Zone (projectile in friendly zone): dmg *= zoneSelf(1.35)/zoneAlly(1.30)
7. Hat Trick (Striker): every 2nd hit same target *=1.30; Clinical vs <40% *=1.50
8. Set buff (nextdmg, non-basic):     dmg *= 1.70, then consume
9. Crit (chance = crit + critBuff):   if proc, dmg *= 1.6
10. Shield Crusher (Batter vs shielded/DR target): dmg *= 1.25
-- mitigation --
11. Reflect stance (GK): consume; deal dmg*1.6 back to source; original → 0.
12. DR: mitigated = dmg * effectiveDR; dmg -= mitigated. (Barriers store the mitigated amount.)
13. Shields: absorb remaining (Spiker bypass skips 40% of shield). 
14. Apply: target.hp -= dmg; reset noDmgT; trigger hit-flash.
15. Lifesteal (Batter melee): source heals dmg * 0.20.
16. Death: if hp ≤ 0 → dead; killer.kills++; on-kill effects (Golden Goal stealth, Thunderspike CD partial reset).
```

**`effectiveDR(target)`** = sum of: active DR buff + barrier DR + clutchDR (if <35% HP)
+ Striker chainDR + QB pocket-DR aura, **capped at 0.75**.

> Minor data note: Batter's passive text says "15% lifesteal" but the code value
> is `0.20`. Treat **code values as source of truth** wherever text disagrees.

---

## 7. Status effects, buffs & timers (per fighter)

All decay by `dt` each tick. Port these as a struct/Resource on the fighter node.

- **stun** (skips the whole action), **slow** (`slowT`+`slowAmt`), **evade** & **untarget** (dodge/ignore windows).
- **shield** (flat absorb, with `shieldT` expiry).
- **buffs:** `nextdmg`, `crit`+`critT`, `atkspd`+`atkspdT`, `dr`+`drT`, `ms`+`msT`, `bypass`, `reflect`.
- **momentum** (Linebacker stacks, decay 1.5/s out of combat), **hat-trick chain** (`hatTarget`/`hatCount`/`hatChainT=3s`).
- **barrier** (`barrier`/`barrierT`/`barrierStored`).
- **clean sheet** (GK shield regen after `noDmgT > 5s`).
- **pocket DR** (`_pocketDR`, recomputed each tick from QB proximity).
- **atkCommitT** (post-fire slow), **chaseT** (melee pursuit ramp), **flipT** (strafe-flip cooldown).

---

## 8. The AI brain (the part that's genuinely valuable)

This is WoW-arena-style team logic. Port faithfully — it's what makes fights read
like real players.

**8.1 Team focus fire** (`pickFocusTarget`, re-eval every 0.5 s)
- Each team computes a single focus target by `killScore`, evaluated from the team's **centroid**:
  ```
  killScore = (1 - effHPfrac) * 2.2      // finish low targets
            + (1 - END/80) * 0.9          // prefer squishies
            + (dmgDealt/2000) * 0.4        // prioritize threats
            - dist/700                     // closer is cheaper
            - 0.25 if shielded
            - 2.0 if untargetable/evading
  ```
- **Swap hysteresis 1.22:** a new target must beat the current focus by 22% to steal it — prevents flip-flopping.

**8.2 Peel** (defenders only, lane 0): if an ally is below 35% HP with an enemy within 130u, the defender's personal target becomes that **threat** (overrides focus).

**8.3 Support routing** (`supportTick`, runs before offense)
Priority per support class each tick:
1. **allyheal** → lowest ally under 55% HP (with LOS).
2. **teamheal (ult)** → when 2+ allies under 60% (or self under 40%): heal everyone + cleanse.
3. **allybuff/shield** → most-threatened ally (lowest HP frac, unshielded, has LOS); don't waste above 85%. Diving Save lunges to them.
4. **allybuff/stat** → routes to the highest-PWR ally (amplify the carry).
- *Six-Pack echo:* every 6th support cast repeats at 50%.
- *Solo Protocol:* last-one-standing supports self-cast (QB keeps his own pocket, Setter sets herself).

**8.4 Per-fighter action priority** (each tick, if not stunned/casting)
1. Support routing (if a support class and a cast is warranted).
2. **Pick target:** peel-threat → team focus → nearest enemy.
3. **Offensive ability:** sort ult > special > basic; cast the first off-cooldown one that's valid. *Ult gating:* hold ults until the target is below ~70% HP or the match is past 8s.
4. **Move** (below).

**8.5 Movement brain** (`moveToward` + the mode machine)
- **Desired range** by class: melee ≈ 50u; ranged = `basicRange − 40` (capped 250).
- **Move modes with hysteresis (deadbands)** so fighters commit instead of jittering:
  - Ranged: `approach ↔ strafe ↔ kite` (strafe holds near desired range; kite backs off when too close; approach when too far).
  - Melee: `approach ↔ orbit` (orbit = shoulder-circle the target at swing range).
- **Special movement intents (in priority):**
  1. **Pillar hugging** — if focused, hurt (<55% HP), and recently hit, put a rig between yourself and the nearest threat.
  2. **Heal-seek** — a support pulls toward a hurt ally that's out of LOS.
  3. **LOS swing** — a denied ranged attacker arcs around the pillar to re-open the angle.
  4. **Approach / kite / strafe / orbit** per the mode machine (melee pursuit speed ramps the longer the gap stays open).
- **Steering:** if a rig is on the path, orbit its rim tangentially (never deadlocks). **Turn-rate-limited heading** — agile classes cut hard, heavy classes carve wide arcs; off-heading movement is slower (real strafing).
- **Separation:** allies inside `SPREAD_DIST = 92` push apart (AoE discipline); rigs push fighters out; fighters avoid standing in enemy zones; finally clamp to arena.

---

## 9. Win / lose / overtime

- **Elimination:** a team with no living fighters loses immediately.
- **Time limit (95s):** higher summed HP-fraction wins (`timeout` flag set).
- **Sudden death (after 50s):** all damage scales up `×(1 + (t−50)*0.035)` so stalemates resolve.
- **Mutual wipe:** RNG coin flip.

---

## 10. Determinism & headless testing (keep this!)

The sim is **fully deterministic** from a seed (`mulberry32`). Same comps + same
seed + same map = identical match, every time. `runHeadlessMatch` runs a whole
fight with no rendering (used for balance sweeps). **Port `mulberry32` to a small
seeded Rng class in Godot and route *all* randomness through it** — this preserves
repeatable balance testing *and* is the foundation for lockstep multiplayer later.

---

## 11. Animation-state map — the bridge to 3D (Meshy/Mixamo → Godot)

This is the list of animation clips to generate/rig per fighter. The sim already
tracks every state below, so wiring an `AnimationTree` state machine is mostly
"read the fighter's current action → play the clip."

| Sim state / event | Animation clip | Trigger in the data |
|---|---|---|
| standing, no target in range | **Idle** | not moving, no cast |
| moving toward/around target | **Run** (blend by `ms`) | `moveMode` approach/kite + velocity |
| strafing / orbiting at range | **Strafe L/R** | `moveMode` strafe/orbit, `strafeDir` |
| basic/special melee | **Attack (per weapon)** | `tryCast` melee/meleeAoe |
| projectile fire | **Throw / Cast** | `tryCast` projectile/barrage (`atkCommitT`) |
| dash / leap | **Dash / Leap** | dash, dashAttack, leapAttack |
| wind-up abilities (`cast`) | **Charge** (loop → release) | `f.casting` (cast bar) |
| took damage | **Hit-react** (flinch) | `flash` set in dealDamage |
| stun / knockdown | **Stagger / Knockdown** | `stun > 0` |
| death | **Death** | `alive = false` |
| ult cast | **Special/Ultimate** | `ab.ult` |
| block / reflect / barrier | **Guard** | `buffs.dr/reflect`, `barrierT` |

**Asset note:** all 8 classes are humanoid → Mixamo auto-rig + its free mocap
library covers idle/run/strafe/attack/hit/death out of the box. Generate the 8
class bodies in Meshy/Tripo (or grab a Synty/Quaternius pack to start *today*),
keep them **stylized/low-poly** to match the not-too-serious tone and stay
cohesive. One shared humanoid skeleton = one animation set retargeted to all 8.

---

## 12. Recommended Godot build order

Build it in vertical slices so there's always something running:

1. **Data layer** — port `CLASSES`, `derive`, `FORMAT_MODS`, the fighter factory, the seeded Rng. (Pure data/logic, no visuals — testable immediately.)
2. **Damage pipeline** — port `dealDamage` + `effectiveDR` exactly. Unit-test against known inputs.
3. **One fighter, one basic attack** — a capsule on a plane that idles and swings. Proves the tick + animation wiring.
4. **Projectiles + melee/dash/leap** resolution.
5. **Movement + AI** — `moveToward`, mode machine, target pick. Now two AI fighters duel.
6. **All 8 classes + abilities + status effects.**
7. **Maps + LOS + obstacle steering + separation.**
8. **Win conditions + overtime + match flow.**
9. **Swap a capsule for a real Meshy/Mixamo model** and wire the AnimationTree (section 11).
10. → **then** the game layers: player input on one fighter, UI, progression, multiplayer (Godot high-level MP / GodotSteam / Nakama).

---

## 13. Toward "playable" and online (forward notes)

- **Player control** = replace the AI driver for one fighter with input → the *same* `tryCast`/movement functions run, just commanded by a human. The other fighters keep their AI (instant bots/co-op).
- **Multiplayer** — the sim being deterministic is a real advantage: a **deterministic lockstep** model (send only inputs, every client runs the same sim) is viable for small PvP, and an auto-battler/less-twitchy combat is far more forgiving of latency than a twitch shooter. Server-authoritative via Nakama is the alternative when you add accounts/matchmaking/persistence.
- **Scope ladder:** 3D auto-battler → single-player controllable → small online PvP arena → RPG/progression layer → (north star) persistent world. Build the arena PvP first; it's the sellable core.

---

*Source of truth: `build/apps/legends/app.jsx` (v1.0 "Stadium"). When code and prose
disagree, the code wins. Keep this doc updated as the design evolves.*
