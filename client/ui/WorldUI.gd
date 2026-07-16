class_name WorldUI
extends RefCounted
## UI-overhaul P3 — the 3D-world UI's shared language. Label3D + procedural meshes can't take the
## screen-space Theme, so the world layer reads its sizes + colors from here (reusing Palette where the
## two render worlds should agree). Gives the nameplates, pad labels and HP bars one visual language.
## Kept free of GameData (no class_name there) — callers pass already-resolved class colors.

# Label3D sizing (promoted from the magic numbers scattered through _spawn + the pad renderers).
# UI-consistency pass: sizes restrained (56/46/52 → 46/38/44) — fixed_size billboards render at
# constant screen size, so the old values shouted over every window and read as clutter.
const PLATE_FONT := 42
const PLATE_NAME := 34        # player character-name line (prominent, sits above the bar)
const PLATE_LEVEL := 20       # player level line — deliberately small, tucked under the name
const PLATE_PIXEL := 0.0016
const PLATE_OUTLINE := 13
const PAD_FONT := 38
const PAD_PIXEL := 0.0016
const PAD_OUTLINE := 13
const OUTLINE_COLOR := Color(0, 0, 0, 0.9)

# --- UI-consistency pass: world-label fade tokens (distances in 3D world units; Client.SCALE
#     maps sim→world, home base ≈ 48×27 units). Labels never fully vanish — wayfinding keeps a
#     floor — and everything drops to WINDOW_FADE while a large data window is open.
const PAD_FADE_NEAR := 12.0   # pads at full alpha inside this camera distance
const PAD_FADE_FAR := 35.0    # … down to PAD_FADE_MIN by here
const PAD_FADE_MIN := 0.22
const PLATE_FADE_NEAR := 12.0
const PLATE_FADE_FAR := 32.0
const PLATE_FADE_MIN := 0.35
const WINDOW_FADE := 0.12     # world text while a big window is open (readability behind windows)

static func pad_fade(dist: float) -> float:
	return remap(clampf(dist, PAD_FADE_NEAR, PAD_FADE_FAR), PAD_FADE_NEAR, PAD_FADE_FAR, 1.0, PAD_FADE_MIN)

static func plate_fade(dist: float) -> float:
	return remap(clampf(dist, PLATE_FADE_NEAR, PLATE_FADE_FAR), PLATE_FADE_NEAR, PLATE_FADE_FAR, 1.0, PLATE_FADE_MIN)

# THE service/portal pad label — one factory for the six clones (portals + quest giver, shop,
# build shop, vendor, forge) that each hand-rolled this shape with drifting magic numbers.
static func pad_label(text: String, tint: Color, pos: Vector3) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = PAD_PIXEL
	lbl.font_size = PAD_FONT
	lbl.outline_size = PAD_OUTLINE
	lbl.outline_modulate = OUTLINE_COLOR
	lbl.modulate = tint
	lbl.position = pos
	return lbl

# HP bar — a 3-stop ramp so "getting low" reads before it's critical (was a single 35% flip)
const HP_FULL := Color(0.3, 0.85, 0.4)
const HP_MID := Color(0.94, 0.78, 0.3)
const HP_LOW := Color(0.9, 0.3, 0.3)

# nameplate text semantics (aligned with Palette's screen colors)
const HOSTILE := Color(1.0, 0.45, 0.45)     # a plate that WILL hurt you — always red, never overridden
const MOB_LEVEL := Color(0.92, 0.82, 0.6)
const MOB_ELITE := Color(1.0, 0.55, 0.4)
const DUMMY := Color(0.72, 0.74, 0.8)
const CORE := Color(0.32, 0.86, 1.0)

static func hp_color(frac: float) -> Color:
	if frac < 0.3:
		return HP_LOW
	if frac < 0.6:
		return HP_MID
	return HP_FULL

# a friendly player's plate reads in their (brightened) class color — identity at a glance without
# touching the gameplay-critical hostile red. `class_col` is the resolved GameData class Color.
static func friendly_plate(class_col: Color) -> Color:
	return class_col.lightened(0.3)
