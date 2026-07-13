# Configurable HUD — Phase 0 report + plan (2026-07-12)

Pre-implementation report for the player-configurable, pattern-based HUD (Sportbound-style
references in `docs/ideas-not-in/hud ui/`). CLIENT-ONLY work: no `shared/`, no `server/`, no
protocol or persistence-schema changes. Everything below was verified against the working tree
on 2026-07-12 (Client.gd 3506 ln, NetClient.gd 5563 ln — the 2026-07-05 ui-overhaul-handoff
anchors are stale; do not use them).

---

## 1. Current module inventory (verified anchors)

Always-on HUD (all children of the single `_hud` CanvasLayer, Client.gd:2641; Theme rides the
root Window, Client.gd:2645):

| Module | Built at | Positioned by | Update cadence |
|---|---|---|---|
| Vitals frame (level/name/HP/shield/XP/status) | Client.gd:2882 `_build_vitals` | `_hud_left` VBox hardcoded (12,10) | per-frame, change-gated `_vit_cache` |
| Currency tray (◈/scrap/tokens) | Client.gd:2943 (in `_hud_left`) | stacked under vitals | per-frame via NetClient:5533 |
| Inventory-cap warning | Client.gd:2957 (in `_hud_left`) | stacked | event (`_update_cap_warning` NC:1095) |
| Zone banner | Client.gd:2964 | anonymous CenterContainer TOP_WIDE offset 8 | per-frame, cached |
| Hotbar (8 slots, 60×60) | Client.gd:3308 `_build_hotbar` | **per-frame math** `((vp.x-w)/2, vp.y-86)` Client.gd:3397 | per-frame `_update_hotbar` |
| Ability tooltip | Client.gd:2668 | offset from hovered slot | hover events |
| DPS/HPS meter | Client.gd:3038 | own drag (Client.gd:3075) — **not persisted**; default `(vp.x-w-12, 340)` | 4 Hz Timer |
| Quest tracker | NC:1604 (lazy) | hardcoded `(vp.x-250, 150)` + own resize hook | quest events |
| Party frames + Leave | NC:4640 (lazy) | hardcoded `(12, 250)` | per-frame fills, rebuild on membership |
| Chat log / input | NC:273 | BOTTOM_LEFT (16,-300)/(16,-46) | event + fade tick |
| Keybind hints `_bar` | Client.gd:2653 | BOTTOM_LEFT (16,-26) | cached |
| Toasts | Client.gd:2742 | per-frame right-align math, z 200 | per-frame |
| Drill banner | NC:2902 (lazy) | per-frame `(vp.x/2-200, 24)` | per-frame |
| Boss ult telegraph (tint + banner) | NC:5017 (lazy) | full-rect + offset_top 90 | per-frame |
| Level flash / zone card | NC:5062 | full-rect, z 160/110 | per-frame anims |
| Low-HP vignette / death overlay | Client.gd:2693 | full-rect, z −20 / 140 | per-frame |
| Proximity hints (7: B/F/E/V/C/P/Y) | NC (each lazy) | per-frame hand-tuned half-width math | per-frame |
| Admin panel (F1) | NC:4433 | `(vp.x-180, 70)` computed once (stale after resize) | static |
| Disconnect overlay | NC:2024 | full-rect, z 4096 + move-to-front | per-frame |

Windowed panels: 14 use `Widgets.panel()` (drag/resize/persist per **title string** into
`user://settings.cfg [windows]`): Inventory, Character, Quest Journal, Quest Giver, Settings,
Shop, Vendor, Camp, Wardrobe, Talents, Paragon, Leaderboards, Forge, Build Shop. Bespoke fixed:
locker loadout (full-screen), sell-confirm, invite popups, loot roll, build-help, delete menu.

Input model: **zero InputMap** — hardcoded keycodes in three layers (`Client._input` F4/builder;
`_unhandled_input` chains NC:5310 / Client:2609 / Player.gd:46; WASD polled in Player.poll()).
Free keys online+sandbox: **F2**, M, Q, X, Z, F5–F12. Esc has a close-priority cascade NC:5316.
Mouse shielding is purely MOUSE_FILTER (no "over UI" guard); WASD/1-8 need explicit gating (chat
precedent: intent zeroed at NC:4503-4506).

Settings file: `user://settings.cfg` sections `[audio] [fx] [build] [windows]` — every writer
load-then-saves to preserve foreign sections. `reduce_fx` (Client.gd:143, `[fx] reduce`) gates
shake/kick/FOV/hitstop/shards/recoil/vignette-pulse/death-fade/toast-slide/level-flash/zone-fade.

## 2. Supplied assets usable directly

- **match-found-frame-only.svg** — as the *geometry spec* for the hero frame: exact path data
  (960×260, chamfered body, rails, brackets, lime elbows, tabs, ticks, dots, orange speeds) is
  ported to procedural `_draw()`. Direct texture import would lose the `<filter>` glows and
  `<pattern>` hex fill (ThorVG doesn't render SVG filters), so the SVG is the blueprint, not the
  runtime asset.
- **match-found-tokens.json** — palette + safe-area contract → codified into `Palette.gd`
  (SB_* tokens) and the hero frame's content margins (safe area 120/55/120/55 at 960×260).
- **SportboundStrike-Regular.ttf** — shipped at `client/ui/fonts/` as the **display font
  prototype** (MSDF import). Headings/timers/banners ONLY (all-caps starter face, A–Z/0–9,
  limited punctuation, no localization coverage, name/licence not yet cleared —
  see `client/ui/fonts/FONTS-README.md`). Body text stays the engine font.
- **match-found.css / README** — sizing recipe (min 360×120, wide 960×260) + type treatment
  (tracking, lime/cyan glow) → constants in the hero frame + display-label helper.

## 3. Reference-only assets (do not ship)

- `ui.png, ui2.png, ui3.png, ui4.png` — frame look-dev; checkerboard/black baked into RGB (no
  alpha). Geometry reconstructed procedurally.
- `skillbar.png` — 6-slot bar concept (baked gray gradient bg); informs the hotbar restyle in
  Phase 5 (slot chamfers, orange charge underline, cyan rail).
- `MOCK_hud.png` — the composition target (layout reference only; it shows unsupported systems:
  minimap, guild chat tabs, match queue — not to be invented).
- `bg.png`, `match_found.png` — concept screens; the match-found *pattern* is reused for real
  states only (zone entry, camp/drill start, boss event, victory, level-up, respawn, discovery).
- Logos (`main/secondary/monogram`) — "Sportbound: Realms of Play" branding: NOT applied.
  Chrome/energy treatment is design reference. Any rebrand needs separate owner approval
  (Phase 12).

## 4. Proposed module registry

Composition, not inheritance: `HudLayout.register(id, node, defaults)` wraps an existing node in
a plain Control wrapper parented to `_hud`; the wrapper owns position/scale/opacity/visibility,
the legacy node keeps its internal behavior. Stable IDs (never node paths):

| id | wraps | default anchor | scale range | notes |
|---|---|---|---|---|
| `player_frame` | `_hud_left` (vitals+tray+cap-warn) | top_left (12,10) | 0.6–1.6 | P3 |
| `hotbar` | `_hotbar` | bottom_center (0,−86) | 0.6–1.6 | P3; kill per-frame position write |
| `quest_tracker` | NC tracker VBox | top_right (−250,150) | 0.6–1.6 | P3; online-only, lazy; edit-preview rows |
| `meter` | meter panel | top_right (−12,340) | 0.6–1.6 | P9: unify its drag; keep 4 Hz + row pool |
| `chat` | log+input | bottom_left | 0.7–1.4 | P6; input keeps body font |
| `party_frames` | party VBox | left (12,250) | 0.6–1.6 | P7; one group module |
| `zone_banner` | banner's CenterContainer | top_center | 0.6–1.4 | P8 |
| `target_frame` / `focus_frame` | new (P7) | top_center-ish | 0.6–1.6 | data exists (`_focus_id`/`_friend_id`) |
| `interact_prompt` | unified proximity hint | bottom_center | 0.6–1.6 | P8: collapse the 7 hint labels into one module |
| `buff_bar`, `minimap`, `bottom_nav`, `builder_panel` | future | — | — | P8/P9 audits |

NOT modules: tooltips (follow cursor/slots), toasts (system), critical overlays (disconnect,
boss telegraph, death, vignette — never player-hideable), transient prompts, Widgets windows
(already movable; Phase 10 restyles only), admin panel.

Wrapper contract per module: stable id, root Control, default layout, min/max scale, edit label,
reference size (wrapper tracks child size), scaled screen rect, apply/serialize/reset, edit-mode
flag, optional preview callback, optional compact variant hook (later phases).

## 5. Layout persistence schema

`user://settings.cfg` (same file, new sections; all writers preserve foreign sections):

```
[hud]
layout_version = 1
ui_scale = 1.0          ; global, 0.75–1.50, step 0.05
profile = "default"     ; default|minimal|combat|exploration|compact|custom

[hud_modules]
player_frame = {"anchor":"top_left","nx":0.0,"ny":0.0,"ox":12.0,"oy":10.0,
                "scale":1.0,"opacity":1.0,"visible":true,"locked":false,"variant":"standard"}
```

- `anchor` ∈ 9-way grid; `nx/ny` normalized to the visible rect relative to the anchor point;
  `ox/oy` pixel offsets — resolution changes keep intent, then clamp to the safe area.
- Unknown ids ignored (kept on disk), missing fields defaulted, corrupt entries dropped to
  defaults, `layout_version` gates future migrations.
- Saves ONLY on Apply / edit-mode exit (never per mouse-motion). HUD reset erases
  `[hud_modules]` only — `[windows] [audio] [fx] [build]` untouched.
- Profiles = data-driven default-layout dicts over the same module system; selecting a built-in
  re-seeds module layouts; any manual edit flips profile → `custom`.

## 6. Scaling strategy

- **Global**: `Window.content_scale_factor` (0.75–1.50) — composes correctly with the existing
  `canvas_items`/`expand` stretch; all per-frame `vp` math reads the visible rect so it adapts
  automatically. Persisted as `[hud] ui_scale`.
- **Per-module**: `wrapper.scale` (clamped 0.6–1.6). Godot 4 GUI transforms mouse picking through
  Control transforms, so hit rects, drags and tooltips stay correct.
- **Crisp text under scale**: `project.godot` gets
  `gui/theme/default_font_multichannel_signed_distance_field=true` (engine font → MSDF) and the
  display TTF imports as MSDF — no raster blur at 60–160%.
- Wrapper size follows the wrapped node's `resized`; anchored placement re-derives from
  `anchor + normalized + offset − pivot·(size·scale)` on child resize, viewport resize, scale
  change. Legacy per-frame position writes for converted modules are removed (hotbar) or
  bypassed when the module owns them.
- Frames are procedural `_draw()` — constant-thickness rails at any module SIZE; proportional
  under module SCALE (correct: scale = zoom).

## 7. Files expected to change (P1–P3)

- NEW `client/ui/HudFrame.gd` — the pattern system: 3 density tiers (HERO / PANEL / UTILITY),
  procedural chamfered geometry ported from the frame-only SVG, published content margins,
  semantic accent params, reduce-FX-aware glow.
- NEW `client/ui/HudFonts.gd` — display-font loader (Sportbound Strike prototype) + display-label
  factory (caps, tracking, glow via theme constants); safe fallback to the engine font.
- NEW `client/ui/fonts/` — `SportboundStrike-Regular.ttf` + `FONTS-README.md` (provenance,
  prototype limits, pre-release checklist).
- NEW `client/ui/HudLayout.gd` — registry, wrapper, persistence, profiles, clamping.
- NEW `client/ui/HudEdit.gd` — edit-mode overlay (outlines, labels, drag, scale, snap guides,
  safe area, overlap warnings, Apply/Cancel/Reset, profile picker, module options).
- NEW `tools/hud_gallery.gd` — Phase-1 gallery harness (frames × content × 60–160% × dark/bright
  backgrounds → `--shot`-style PNGs).
- NEW `tools/hud_layout_test.gd` — headless layout tests (round-trip, clamp, unknown module,
  missing field, corrupt entry, version, profiles) — CI-compatible.
- EDIT `client/Client.gd` — register `player_frame`+`hotbar` after `_build_vitals`/`_build_hotbar`;
  gate the hotbar per-frame position write; F2 toggle (sandbox); intent zeroing while editing;
  load/apply `[hud] ui_scale`.
- EDIT `client/NetClient.gd` — register `quest_tracker` on lazy build (+preview rows); F2 + top
  of the Esc cascade; intent zeroing (chat precedent NC:4503); Settings panel HUD section
  (UI-scale slider, Edit HUD button, profile, Reset HUD layout).
- EDIT `project.godot` — MSDF default font flag (import-cache bust is harmless per kickoff:25).

## 8. Missing authoritative data

None for P1–P3 (vitals/hotbar/tracker data all present client-side). Later-phase notes:
target/focus frames — data already in snapshots + `_focus_id`; minimap — interest-scoped
snapshot positions only (by design, no hidden-info risk, feasibility audit in P9); hold-to-
interact progress — no server support, so no progress variant (per spec); lifesteal/regen HPS —
known deferred `shared/` slice, stays deferred.

## 9. First three-module prototype plan (P1→P3)

P1: build `HudFrame` + `HudFonts` + gallery; screenshot matrix (hero/panel/utility × short/long
title, timer, progress, 2-line body, buttons, icon-value row × 60/75/100/125/150/160% × dark +
bright) on the live X display; iterate until rails/corners/margins/legibility hold. Gate: visual
pass + parse-clean.
P2: `HudLayout` registry + persistence + profiles; headless test suite green.
P3: `HudEdit` wired to exactly `player_frame`, `hotbar`, `quest_tracker`; F2/Settings entry;
Apply/Cancel/Reset/profiles; global-scale slider. Gate: parse-clean boot, layout tests green,
screenshot set (default/edit-mode/scale-extremes/720p/1080p/1440p/ultrawide/150% global),
persistence survives relaunch, gameplay input isolated (WASD/1-8/LMB verified in practice mode).

## 10. Risks & rollback

- Client-only, additive settings sections → rollback = `git revert` of the client commits;
  no server deploy, no migration, no protocol bump. Layout data is disposable by design
  (delete `[hud]`/`[hud_modules]` sections = factory reset).
- Top risks + mitigations: (1) edit-mode input leaking into gameplay → full-rect STOP overlay +
  intent zeroing (chat precedent) + Esc-cascade top branch + F2 (verified free); (2) hotbar's
  per-frame position write fighting the wrapper → the write moves into the module default,
  removed from `_update_hotbar`; (3) `_vit_cache` change-gating across reparent → node refs
  survive reparenting, cache untouched (verified refs, not paths); (4) sandbox R/C teardown —
  HUD built once in `_ready`, wrappers persist; teardown re-verified in practice mode; (5) MSDF
  flag subtly changes text rendering globally → single-line revert if screenshots regress;
  (6) `[windows]` legacy system stays untouched — zero interference by construction.
- Godot-version note: `Image.load_svg_from_string` + MSDF verified live on 4.6.3.

**Phase order from here**: P4 player frame restyle+variants → P5 hotbar → P6 tracker/chat → P7
unit frames → P8 hero events/interact → P9 meter/minimap/builder/nav → P10 modals → P11 settings
consolidation → P12 branding/licensing gate. One phase per session, adversarial review before
ship (project discipline).

---

## STATUS — 2026-07-12 session: P0–P3 BUILT + adversarially reviewed (uncommitted working tree)

Shipped in this session (client-only; zero shared//server/ changes):
- **P1 pattern system**: `client/ui/HudFrame.gd` (procedural hero/PANEL/utility chrome, safe-area
  contract, reduce-FX-aware glow), `client/ui/HudFonts.gd` (display-font roles + fit-to-width),
  `client/ui/fonts/` (Sportbound Strike prototype, MSDF, `FONTS-README.md` licensing gate),
  Palette SB_* tokens. Verified via `tools/hud_gallery.gd` screenshot matrix (60–160% × dark/
  bright × stretch extremes — corners/rails/margins hold everywhere).
- **P2 module framework**: `client/ui/HudLayout.gd` — registry/wrapper/9-way anchors/normalized
  persistence (`[hud]`+`[hud_modules]` in settings.cfg, versioned, sanitized, foreign-section
  safe), 5 built-in profiles + custom, clamping, global UI scale via content_scale_factor.
  `tools/hud_layout_test.gd`: 41 headless checks green (CI-ready — add to tests.yml SUITES).
- **P3 editor**: `client/ui/HudEdit.gd` (F2 / Settings → outlines, name tags, drag+snap guides,
  corner-grip scale, per-module scale/opacity/visible/lock/anchor row, profiles, Apply/Cancel/
  Reset/Fit, Esc=save+exit) wired to exactly `player_frame`, `hotbar`, `quest_tracker` (tracker
  with edit-preview rows). Input isolation: full-rect STOP overlay + intent zeroing (chat
  pattern) + key swallow + `_input`-phase builder gate both directions. Settings gained a HUD
  section (UI-scale slider 75–150%, Edit HUD, Reset HUD Layout; old reset renamed "Reset Window
  Positions"). MSDF default font ON (verified: heavy damage-floater/nameplate outlines intact).

Adversarial review (2-phase workflow, 5 reviewers + per-finding verification) — all confirmed
findings FIXED: toolbar full-width click-dead band → STOP hugs the visible frame; builder/
decorator `_input` bypass → `hud_edit_on` gate + `_hud_edit_blocked()` (no editor over _lb_on/
_deco_on); party-invite/loot-roll popups stealing picks through the overlay → editor moves to
last child on open + auto-closes (saving) when those prompts arrive; `_sanitize` crash on
wrong-typed bools → type-guarded (regression-tested); grip-scale runaway on non-top_left
anchors → frozen scale origin; slot tooltip off-screen with a top-anchored hotbar → clamp+flip;
RMB/wheel now swallowed in edit mode; HudFrame zero-size draw guard; display font
msdf_pixel_range 8→16. Accepted-as-designed (documented): Esc saves live-previewed changes incl.
profile picks (Cancel reverts); Lock gates mouse ops only (toolbar row still edits); hex-field
cost is resize-time only.

Verification evidence: parse+boot grep clean, 41/41 layout tests, screenshot set (default/edit
mode/custom-layout persistence at 1600×900 + 1280×720 + ultrawide/global 150% + module-scale
extremes 60%/160%) in the session scratchpad. NOT yet verified: live-input feel of drag/scale
(no synthetic-input tool on this box) and online-mode pass (quest tracker preview, settings HUD
section) — both fold into the owner playtest that is already owed for the 2026-07-11 session.

Known deliberate limits for later phases: party frames still hardcoded at (12,250) so an
enlarged player frame can overlap them until P7; login screen ignores ui_scale until P11; meter
keeps its own drag until P9.

## STATUS — P4 SHIPPED (commit c69e86c, same session)

Player frame + resources wear the pattern: `HudFrame.fitted()` (content-auto-sized frame),
PANEL chrome + class-emblem chip + name ellipsis on the vitals, UTILITY strip w/ gold stripe on
the tray, **variants** standard/compact/bars via new HudLayout variant plumbing (on_variant
rebuild hook, sanitize-against-list, profile seeds: minimal=bars, compact/exploration=compact)
+ an editor variant picker. `_vit_status` exists in every variant (never-hideable messaging).
Review pass (both findings empirically verified + fixed): fitted frames had stopped shielding
gameplay clicks → STOP restored on both roots; test harness left lambdas in HudLayout statics →
teardown SIGABRT on green runs → registry reset before quit. 46 checks, exit 0. Screenshot
evidence: all three variants incl. bars@150%. Notable: the owner's own F2 layout (saved by a
real play session) restored correctly across sessions during verification — persistence works
in the wild.

## STATUS — P5 SHIPPED (commit 9f69f3a, same session)

Hotbar chassis + slot chrome: the bar rides in a PANEL-tier fitted chassis (module now wraps
the chassis root — existing saved layouts re-apply transparently, verified against the owner's
real layout), STOP shielding on the bar region, cyan slot borders (ult keeps gold), ink keycap
chips with cyan keys, lime ready tick on each slot's bottom edge (hidden while locked/cooling;
the wipe + seconds remain the primary indicators). All slot behavior untouched. fitted() now
sets root.size for non-container parents. Two-row/compact content variants deliberately
skipped — module scale covers the need (spec allowed "optionally").

## STATUS — P6 SHIPPED (commit 85104a9, same session) + owner playtest round 1

Owner playtested P0–P5 ("mostly working"): two UX misses found + fixed — the anchor dropdown
now SNAPS the module to the picked corner/edge/center (`HudLayout.snap_to_anchor`, 12px inset),
and "Fit Screen" became "Rescue Off-Screen" with status feedback. P6: quest tracker rides a
PANEL chassis (display-font QUESTS title + body-font count) with standard/compact/collapsed
variants, registered EAGERLY at build (edit mode can place it pre-quests — lazy registration
left it unplaceable in fresh sessions); chat (log+input) is one module — UTILITY frame fades
with the log, variants standard/compact/wide/collapsed cover the spec's width/height/collapse
options, input keeps body font + exact focus flow, scale clamped 0.7–1.4. `--hudedit` works
online. Verified: 46 tests exit 0, online pre-connect edit-mode screenshots (chat preview,
collapsed tracker chip, saved-variant round-trip).

## STATUS — P7 SHIPPED (ce9b4ad) + P6/P7 review fixes (be420aa)

P7: 2D target (red rail) + focus (green rail) unit-frame modules fed by the same authoritative
`_focus_id`/`_friend_id` the 3D rings use — Tab/Ctrl+Tab/Esc/death rules untouched; change-gated
text, shared HP ramp, edit previews, defaults flank the zone banner. Party frames became ONE
group module (PANEL chassis + PARTY title at the old (12,250); member rows restyled navy/cyan;
click-to-focus + Leave untouched; sample rows in edit preview; eager registration). Boss target
= the target frame's tier chip (world scoreboard plate stays the richer source).
Consolidated adversarial review (2 finders; verifiers died on session limits → findings
self-verified against code) — all six fixed in be420aa: mob identity (mobs ship mobLevel/
mobTier, never name/level → frame was blank for the primary target type), unit-frame STOP
starving camera input, chat variants unable to shrink (size-before-min clamp + read-back pin),
Enter-on-hidden-chat freezing movement invisibly, one-frame stale focus row, _draw_utility
ignoring body_alpha.

## STATUS — P8 SHIPPED (commit 8f64414, same session)

Hero event banners: ONE queued hero-frame module (in/hold/out; reduce_fx steady-then-cut;
disconnect-suppressed; movable/scalable/hideable — celebrations only, ult telegraph +
disconnect overlay stay un-hideable) replaced the P4 zone card + level flash. Wired states:
zone arrival (+open-pvp sub), level-up, respawn, Circuit Clear, Drill Complete. The 7
proximity hints collapsed into ONE interact-prompt module (keycap chip + verb/target,
change-gated offer/clear per source; all proximity/keybind/auto-close logic untouched;
locker cost dynamic). `--bannertest` dev flag (suppression bypass) for screenshots — note the
banner driver must run pre-snapshot (it sits ABOVE `_process`'s `_state.is_empty()` return).
9 modules now configurable. Verified: banner screenshot over the live world, edit-mode shot
with the prompt preview, 46 tests exit 0, boots clean.

## STATUS — P9 SHIPPED (same session)

- **Meter**: ad-hoc header drag + auto-place REMOVED — the meter is a module now (moves/scales
  in F2, position finally persists; 4 Hz timer + fixed row pool untouched; edit preview opens
  it). Works in the sandbox too (registered in Client._build_hud).
- **Builder panel**: `_lb_lbl` left `_pin_topright` for a lime PANEL chassis with a BUILDER
  badge (autowrapped status text, module "builder_panel", eager-registered via
  `_lb_set_on(false)` at _enter_mode, edit preview shows sample status).
- **Bottom nav**: NEW module — 10 buttons for the REAL panels with their REAL keybinds
  (Inventory I … Settings O), selected-state recolor (change-gated per frame), hidden
  pre-snapshot, hideable for keyboard-only players. Reuses the flat _meter_btn chrome.
- **Gotcha (twice-learned)**: modules hidden at build never lay out (size 0) — ANY module that
  starts hidden needs an edit-preview that shows it, or its editor rect collapses pre-trigger.

### Minimap feasibility audit (P9 deliverable — implementation deferred)

FEASIBLE, pure client, zero protocol change. Data already client-side: `_state.fighters`
(interest-filtered ~30 Hz — drawing exactly this reveals nothing beyond nameplates, satisfying
the no-hidden-info rule BY CONSTRUCTION), `_state.portals`, zone pads (META), rectangular map
bounds (same source the F3 coords overlay uses). Design: one "minimap" module, ~180px custom
`_draw()` Control — bounds rect → schematic box; self = oriented arrow; fighters = dots
(hostile red / friendly class-color); portals = diamonds; pads = color-coded squares;
north-up. Redraw on a 10 Hz timer (bounded ≤ ~40 dots). Est. ~150 lines in NetClient +
registration. Recommended slot: its own small session (needs owner eyeball on live camps).

12 modules configurable: player_frame, hotbar, quest_tracker, chat, target_frame, focus_frame,
party_frames, event_banner, interact_prompt, meter, builder_panel, bottom_nav.

## STATUS — P10 + P11 SHIPPED (a7842f9, b439c8a — same session)

P10: window chrome joined the pattern (navy body + cyan-tinted rail via the ONE Theme; cyan
title-rule separators); Build Shop added to the Esc cascade (the one window missing);
verified Settings window at 100%/150% global scale (clamped, readable, grip reachable);
`--opennow <panel>` dev flag. Deliberately skipped per spec: no window-manager expansion —
headers/✕/size-persistence were already consistent.
P11: Settings HUD section consolidated — profile dropdown (applies+saves), bulk HUD-opacity
slider (HudLayout.set_all_opacity; per-module stays in F2), Fit Layout to Screen, plus the
existing UI scale/Edit/Reset entries. "Reduce screen effects" documented as the reduced-
HUD-motion option (it gates banner fades/toast slides/frame glow). Colorblind: no status is
color-only by construction (numbers/wipes/ticks/text accompany every color cue).

## STATUS — MINIMAP SHIPPED (commit ecd95f8, same session)

13 modules now. Schematic top-down drawn from the interest-filtered snapshot only (no hidden
info — adversarial review confirmed the server filters the fighter list + phased bosses were
already world-visible). Custom `_draw`, 10 Hz visible-only timer, mouse-transparent.
**Defaults HIDDEN** (opt in via F2) so it can't land on a returning player's saved layout —
this is the safe default; a visible-by-default minimap for NEW players would need a
`layout_version` bump + migration (owner call). 2-finder adversarial review (all confirmed,
fixed pre-commit): letterbox uniform scale (non-square maps were stretching dots + desyncing
the self-arrow ~11–15°); skip fighters/self until a valid self-reference (pre-assign race
mis-colored mobs); hidden default + reverted the quest_tracker/builder default nudges.
`--minimap` dev flag. Verified: 46 tests exit 0, boot clean, clean render screenshot.

## MENU-THEMING PASS (2026-07-13, commits 7aa25b8…9255322) — separate from the HUD program

Owner asked to bring the rest of the menus/screens onto the HUD's sports-tech pattern and fix
readability. Audited every non-HUD surface (workflow) → the Theme already covered every Control
type; the gap was panels bypassing it with bespoke inline styleboxes + old-palette accents.
Done (mostly central, so one change lifts many panels):
- **UITheme**: accents repointed from the pre-pattern palette (gold ACCENT / soft-cyan ACCENT2)
  to SB_CYAN/SB_LIME — buttons (navy body + cyan rail + cyan press, was flat grey/gold),
  OptionButton/MenuButton, LineEdit/TextEdit, sliders (+ procedural cyan grabber knob),
  scrollbars, PopupMenu, ProgressBar; NEW TooltipPanel/TooltipLabel (native tooltips were
  unstyled); procedural CheckBox cyan-box/lime-tick glyphs.
- **Widgets**: NEW `tile_box()` (replaces the SAME inline stylebox duplicated in _rarity_box/
  _inv_tile/_build_item_tile → restyles Inventory/Shop/Forge/Craft/Build tiles), `toggle_btn()`
  (filled-cyan active pill), `tab_row()` (cyan-underline active tab); `section()` + window
  titles use the display font WITH a `display_safe()` guard (Sportbound Strike is caps-only w/
  limited punctuation — parens/symbols/sentences fall back to the body font). `Palette.SUCCESS`.
- **Login (Account.gd)**: display-font "LEGENDS MMO" wordmark + radial navy→ink backdrop +
  display card titles + cyan title rules.
- **Biggest usability fixes**: Quest Giver Accept/Turn In/Claim were bbcode [url] TEXT LINKS →
  real button rows (`_qg_action_row`); Leaderboard 5 tabs were indistinguishable → tab_row;
  Inventory/Shop sort+filter toggles → toggle_btn; sell-confirm → PanelContainer + orange
  Confirm; framed dye swatches (dark dyes were invisible); tiles get a pointing-hand cursor +
  common items lifted to readable contrast.
- Adversarial review (3-finder + verify): qgiver rewrite / leaderboard / theme = ZERO defects;
  2 low bugs fixed (sell-confirm 0×0 Panel→PanelContainer; section ✦/📋 tofu → glyphs dropped).

Follow-up round (commits e2ec387…d9350c8): fixed an owner-reported z-order bug — the quest
tracker / minimap / bottom-nav (modules registered late in _enter_mode) drew OVER the
full-screen loadout; now every HudLayout module wrapper is z_index -6 (below panels/windows/
modals at 0, above the vignette at -20) so the HUD consistently sits UNDER anything the player
opens. Plus: charsheet section headers now cyan; admin F1 panel grouped (display title +
Widgets.section groups + teleport grid, was 19 buttons in one column); paperdoll cells 34px +
rarity border + pointing cursor.

**Optional remaining polish** (audit flagged, NOT done — all cosmetic, none blocking): charsheet
+ quest-journal are still RichTextLabel blobs using retyped bbcode hex literals (readable, just
not Palette.hex-tokenized); camp intensity tiers could be Widgets.tile cards. Owner playtest of
the re-themed menus owed.

⚠ TEST-HYGIENE NOTE: my screenshot runs polluted the owner's real user://settings.cfg with test
module values (removed the bad `minimap` entry; hotbar 1.6 / chat 0.7 may be mine or theirs).
Live client `--shot` runs read+write the owner's settings.cfg (user:// can't be redirected for
a live client) — future runs must restore from scratchpad/owner_settings.clean and never inject
test values into the live file.

## REMAINING (HUD program)

- **P12 branding/licensing gate — OWNER DECISIONS, not code**: (1) keep "Legends MMO" or adopt
  Sportbound identity (logos are reference-only until decided); (2) production display font:
  clear/replace the Sportbound Strike prototype (see client/ui/fonts/FONTS-README.md
  checklist) before any commercial build; (3) final asset provenance/attribution doc.
- Owner playtest of P7–P11 (unit frames, banners, prompt, meter-in-F2, nav, settings).
- Push the commit train (de6a707…b439c8a) to GitHub when ready.
