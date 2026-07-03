# Combat/UI SFX — attribution & mapping

All sounds here are **CC0 (Creative Commons Zero — public domain)**, created/distributed by
**Kenney** (https://kenney.nl). No attribution is legally required; recorded here for provenance.

Sourced 2026-07-03 from three Kenney CC0 packs (a "de-sci-fi" pass swapped out the laser/explosion/energy
sounds for grounded, physical ones that read better for a sports-fantasy game):
- **Impact Sounds** — https://kenney.nl/assets/impact-sounds
- **RPG Audio** — https://kenney.nl/assets/rpg-audio
- **Interface Sounds** — https://kenney.nl/assets/interface-sounds

Each file is renamed to the exact `AudioManager.SFX_NAMES` slug so `AudioManager._try_load` picks it
up automatically (`res://audio/sfx/<name>.ogg`) — **no code change needed to make the game audible.**

| slot (SFX_NAME) | source file | picked because |
|---|---|---|
| `hit`          | Impact / impactMining_002      | dry, meaty body-thwack |
| `crit`         | Impact / impactPlank_medium_000 | wood-plank CRACK — reads like a bat/racket crack |
| `death`        | Impact / impactBell_heavy_000  | knockout-bell toll |
| `respawn`      | Interface / confirmation_001   | positive "back in play" chime |
| `cast_melee`   | RPG / knifeSlice               | clean swing whoosh |
| `cast_ranged`  | RPG / cloth3                   | fabric whoosh = a throw / pitch |
| `cast_ability` | RPG / chop                     | forceful power-hit |
| `cast_support` | Interface / confirmation_002   | soft positive tone (heals/buffs — kept gentle, they're frequent) |
| `cast_ult`     | Impact / impactMetal_heavy_000 | big metallic slam for the ultimate |
| `level_up`     | Interface / bong_001           | celebratory resonance (rare) |
| `loot`         | RPG / handleCoins              | coin jingle on pickup |
| `quest`        | Interface / confirmation_004   | positive chime on quest complete |
| `ui_click`     | Interface / click_001          | tactile UI click |
| `portal`       | RPG / cloth1                   | fabric swish transition |

**How to swap any of these:** drop a new `<slot>.ogg` here (same filename), then run `godot --headless
--import --path .` (or just open the project in the editor — it auto-imports). You never hand-make the
`.import` sidecar; Godot generates it. `.wav`/`.mp3` also work.

## Staged: per-CLASS cast sounds (NOT YET WIRED — for the combat-feel pass)
Pre-sourced so each class's cast can sound like its sport. These are **imported and ready but inert** — they
are NOT in `AudioManager.SFX_NAMES` yet, so nothing loads them until the pass adds a `classId → cast sound`
lookup (see `docs/combat-feel-handoff.md`, "Enhancement — per-CLASS cast sounds"). All CC0 Kenney, grounded.

| class (sport) | file | source | reads as |
|---|---|---|---|
| pitcher (Baseball)     | `cast_pitcher.ogg`     | RPG / cloth2               | a pitch / throw whoosh |
| batter (Baseball)      | `cast_batter.ogg`      | Impact / impactWood_heavy  | a **wood bat crack** |
| quarterback (Football) | `cast_quarterback.ogg` | RPG / cloth4               | a pass / throw whoosh |
| linebacker (Football)  | `cast_linebacker.ogg`  | Impact / impactPunch_heavy | a body-check tackle thud |
| setter (Volleyball)    | `cast_setter.ogg`      | Impact / impactSoft_medium | a soft set / bump |
| spiker (Volleyball)    | `cast_spiker.ogg`      | Impact / impactPunch_medium| a hard spike smack |
| striker (Soccer)       | `cast_striker.ogg`     | Impact / impactSoft_heavy  | a ball kick / thump |
| goalkeeper (Soccer)    | `cast_goalkeeper.ogg`  | RPG / handleSmallLeather   | a glove catch / save |

These are grounded **approximations** (Kenney has no true sports foley). For studio-authentic sports sounds
(a real aluminum bat *ping*, a whistle, crowd murmur, a net swish), the CC0 route is Freesound (CC0-filtered)
or OpenGameArt; drop replacements in with the same names + re-import.

### Alternates to audition — `alts/` (throws feel subtle)
The `cloth`-whoosh pitcher/QB throws are soft; punchier options are staged in `audio/sfx/alts/` (CC0 Kenney):
`cast_pitcher_alt1_fastball` (RPG/knifeSlice2 — sharp fastball), `cast_pitcher_alt2_release` (RPG/drawKnife2),
`cast_quarterback_alt1_longpass` (RPG/drawKnife1), `cast_quarterback_alt2_firm` (RPG/knifeSlice). To promote
one: copy it over the primary, e.g. `cp alts/cast_pitcher_alt1_fastball.ogg cast_pitcher.ogg`, then re-import.
`alts/` is ignored by the loader (it only reads `audio/sfx/<exact name>.ogg`).

These are a **first-pass** set to make the game not-silent. Swap any file (keep the name) to retune;
the loader also accepts `.wav`/`.mp3`. Tuning of per-hit pitch/volume is done at the call sites, not here.
