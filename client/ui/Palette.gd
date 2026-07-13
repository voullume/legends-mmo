class_name Palette
extends RefCounted
## UI-overhaul P0 — the codified palette. These are the hexes that were retyped ad-hoc across
## NetClient/Client promoted to named tokens; every restyle reads from here so the screen UI and
## the 3D-world UI (Label3D/meshes, which can't take a Theme) share one language.

# --- surfaces / chrome ---
const BG := Color(0.05, 0.06, 0.09)                    # backdrop / near-opaque tooltip ground
const BG_PANEL := Color(0.043, 0.058, 0.095, 1.0)      # pop-up panel chrome — SOLID dark navy.
                                                       # (0.94→0.985 still bled the busy 3D world
                                                       #  through windows; data menus must be opaque)
const BG_INSET := Color(0.10, 0.12, 0.16, 0.92)        # tiles / inset boxes / buttons at rest
const BG_HOVER := Color(0.17, 0.20, 0.25, 0.96)        # hovered tile/button
const BG_PRESSED := Color(0.07, 0.085, 0.115, 0.98)
const BORDER := Color(0.30, 0.36, 0.46, 0.9)
const BORDER_BRIGHT := Color(0.48, 0.56, 0.70)

# --- accents (the scoreboard/jumbotron identity) ---
const ACCENT := Color("#ffd24d")       # gold
const ACCENT2 := Color("#8ad6ff")      # cyan

# --- text hierarchy ---
const TEXT_BRIGHT := Color("#eef2f7")
const TEXT := Color("#cfd6df")
const TEXT_DIM := Color("#7f93a8")
const TEXT_FAINT := Color("#5a6472")

# --- semantic colors ---
const XP := Color("#9fe8a0")
const CREDITS := Color("#ffd24d")
const SCRAP := Color("#c9a36a")
const TOKENS := Color("#4fd4ff")
const DANGER := Color("#ff6b6b")
const DANGER_SOFT := Color("#ff8a8a")
const HEAL := Color(0.44, 0.88, 0.54)
const SHIELD := Color(0.5, 0.72, 1.0)
const LAVENDER := Color("#cdbcff")
const HP := Color(0.3, 0.85, 0.4)
const HP_LOW := Color(0.9, 0.3, 0.3)
const SUCCESS := Color("#9fe8a0")      # the "ready/done/equipped/NEW" green (was hand-typed ~7×)

# --- ability-tooltip / class-preview number colors (centralizes the skill-card palette) ---
const DMG := Color("#ff9a6b")          # damage numbers
const SHIELD_NUM := Color("#9fd0ff")   # shield numbers (lighter than the SHIELD combat ring)
const CC := Color("#d7c27a")           # crowd control — stun / slow
const INFO := Color("#9fb4c8")         # range / dash / duration / secondary tooltip info

# --- sports-tech pattern tokens (HUD frame language; source: docs/ideas-not-in/hud ui/
#     match-found-tokens.json — deep navy / graphite surfaces, cyan rails, lime ready, orange warn) ---
const SB_NAVY := Color("#0B1324")
const SB_GRAPHITE := Color("#1A1F2B")
const SB_INK := Color("#050B12")
const SB_CYAN := Color("#00E5FF")
const SB_LIME := Color("#A8FF00")
const SB_ORANGE := Color("#FF6A00")

# --- rarity ramp (hex strings: BBCode and Color.html both consume these) ---
const RARITY_HEX := {"common": "#cfd6df", "uncommon": "#7fe08a", "rare": "#5aa0ff",
	"epic": "#c77dff", "legendary": "#ff8c1a", "mythic": "#ff4d6d"}
const UNIQUE_HEX := "#ff9d3c"

# --- type scale (per-role font sizes; the Theme carries the body default) ---
const SIZE_TITLE := 22
const SIZE_SECTION := 16
const SIZE_BODY := 15
const SIZE_CAPTION := 12

static func hex(c: Color) -> String:
	return "#" + c.to_html(false)
