# HUD fonts — provenance + usage rules

## SportboundStrike-Regular.ttf — PROTOTYPE display face

Source: `docs/ideas-not-in/hud ui/sportbound_strike_typography_package.zip` (generated starter
face from the Sportbound brand package, spec in `SPORTBOUND_STRIKE_TYPE_SPEC.md` there).

**Status: prototype. NOT cleared for commercial release.** Before any public/commercial build:
- verify authorship + license; run name/trademark clearance on "Sportbound Strike";
- refine kerning (SP PO RT BO UN ND EA PL AY) and optical corrections (S G R W M Q);
- add missing punctuation/symbol/i18n glyph coverage or formally declare caps-only;
- provide a production fallback chain.

**Allowed uses** (via `HudFonts.display_label()` only): major headings, zone titles, boss/event
banners, timers, short panel headers, short mode badges, logo prototypes.

**Never use for**: body text, quest/item descriptions, chat, tooltips, player names,
localization-sensitive or user-generated strings. Coverage is A–Z (lowercase maps to caps),
0–9, and only `. , : ! ? - _ / + & #` — anything else renders as tofu.

The engine default (Open Sans SemiBold, embedded in Godot) remains the body font everywhere.
`HudFonts.display()` returns null if the TTF is missing and every caller falls back to the
theme font — the game must never hard-depend on this file.

Import is MSDF (multichannel signed distance field) so display text stays crisp under
per-module HUD scaling (0.6–1.6×) and global UI scale.
