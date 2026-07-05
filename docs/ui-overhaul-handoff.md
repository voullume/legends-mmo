# UI Look-and-Feel Overhaul — Handoff for a New Session

> A polished, cohesive UI pass over Legends MMO. Read `CLAUDE.md` first for run/deploy conventions, then
> this. **The whole game loops, content-wise (Glitchyard Phases 1–5 + reward loop + a secret boss are live);
> the systems work — what's missing is a deliberate visual identity.** This doc maps the *exact* current UI,
> the single architectural move that makes the overhaul tractable, a phased plan, and a deep functionality
> wishlist. File:line anchors refreshed 2026-07-05 (post combat-feel Tier 2, commit `daa1697`) — re-grep
> if the files have drifted.
>
> **Tier-2 note (2026-07-05):** the combat-feel Tier-2 pass landed AFTER this doc was first written and
> already shipped part of what §4-P3 planned: floaters are now styled by type (`dmg`/`burn`/`heal`/`shield`),
> hit pops carry the attacker's class color, casts flash class-colored ground rings, and kills/crits throw
> debris shards. It also added the **zone-wide heal/shield event stream** that makes the §4a DPS meter a
> pure-client feature. Don't re-plan those; build on them.

---

## 0. Orientation — where the UI lives + the ONE big freedom

**The entire UI is CLIENT-ONLY.** Nothing here touches the deterministic combat sim, the balance harness, the
server, or the DB. That means:
- **No determinism gate, no `bal_identity`/`bal_p1`, no 6-seed harness.** You can iterate freely.
- **Deploy = a client re-export only** (no server redeploy) — unless you change `shared/`, which the UI
  shouldn't. `godot --headless --export-release "Linux"|"Windows Desktop" … && gh release upload v0.1.0-test … --clobber`.
- **Test loop = open `project.godot`, F5** (or `--online <ip>` to hit the live server). Fast, visual, safe.

**The two UI layers:**
1. **Screen-space HUD + panels** — a single `CanvasLayer` (`_hud`, created in `client/Client.gd:2026`). Holds
   the always-on HUD (`_info` `RichTextLabel`, the skill bar) and every pop-up panel (inventory, sheet, shop,
   forge, vendor, quests, settings, admin, party, chat). All built **programmatically** in `client/NetClient.gd`.
2. **3D-world UI** — `Label3D` nameplates, procedural `MeshInstance3D` HP bars (`_quad`), pooled damage
   floaters, portal/pad pillars + labels, target rings, the boss scoreboard. All in `client/Client.gd`
   (`NetClient` extends `Client`, so it inherits these).

**Files:**
- `client/Client.gd` (2207 ln) — base render + the 3D-world UI + the `_hud`/`_info`/skill-bar scaffold +
  per-fighter nameplate/bar/floater code. `_make_character`, `_update_ui`, `_spawn_num`, `_update_hotbar`.
- `client/NetClient.gd` (3225 ln) — **the bulk of the UI**: every panel builder (`_build_*`), toggle
  (`_toggle_*`), proximity prompt, the HUD info text, input handling (`_unhandled_input`), party frames, chat.
- `client/Player.gd` — input→intent (not UI). `client/Account.gd` — the login/character-select screen (266 ln,
  its own UI). `Main.gd` / `Main.tscn` — boot.
- `project.godot` — **minimal**: no `[display]` window/stretch config, **no project `gui/theme`**, no custom font.

---

## 1. Current UI — precise inventory

### 1a. The styling reality (THE thing to fix)
- **There is NO central `Theme` resource.** Grep confirms: no `Theme.new`, no `.tres` theme, no `set_theme`,
  no `theme =`, no custom `FontFile`. Every widget renders with Godot's built-in default theme.
- **Styling is ad-hoc per-element**: hundreds of `add_theme_color_override(...)`, `add_theme_font_size_override(...)`,
  `add_theme_constant_override(...)` calls scattered through `NetClient.gd`, plus a handful of hand-built
  `StyleBoxFlat`s (`_rarity_box` at `NetClient.gd:587`; button boxes nearby; the world tooltip box at
  `Client.gd:2057`). The same hex colors are retyped everywhere.
- **The implicit palette** (extracted from the repeated literals — formalize these): `#7f93a8` muted
  blue-grey (hints/secondary text, 23 uses), `#cfd6df` light text (19), `#9fe8a0` XP-green (17), `#ffd24d`
  gold/credits (12), `#c9a36a` scrap-tan, `#4fd4ff`/`#8ad6ff` cyan (tokens/info), `#ff6b6b`/`#ff8a8a` red
  (hostile/damage), `#cdbcff` lavender, rarity colors per item. There IS a coherent palette in the designer's
  head — it's just not codified.
- **No project display config**: no `window/size`, no `window/stretch/mode` or `content_scale` — so there's no
  resolution-independent UI scaling. Panels position themselves by polling `_hud.get_viewport().get_visible_rect().size`
  and reconnecting `size_changed` (e.g. `NetClient.gd:835`).
- **No custom font** — default Godot font everywhere (functional, generic).

### 1b. The always-on HUD (`Client.gd`)
- `_info` (`RichTextLabel`, `Client.gd:2028`) — the top BBCode status line: name · sport · role · Lvl · HP ·
  XP · `◈ credits` · `scrap` · `tokens` · zone-chip · ONLINE + a second line of keybind hints. Built at
  `NetClient.gd:3209`. **It's one dense text run — prime candidate for real chips/icons + a vitals frame.**
- `_bar` (`RichTextLabel`, `Client.gd:2035`) — a secondary text line.
- **Skill bar** — `_update_hotbar(pf)` (`Client.gd:2116`): the 1–8 ability buttons with a cooldown sweep +
  computed-stat tooltips. The most "game-like" HUD piece already.
- **No minimap. No buff/debuff bar. No dedicated target/focus frame** (focus is a flat 3D ground ring). **No
  cast bar** for the player (the boss has a telegraph banner; the player has none).

### 1c. The panels (all `CenterContainer → PanelContainer → MarginContainer → VBox`, programmatic)
| Panel | Key | Builder | Notes |
|---|---|---|---|
| Chat | Enter | `_build_chat` `:170` | bottom-left log + input |
| Inventory | `I` | `_build_inventory` `:261` | grid of item tiles, drag/equip, the rarity StyleBoxes |
| Character sheet | `K` | `_build_charsheet` `:319` | computed base+gear stats, item power, set bonuses, procs |
| Shop | `B` (pad) | `_build_shop` `:1242` | buy catalog grid + random-roll + sell/salvage columns |
| Forge | `F` (pad) | `_build_forge` `:1807` | upgrade / reforge / craft (credits + scrap) |
| Practice Vendor | `V` (pad) | `_build_vendor` `:1338` | Rookie Camp set for tokens (newest, simplest panel) |
| Quest log | `J` | `_build_questlog` `:873` | the 9-quest chain + tracker (`size_changed`-pinned) |
| Quest-giver | `E` (pad) | `_build_qgiver_dialog` `:987` | accept / turn-in dialog |
| Settings | `O` | `_build_settings` `:1140` | audio/options |
| Admin | `F1` | `_build_admin_panel` `:2484` | service-role tools (level/xp/give/goto/spawn) |
| Party | — | `_update_party` `:2668` | live-HP frames; right-click a player to invite |
- Every panel repeats the same chrome scaffold + hardcoded fonts/colors → **a Theme makes them all consistent
  at once.** Toggles live in `_unhandled_input` (`NetClient.gd:3032`); pad panels (B/F/V/E) also auto-close on
  walk-away via `_update_*_proximity`.

### 1d. The 3D-world UI (`Client.gd`)
- **Nameplates** — per-fighter `ui` node: a `_quad` black bg + green/red fill HP bar + a `Label3D` (level /
  ★ELITE / ☠BOSS / the Head Coach "scoreboard" with phase + the `BREAK LINE OF SIGHT` ult countdown). Built in
  `_spawn`; driven in `_update_ui` (`Client.gd:1521`). `UI_Y` height; lifted for tall mobs.
- **Damage/heal floaters** — pooled `Label3D` via `_spawn_num` (`Client.gd:1635`), styled by the Tier-2
  `style` param: `dmg` (taken=red, dealt=white/gold crit, others dimmer), `burn` (ember proc ticks),
  `heal`/`shield` (green/blue gains, offset lane, batch-coalesced). Plus Tier-2 world FX riding the same
  event stream: class-colored hit pops (`_spawn_pop` `:1711`), cast rings (`_spawn_flourish` `:1728`),
  debris shards (`_spawn_shards` `:1742`).
- **Pads** — shop (gold), forge, quest-giver, Practice Vendor (cyan) pillars + billboard `Label3D` +
  proximity prompts. Portals: `_render_portals` from the snapshot.
- **Target/focus** — a flat pulsing ground ring (enemy = Tab; ally = Ctrl+Tab / party frame).
- **Ult telegraph** — `_update_boss_telegraph` (`NetClient.gd`): a full-screen red `ColorRect` tint that
  intensifies + a "BREAK LINE OF SIGHT — GET BEHIND COVER" banner. The one piece of real screen-space juice.

---

## 2. The core problem + the design vision

**Problem:** the UI is *complete in function but generic in form* — Godot's default grey theme with hand-tuned
text colors. It reads as a prototype, not a shipped MMO. There's no typographic hierarchy, no panel chrome
identity, no iconography, no motion language, no resolution scaling.

**Vision:** a cohesive **sports-arena MMO** look. Concretely:
- **A codified palette** (promote the implicit hexes to named tokens) + a **dark, slightly-translucent panel
  chrome** with an accent (the existing gold `#ffd24d` / cyan `#8ad6ff` reads as "scoreboard/jumbotron").
- **Typographic hierarchy** — one good display font (headers) + a clean body font, sized by role (title /
  section / body / caption), not ad-hoc per call.
- **Iconography** — currency icons (◈ credits / scrap / tokens), stat icons, slot icons, ability/keybind chrome.
- **Juice** — hover/press states, panel open/close tweens, number pops, hit/low-HP feedback, toasts.
- **Resolution independence** — a `content_scale` mode so it looks right at any window size.

---

## 3. The architecture — the ONE move that makes this tractable

**Set a single `Theme` on the `_hud` CanvasLayer (and the Account screen) and it propagates to EVERY child
Control for free.** This is the highest-leverage change: most of the 100+ `add_theme_*` override calls become
redundant once the Theme carries the defaults.

Do this, in order:

1. **`client/ui/Palette.gd`** (a `class_name Palette` with `const` Colors) — promote the implicit palette to
   named tokens: `BG`, `BG_PANEL`, `BORDER`, `ACCENT` (gold), `ACCENT2` (cyan), `TEXT`, `TEXT_DIM`, `XP`,
   `CREDITS`, `SCRAP`, `TOKENS`, `DANGER`, `HEAL`, + the rarity ramp. Every restyle reads from here.

2. **`client/ui/theme.tres`** — a real `Theme` resource. Set: a default `Font` + `font_size`s; `Button`/
   `PanelContainer`/`LineEdit`/`ScrollContainer`/`RichTextLabel` StyleBoxes (rounded dark panels, accent
   borders, hover/pressed button states); `Label` default colors. Build it once (in code or the editor).

3. **`client/ui/Widgets.gd`** — reusable factories so panels stop re-deriving chrome: `panel(title) ->
   {root, body}` (the CenterContainer→PanelContainer→Margin→VBox scaffold + a styled header + a close ✕),
   `chip(icon, text, color)`, `icon_button(...)`, `stat_row(...)`, `currency(kind, amount)`, `section(text)`,
   `tooltip(...)`. Refactor each `_build_*` to call these.

4. **Apply it:** `_hud.theme = preload("res://client/ui/theme.tres")` right after `_hud = CanvasLayer.new()`
   (`Client.gd:2026`); same on the Account/login UI. Instantly restyles every default-themed widget.

5. **`project.godot` `[display]`** — add `window/size/viewport_width/height` (a sane base, e.g. 1600×900) +
   `window/stretch/mode="canvas_items"` + `content_scale/...` so the UI scales cleanly to any resolution.

6. **Migrate, don't rewrite:** delete the now-redundant per-element overrides panel by panel as the Theme
   covers them; keep only the *semantic* overrides (a value that's gold *because it's a currency*, via
   `Palette`). Ship after each panel — it's all client-only, zero risk to the sim.

**3D-world UI** can't use the Theme (it's `Label3D`/meshes), so give it a parallel `client/ui/WorldUI.gd`
constants (font sizes, the `Palette` colors reused) so the world + screen UI share one language.

---

## 4. Phased plan (each phase ships independently — re-export, eyeball, done)

- **P0 — Foundation (do first, ~½ day):** `Palette.gd` + `theme.tres` + a font + the `project.godot` display
  config + apply to `_hud`. *Outcome: the whole UI restyles at once — instant, dramatic, low-risk.*
- **P1 — HUD:** redesign the top bar into a **vitals frame** (portrait/class, HP/XP bars, name/level) + a
  **currency tray** (real ◈ icons for credits/scrap/tokens) + a **zone banner**; polish the **skill bar**
  (keybind caps, cooldown radial, GCD); add a **minimap**, a **target/focus frame** (the Tab/Ctrl+Tab targets
  as proper unit frames with cast bars), a **buff/debuff bar**, a **player cast bar**, and the **DPS/HPS
  meter — the flagship P1 panel, fully specced in §4a** (build it right after the vitals frame: it's the
  hardest panel class — compact live rows — so it pressure-tests the Theme/Widgets early).
- **P2 — Panels:** restyle inventory/sheet/shop/forge/vendor/quests/settings via `Widgets` + the Theme;
  consistent headers + ✕ close + ESC; **item tooltips with comparison** (vs equipped); rarity-ramped tiles;
  a proper **paperdoll**; the quest log as a readable chain with rewards/icons.
- **P3 — 3D-world UI:** nameplate/HP-bar polish (class color, cast pip), target-ring redesign, pad/portal
  label polish, and finish the boss presentation — **the noted-missing `coreShield` aura + Wobble-stack
  pips + a per-phase emissive** (see §5). *(Damage-floater juice — crit pop/scale + color-by-type — already
  shipped in combat-feel Tier 2; don't redo it, just restyle its colors through `Palette` if they drift.)*
- **P4 — Juice & feel:** panel open/close tweens, hover/press everywhere (free once the Theme has button
  states), **toasts/notifications** (loot, level-up, quest complete, "set bonus active"), a **low-HP screen
  vignette**, **death/respawn** + **zone-transition** screens, sounds tie-in, and **gamepad/controller focus
  navigation** (Godot focus-neighbors).

---

## 4a. Flagship P1 work item — the DPS/HPS meter (scoped 2026-07-05)

**Why now:** combat-feel Tier 2 (commit `daa1697`, LIVE server+client) made this a **pure-client** feature.
The client already receives, zone-wide in every snapshot's `events` array, everything a meter needs. **No
`shared/` change, no server change, no snapshot field, no `bal_identity` gate.**

### Data source (all consumed in `_handle_events`, `Client.gd:1031`)
- **`dmg` events** — `{src, tgt, amt, crit, t}`; proc/DOT damage arrives as the same events tagged
  `"proc": true`, already sim-side coalesced to ~1 flush/sec per (src,tgt). Count BOTH toward the source's
  damage (procs are real damage — the tag only gates the impact stack).
- **`heal` / `shield` events** (new in Tier 2) — `{src, tgt, amt, t}`; `amt` is the **post-cap applied**
  amount (= effective healing, exactly what an HPS meter wants). Shield = the boosted absorb granted.
- Hook the accumulator INSIDE the existing `_handle_events` loop (events are cleared at its end — read them
  before `_state["events"].clear()`; note heal/shield are batch-coalesced into the `gains` dict there — tap
  the raw events, not the render coalescing).

### Accumulator + window math
- `_meter := {}` — fighter id → `{dmg: float, heal: float, shield: float, first_t: float, last_t: float,
  buckets: Array}`. `buckets` = a small ring of per-second sums (15 slots) for **current DPS/HPS** (display
  a 10–15 s rolling average — the ~1 s proc lumps and 1/30 tick jitter smooth out at ≥5 s). Encounter
  totals + `total/(last_t - first_t)` for **encounter DPS**.
- **Encounter edges:** start = first event after ≥5 s of event silence involving tracked ids; end/reset =
  the same silence, plus a manual reset button on the panel. Keep the LAST encounter viewable after it ends.
- Resolve display names/classes lazily via `_find_fighter` + `GameData.CLASSES[cid]` (name, `color` — the
  Tier-2 class-color language carries straight into the meter's row chips). Cache id→{name,color} so rows
  survive a fighter leaving interest range; prune entries idle >60 s to bound the dict.

### Panel spec (build on P0's `Widgets`/`Palette` — this panel is the pattern-proof)
- Toggle key: **`N`** ("numbers" — `L` is the leaderboards, `G` the wardrobe, and keep `M` free for the
  future minimap; the full live-bound list is in §6). Compact, movable, semi-transparent; lives fine
  alongside combat.
- Rows sorted by the selected metric: rank · class-color chip · name (self + party highlighted, using the
  party roster) · horizontal bar normalized to the top row · number (per-mode). Modes: **DPS (rolling)** /
  **DPS (encounter)** / **HPS** / **Damage taken** (tgt-side sum of the same events — free). Scope filter:
  party-only vs zone (zone shows AI residents too — fun, keep it as the default OFF).
- Footer caveat line (honesty beats mystery): "melee lifesteal + passive regens aren't counted".

### Known blind spots (document, don't fix here)
1. **Melee lifesteal + the vampiric proc + zone/clean-sheet regens are event-silent by design** (Tier-2
   exclusion list — they write hp directly). HPS under-counts those sources. If that ever matters, the fix
   is a coalesced `_healAcc` flush in `shared/Combat.gd` — a **separate slice with the full identity
   ceremony** (bal_identity byte-identical, headless event test, server-first deploy). NOT part of the UI pass.
2. **Mitigated/absorb-consumed damage isn't evented** — no "absorbed" column.
3. **No pre-arrival history** — events flow only while you're in the zone; meters are encounter-scoped
   anyway (that's the genre norm).
4. **`dmg` events include overkill** (the killing blow's full amount) — fine for a game meter; don't
   over-engineer.

### Verify
- Sandbox first (bots brawl constantly — the meter fills in seconds; `R`/`C` resets must not leak rows or
  crash the ring buffers — same `_teardown` discipline as the FX pools).
- Then online vs the live server (heal/shield events are live as of `daa1697`); confirm an AI-resident
  Setter's heals attribute correctly.
- MMO-scale sanity: accumulation is O(events/frame); the panel re-renders at ~4 Hz (a timer), NOT per frame.

---

## 5. The functionality wishlist (the "most functionality" — pick + sequence)

Always-on HUD / combat:
- **Minimap** (zone overview + mob/pad/portal/party blips) — there is none today.
- **Buff/debuff bar** with durations — none today.
- **Player cast bar** + GCD spinner on the skill bar — none today.
- **Target & focus unit frames** (HP/cast/buffs) replacing the bare ground ring.
- **Boss frame** for raids: HP %, phase, the ult countdown as a proper bar (today it's nameplate text +
  the screen tint).
- **The two flagged-missing indicators** (from the combat work): **Wobble stacks** (a pip meter — currently a
  stumble just happens) and a **core-shield aura** on Head Coach PRIME (the boss takes 55% DR while cores
  live with NO visual cue — players can't see why it's tanky). High value, currently invisible mechanics.
- **Party frames** polish (class color, role, range, ready-check), **threat/aggro** hint.

Panels / inventory:
- **Item tooltips with side-by-side comparison** vs the equipped piece; **set-bonus preview**; **stat deltas**
  on hover. **Drag-drop** equip/sort; **item lock/favorite** chrome; **inventory search/filter/sort**.
- **A real paperdoll** with slot icons + the equipped item art.
- **Currency icons** (replace the `◈`/text), **a forge/upgrade preview**, a **vendor "owned/equipped"** marker.
- **Quest log** redesign: the chain as a tracked journey, reward icons, the **secret unlock** progress
  ("8/9 quests · beat the Head Coach") teasing the gated boss without spoiling it.

Screens / flow:
- **Login / character-select** restyle (`Account.gd`) to match.
- **Zone-transition + loading** screen (portal travel currently snaps).
- **Death / respawn** screen, **level-up** flash, **boss-kill** banner, **toast/notification** stack.
- **Settings** expansion: UI scale, keybind remap, volume sliders (some exist), graphics, a help/keybind cheat
  sheet (today keybinds live as cramped HUD text).
- **Accessibility/scaling**: `content_scale` factor, colorblind-safe rarity, font-size option.

Feel:
- Hover/press/disabled states, focus rings, panel tweens, button "click" sounds, toasts, low-HP vignette,
  controller navigation. *(Hit-flash, shake/kick/hitstop, number pops, recoil, class VFX + shards are LIVE
  from the combat-feel Tiers 1–2 — the UI pass shouldn't rebuild combat juice, only screen-space chrome.)*

---

## 6. Gotchas + conventions (so it goes smoothly)

- **Client-only ⇒ no sim risk.** Don't touch `shared/` (the deterministic engine) or the server's dupe-safe
  RPCs. If you somehow need a new server field for the UI, that's a `shared/`+server change → server redeploy
  + the determinism note applies; avoid it.
- **Deploy = client re-export only** for pure-UI changes (no `setup.sh` redeploy). Verify by launching the
  client (F5 or `--online 159.89.132.86 --dtls --token …`).
- **Two render worlds, one language.** Screen UI = Theme on `_hud`; world UI = `Label3D`/meshes (can't take a
  Theme — share constants via a `WorldUI`/`Palette` module).
- **Migrate the overrides; don't fight them.** As the Theme covers a property, delete that panel's
  `add_theme_*` line. Keep semantic-color overrides (route them through `Palette`).
- **Positioning pattern:** panels read `_hud.get_viewport().get_visible_rect().size` and reconnect
  `size_changed` (e.g. `NetClient.gd:835`). With a `content_scale` stretch mode you can lean on anchors more
  and poll less.
- **Keybinds in use** (re-grepped 2026-07-05 — don't collide; surface them in a cheat sheet): `WASD` move,
  `1–8` abilities, `LMB` basic, `RMB` camera/invite, `Tab` enemy, `Ctrl+Tab` ally, `I` bag, `K` sheet,
  `J` journal, `B` shop, `F` forge, `V` vendor, `E` quest-giver, `G` wardrobe, `L` leaderboards,
  `C` Camp Circuit selector (portal pad, online), `O` options, `F1` admin, `Enter` chat, `Esc` close/cancel;
  sandbox-only (Client.gd — NetClient overrides them online): `C` class-cycle, `R` reset, `P` bot-freeze.
  Free for new UI: `N` (the §4a meter), `M` (reserve for the minimap), `H`, `T`, `U`, `Q`, `X`, `Y`, `Z`.
- **BBCode + StyleBoxFlat already in use** (`RichTextLabel` for `_info`; `_rarity_box`). Build on them.
- **No tests/harness for UI** — it's pure presentation; verify visually. (A screenshot diff is the only
  "test" and it's manual.)
- **One adversarial review at the end** (a Workflow) is still worth it for the big refactor — focus it on:
  no broken panel after the Theme migration, no leaked nodes on re-render, resolution/scale correctness,
  keybind/focus conflicts.

---

## 7. First-session starter (copy/paste momentum)

1. `mkdir client/ui`. Create `client/ui/Palette.gd` (`class_name Palette` + the named Colors from §1a/§3.1).
2. Build `client/ui/theme.tres` (start minimal: default font + `PanelContainer`/`Button` StyleBoxes + Label
   color). Author in the editor (Theme editor) or in a one-off `@tool` script.
3. In `client/Client.gd:2026`, right after `_hud = CanvasLayer.new()`, add
   `_hud.theme = preload("res://client/ui/theme.tres")`. Run F5 → **everything restyles**. That single moment
   proves the architecture and is the most satisfying first step.
4. Add the `[display]` block to `project.godot` (1600×900, `canvas_items` stretch). Re-test at a few sizes.
5. Refactor ONE panel (the Practice Vendor `_build_vendor` `:1338` is the smallest, newest, cleanest) onto
   `Widgets.panel(...)` to establish the pattern, then fan out.

**Recommended first ship:** P0 (foundation) alone is a dramatic, low-risk visual upgrade — land it, eyeball it
live, then iterate panel-by-panel. Save the big functionality adds (minimap, buff bar, unit frames) for after
the look is cohesive, so they're built once against the final theme.
