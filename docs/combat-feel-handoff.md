# Combat-Feel Pass — Tier 1 Handoff

**Goal:** fix "pressing the buttons just feels like pressing buttons." The combat *works*; it lacks
game-**feel**. This handoff covers the highest-ROI slice (**Tier 1**), fully scoped, with the exact code
hook points a multi-lens analysis already found. Read `CLAUDE.md` first.

## The diagnosis (why it feels flat)
Game feel comes from an **impact stack** — many tiny cues fired on the *same frame* of one hit (sound +
flash + camera kick + micro-freeze + knockback + number-pop) that the brain fuses into "CONNECT." Today a
hit fires ~2 cues (a floating number + a pop sphere) **and the sound is a silent no-op**. Four independent
expert lenses (juice / netcode-feel / audio-camera / readability) converged on the same root causes:
1. **The game is 100% silent** — the audio system is fully wired but `audio/sfx/` had only a `.gitkeep`.
2. **Nothing happens the instant you press a key** — server-authoritative combat means your fighter freezes
   for a full round-trip (~100–250 ms) before the snapshot shows the swing. This is the true root cause.
3. **Hits don't visibly "connect"** — the `flash` field is plumbed but never tints the model.
4. **Landing a hit gives no kinetic feedback** — screen shake fires only when *you take* damage, never when
   you deal it.
5. **No hitstop** — the highest impact-per-effort juice technique is absent.

**It is NOT the character animations** — re-animating the Meshy characters is a documented dead-end
([[legends-mmo-character-anim-deadend]]). All Tier-1 work is **code-driven, client-side presentation**.

## HARD CONSTRAINTS (do not violate)
- **Client-only.** Touch only `client/` (+ the SFX assets). **No `shared/` change** (breaks combat
  determinism/balance — verify `tools/bal_identity.gd` still prints `sig_w=175623132 sig_d=351654260` if in
  doubt, though pure client work can't affect it). **No server change, no migration.**
- **Server stays authoritative.** All new feedback is cosmetic/predicted. The server still resolves every
  real hit; predicted client tells must self-correct when the next snapshot disagrees.
- **Hitstop must be RENDER-ONLY.** Never use `Engine.time_scale` / `get_tree().paused` — that would stall
  NetClient's 60 Hz input/send loop and desync you from the server. Freeze only the *render lerp + anim
  advance* of the involved nodes for a few frames.
- **MMO scale.** Effects must be cheap and pooled — many fighters can be on screen. Cap concurrent
  particles/shards; distance-gate audio (the 3D voices already set `max_distance = 70`).
- **Tunable + accessible.** Build every effect with a tunable magnitude constant and add a **"reduce screen
  effects" toggle** in the O-settings menu (shake/hitstop/FOV are motion-sickness triggers for some players).

---

## Step 0 — Audio is ALREADY SOURCED (just commit + polish the call sites)
**Done in this session:** 14 CC0 (Kenney) `.ogg` files are in **`audio/sfx/`**, named exactly to
`AudioManager.SFX_NAMES`, imported, and verified loadable (`ResourceLoader.exists` = 14/14). See
`audio/sfx/ATTRIBUTION.md` for the pack sources + per-slot mapping + license (CC0, no attribution required).
`AudioManager._try_load` (`client/AudioManager.gd:72`) auto-loads `res://audio/sfx/<name>.ogg`, so **the game
becomes audible with zero code change** the moment these are committed and the client is re-exported.

**Remaining audio work (call-site polish, small):**
- Route the **local player's own dealt-hit** sound through the flat 2D UI voice (`AudioManager` has `_ui`,
  `play_sfx(name, null, ...)`) so it lands close/dry/punchy and never gets voice-stolen by distant hits.
- Pass **damage-scaled pitch/gain** at the hit call site — `play_sfx` already takes a `pitch` arg
  (`AudioManager.gd:79`); the damage fraction `amt/maxHP` is already computed in `_handle_events`
  (`client/Client.gd` ~:934) for the shake. Add slight random pitch variation (±5–10%) so repeats don't
  fatigue.
- Fire `cast_*` for **nearby casters, not just the local player** — `_detect_cast` (`Client.gd` ~:1072)
  already resolves which ability *any* visible fighter cast; reuse it to play the type-mapped whoosh
  positionally (distance-attenuated) for audio anticipation of incoming abilities.

### Enhancement — per-CLASS (or per-sport) cast sounds *(do this in this pass, part of the audio step)*
Requested: each class's cast should sound like its sport — **pitcher = a pitch/throw, batter = a bat crack,
striker/goalkeeper = a ball kick/punt, spiker = a spike smack, setter = a soft set/bump, quarterback = a pass,
linebacker = a tackle thud.** Today cast sounds are chosen by **role/type** (`cast_melee/ranged/ability/support
/ult`) in `_play_cast_sound` (`client/NetClient.gd` ~:2861/:2876) and mirrored for other fighters in
`_detect_cast` (`client/Client.gd` ~:1072).
- **This is a small CLIENT change** (not just an asset swap), which is why it belongs in this pass rather than
  the file-swap step. Add a `classId → sound` (or `sport → sound`) lookup that **falls back to the existing
  role sound** if no signature sound exists, so nothing regresses.
- **The data is already there:** every class carries a `"sport"` field (`shared/GameData.gd`: pitcher/batter =
  Baseball, quarterback/linebacker = Football, setter/spiker = Volleyball, striker/goalkeeper = Soccer). So
  **per-sport (4 new sounds)** is the cheap version and **per-class (8 new sounds)** is the rich version — key
  the lookup off `GameData.CLASSES[classId].sport` or `classId` respectively.
- **Assets are ALREADY STAGED (per-class):** the 8 `cast_<class>.ogg` files (pitcher/batter/quarterback/
  linebacker/setter/spiker/striker/goalkeeper) are already in `audio/sfx/`, imported, CC0, and documented in
  `audio/sfx/ATTRIBUTION.md` (bat=wood crack, tackle=heavy punch, spike=punch, kick=soft thud, catch=leather,
  throws=cloth whoosh). They are **inert until wired** — NOT in `SFX_NAMES` yet. So the remaining work is code
  only: add the 8 names to `AudioManager.SFX_NAMES` and the `classId → cast_<class>` lookup (fallback to the
  generic `cast_melee/ranged/...` when a class has no signature sound). They're grounded approximations —
  swap any for authentic sports foley (same filename + re-import) if desired.

---

## Tier-1 bundle — the five changes (with hook points)
> Line numbers are **as-of-analysis** — verify against current `client/` before editing.

### 1. Wire audio punch (see Step 0) — `client/Client.gd` `_handle_events`, `client/AudioManager.gd`
Cheapest, biggest single jump. Ship first.

### 2. Material hit-flash — the universal "it connected" pop
- **Where:** the `flash` rising edge is already detected each frame (`n['pflash'] = f['flash']` set ~:701/:723;
  edge read ~:1128 in `_render_world`).
- **How:** on that edge, set a per-node scalar `n['flash_t'] = 1.0`; each frame in `_update_fx` (~:1439) apply
  an unshaded **additive white/red overlay** to the cached mesh material and fade its alpha to 0 over ~0.12 s.
  Reuse **`_set_overlay_recursive(model, mat)`** (`Client.gd:1332`) — the same helper the dye system uses.
- **GOTCHA:** `material_overlay` is the **same channel the dye cosmetic uses**. Cache the player's dye overlay
  at spawn and **restore it when the flash fades**, or the flash will clobber their dye.

### 3. Dealt-damage directional camera kick — the missing "you hit it" kinetics
- **Where:** the `dealt` boolean (`src == _player_id`) is already computed in `_handle_events` (~:926). Shake
  today only triggers on taken-damage/kill/death (~:932–945).
- **How:** add a **second, directional** impulse channel alongside the existing random `_shake`. On a dealt
  `dmg` event compute the world vector `local_player → target` (both already resolved via `_world(pf)` /
  `_world(tgt)`), store a small `_cam_kick` (~0.15–0.35 world units) scaled by `amt/maxHP` (mirror the
  taken-damage curve ~:934), and apply+decay it in `_update_cam` / `_update_fx` (decay ~:1440). **Cap the
  accumulated magnitude** (like `SHAKE_MAX`) so multi-target AoE doesn't feel seasick.
- **Bonus (cheap):** a small **crit/kill FOV punch-zoom** — `_fov_kick` var, `_cam.fov = FOV - _fov_kick`,
  decay fast (<0.15 s, <5°). The crit/kill branches are already isolated (~:931/:942).

### 4. Render-only hitstop / hit-pause
- **Where:** the dmg/kill dispatch in `_handle_events` (~:919–945); the render lerp is `holder.position.lerp(
  target, delta*14)` (~:708).
- **How:** on a dmg event the local player dealt/took (harder on a kill), set `n['hold'] = ~2–4 frames` on the
  attacker + target nodes and **freeze only those nodes' position lerp + anim advance** for the window,
  decrementing in `_update_fx`. Because the server keeps ticking, the frozen node **snaps forward** when the
  hold ends — that snap *is* the impact bite. **Scope to impacts the local player is part of** (never a global
  freeze — reads as a lag spike in a crowd).

### 5. Predicted press feedback — kill the input-lag feel at the source
- **Where:** `client/NetClient.gd` `_send_ability` (~:2851) — fires on the exact key event, already gates on
  the client-known cooldown (the same check `_play_cast_sound` does ~:2865). Input originates at
  `client/Player.gd` (~:46–63).
- **How:** in that same cooldown-gated spot, the instant a valid ability is pressed, immediately (before the
  RPC):
  - **(a)** play the swing/cast animation on the **local player's** render node — reuse the clip resolution
    `_detect_cast` already computes (role → melee/ranged/cast clip);
  - **(b)** **depress + flash the pressed hotbar slot** (`_slots[i]`, `Client.gd:1668`) and start a **predicted
    cooldown sweep** (set the slot's cd fill to full and drain it locally), reconciled to the snapshot's `cds`
    when it arrives;
  - **(c)** optionally a **predicted cast bar** for cast-time abilities (duration known locally from
    `GameData.CLASSES[id]...['cast']`), mirroring `_update_boss_telegraph`'s pattern but scoped to the player.
- **GOTCHA (mispredict):** the server may reject the cast (out of range / stun / silence the client didn't
  model). Keep the tell **subtle and self-correcting** — if the next snapshot shows no cooldown actually
  started, let the predicted sweep quietly snap back. Don't play anything irreversible (no committed
  projectile) on prediction.

---

## Suggested sequencing (each independently shippable + playtestable)
1. **Audio** (commit the assets + call-site pitch/gain/routing) — biggest perceptual gain, least code.
2. **Impact stack on one hit:** hit-flash (#2) + dealt-damage camera kick (#3) + render hitstop (#4). These
   three combine into the "THWACK" and are best tuned together.
3. **Predicted press feedback** (#5) — the responsiveness half.
4. *(Then, if desired, the Tier-2 list from the brainstorm: procedural knockback/recoil + squash-stretch,
   per-ability signature VFX via class colors, heal/shield combat text, debris shards.)*

## Testing / verification
- **No headless GUI test is possible** — `NetClient` can't be instantiated in a `--script` SceneTree (it
  hangs; see [[legends-mmo-deploy-ops]]). Verify with `godot --headless --import` (parse/asset check) + a
  live playtest. Determinism is unaffected (no `shared/` change) but running `bal_identity` once is a cheap
  sanity check.
- Adversarially review the predicted-cast reconciliation + the dye/flash channel conflict + that hitstop is
  render-only (these are the three real risk spots).

## Deploy (client-only — different from the server phases!)
This is a **client** change → **re-export + publish the player build**, NOT a droplet redeploy or migration:
```
godot --headless --path . --export-release "Linux" dist/Legends-Linux-x86_64.x86_64
godot --headless --path . --export-release "Windows Desktop" dist/Legends-Windows-x86_64.exe
gh release upload v0.1.0-test dist/Legends-Linux-x86_64.x86_64 dist/Legends-Windows-x86_64.exe --clobber
```
The `gh release upload` is a public-surface publish — it needs user approval (or a `Bash(gh release upload:*)`
allow rule). The live server is unaffected. See [[legends-mmo-deploy-ops]] for the full client-deploy notes.

## Files in play
- `audio/sfx/*.ogg` (+ `.import`, `ATTRIBUTION.md`) — **already placed, uncommitted** (commit as part of the pass).
- `client/AudioManager.gd` — loader + `play_sfx(name, pos, pitch)`; no change needed to enable, small change to polish.
- `client/Client.gd` — `_handle_events`, `_render_world`, `_update_fx`, `_update_cam`, `_add_shake`,
  `_spawn_num/_pop`, `_set_overlay_recursive`, the hotbar `_slots`.
- `client/NetClient.gd` — `_send_ability`, `_play_cast_sound`, `_detect_cast` (in Client), settings menu
  (`_build_settings` ~:1135) for the "reduce screen effects" toggle.
- `client/Player.gd` — input origin.
