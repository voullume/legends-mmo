# Audio drop-in folder

The audio system (`client/AudioManager.gd`) is fully wired but **silent until you add files here**.
To enable a sound, drop a `.ogg` (preferred), `.wav`, or `.mp3` with the matching name, then re-export
the client. Anything missing just stays silent — no code change needed.

## SFX → `audio/sfx/<name>.ogg`
Combat (played positionally in 3D at the fighter):
- `hit` — a normal hit lands
- `crit` — a critical hit
- `death` — a fighter dies
- `respawn` — you respawn

Ability casts (played when **you** use an ability; mapped from the ability's type):
- `cast_melee` — melee / dash-attack / leap / melee-AoE
- `cast_ranged` — projectile / barrage
- `cast_ability` — dash / self-buff / barrier
- `cast_support` — ally heal / ally buff / team heal
- `cast_ult` — any ultimate (overrides the above)

UI / feedback (flat, non-positional):
- `level_up`, `loot`, `quest`, `ui_click`, `portal`

## Music → `audio/music/<zone>.ogg`
Per-zone tracks, crossfaded on zone change. Names match the world ids:
- `home`, `combat`, `frontier`, `arena`

Tips: keep SFX short and normalized; loop music seamlessly. CC0 sources (Kenney, etc.) are safest to
bundle since they need no attribution.
