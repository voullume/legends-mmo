# Text-UI / Sports-Tech Theme Audit — Part A + B

Discovery pass for the world-text & nameplate theme work (`docs/text-ui-theme-updated-handoff.pdf`).
Produced by a 4-way parallel static audit of `client/` + a completeness critic (99 raw findings → 94
unique elements). Each entry: node type · current font/color source · drift · correction · **status**.

Line numbers were current at audit time and **drift as the file changes — re-grep the symbol**. Status
key: **✅ FIXED** this pass · **🟡 OWNER** (verified drift, correction deferred to an owner design call —
see *Remaining visual decisions*) · **➖ COMPLIANT** (listed for completeness, no change).

---

## A. World-space (Label3D / Sprite3D / mesh) — not theme-reachable, hand-styled

| Element | Symbol | Node | Drift | Correction | Status |
|---|---|---|---|---|---|
| Player name line | `_update_player_plate` | Label3D | was `fixed_size` (dwarfed char at far zoom); resident `◆` rode the string | world-proportional billboard in a scaled `plate` group; **body font** (arbitrary glyphs); `WorldUI.HOSTILE`/`friendly_plate` preserved; bounded `clamp_name` | ✅ FIXED |
| Player level line + `⚔` hostile marker | `_update_player_plate` | Label3D | `font_size` rewritten every frame; `⚔` glyph folded into the level string (display-font fallback) | metrics set **once at spawn**; **display face** `LV %d` (caps-safe); hostility = red plate color (`⚔` dropped) | ✅ FIXED |
| Wobble pips (`⟳ ◆ ◇`) | `_update_player_plate` | Label3D (appended) | pips string-appended onto the level label → **reflowed** the plate when they appeared/vanished | dedicated **4-quad pip strip** near the HP bar (`WorldUI.PIP_*`), own reserved slot, no reflow | ✅ FIXED |
| Nameplate backing | (new) `WorldUI.plate_backing` | quads | bare floating text, no chrome | restrained billboarded **UTILITY-style chip** — navy/ink body + thin cyan rail, no glow | ✅ FIXED |
| Overhead buff/debuff chips | (new) `_drive_overhead_status` | SubViewport→Sprite3D | did not exist (owner ask) | self-only `StatusRow` in one SubViewport, debuff-first, cap 4 + "+n", same fade | ✅ FIXED |
| Damage/heal/crit/shield/burn/bystander floaters | `_spawn_num` | Label3D (pooled) | `pixel_size 0.0011` / `font 96` / `outline 22` + 8 inline color literals (2 byte-identical to `Palette.HEAL`/`SHIELD`) | moved size/outline/**8 semantic colors** to `WorldUI.FLOAT_*` (byte-identical); reuse `Palette.HEAL`/`SHIELD`; outline reuses `OUTLINE_COLOR`; **motion timing left inline** (combat-feel, not theme) | ✅ FIXED |
| Boss ult-warning color | `_update_mob_plate` | Label3D | `Color(1.0,0.2,0.2)` inline | `WorldUI.BOSS_ULT` (same value) | ✅ FIXED |
| Boss core-shielded color | `_update_mob_plate` | Label3D | `Color(0.4,0.82,1.0)` inline | `WorldUI.BOSS_SHIELDED` (same value) | ✅ FIXED |
| Boss phase ramp | `_update_mob_plate` | Label3D | 4-stop `pcol` array inline | `WorldUI.BOSS_PHASE` (same values) | ✅ FIXED |
| Boss plate emoji `⚠ ☠ 🛡` + `·` | `_update_mob_plate` | Label3D | emoji/middot force the body font off the display face; **unreliable fallback** | remove/replace with theme glyphs OR a themed multi-line plate — **gameplay-critical, byte-identical across GY bosses, unverifiable offline** | 🟡 OWNER |
| `◈ POWER CORE` label | `_update_mob_plate` | Label3D | `◈` forces body font on a short-uppercase identity label; unbacked | display face `POWER CORE` (drop/relocate `◈`) + restrained backing; keep `WorldUI.CORE` tint | 🟡 OWNER |
| `Training Dummy` label | `_update_mob_plate` | Label3D | title-case body font, unbacked world identity | display face (uppercase) + restrained backing; keep `WorldUI.DUMMY` tint | 🟡 OWNER |
| Pad/portal labels (`📜🛒🔨◈`) | `WorldUI.pad_label` | Label3D | emoji stay body font (v1.8.0) | acceptable (body font); emoji-vs-drawn-glyph is an owner call | ➖ COMPLIANT |

## B. Screen-space (Control) — themed post-v1.8.0; residual drift

| Element | Symbol | Node | Drift | Correction | Status |
|---|---|---|---|---|---|
| **Every window title** (root cause) | `Widgets.panel` | Label | applied the caps-only display face **unconditionally** — unlike `Widgets.section` which gates on `display_safe()`; any title with an emoji / em-dash / `◈` / `·` forced the face onto glyphs it lacks | **panel() now mirrors section()**: display-safe → uppercased display face; else → body font. One fix covers all titles. Pinned by `tools/widgets_title_test.gd` | ✅ FIXED |
| Window-title emoji (`📜🎨🏆⚔🌳⭐◈`) | `_build_*` (≈10) | Label | the emoji themselves have no display-font coverage; after the panel() fix they render in the body font but may still lack a glyph | remove the emoji (branded caps, no fallback) **or** replace with drawn glyphs — a per-window content decision; online-only, could not verify offline | 🟡 OWNER |
| DPS/HPS meter rows, juice toasts, admin body, interaction prompts, event/zone subcopy, tooltips, currency tray | various | Label/RichText | mostly compliant post-v1.8.0; scattered hand-typed colors that a `Palette` token already covers (P2) | byte-identical `literal → Palette` swaps — **online-only surfaces; deferred to avoid blind edits I could not screenshot** | 🟡 OWNER |

---

## Deliberate scoping decisions (this pass)

- **Floater motion timing** (rise speed / lifetime: `0.9/1.0/0.82`, `1.8/3.2/2.6`) was **left inline**.
  The audit suggested moving it too, but it is combat-feel, not theme — moving it risks changing feel for
  zero theme benefit. Only the visual identity (size / outline / semantic colors) moved to `WorldUI`.
- **Boss / POWER CORE / Training Dummy** got their **colors tokenized** (zero visual change) but keep their
  text/emoji/font. These are gameplay-critical, byte-identical across the Glitchyard bosses, and cannot be
  screenshotted offline (no boss/core/dummy in the practice sandbox) — so the emoji-removal + display-face +
  backing-plate promotion is **flagged for an owner online eyeball** rather than changed blind.
- **Online-only screen surfaces** (window-title emoji, P2 `literal→token` color swaps): the correction is
  cataloged above but **not applied**, because the online client could not be driven for verification this
  pass, and the handoff is explicit — *correct only verified mismatches; no blind replacement*.
