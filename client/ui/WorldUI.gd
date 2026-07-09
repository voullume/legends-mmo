class_name WorldUI
extends RefCounted
## UI-overhaul P3 — the 3D-world UI's shared language. Label3D + procedural meshes can't take the
## screen-space Theme, so the world layer reads its sizes + colors from here (reusing Palette where the
## two render worlds should agree). Gives the nameplates, pad labels and HP bars one visual language.
## Kept free of GameData (no class_name there) — callers pass already-resolved class colors.

# Label3D sizing (promoted from the magic numbers scattered through _spawn + the pad renderers)
const PLATE_FONT := 56
const PLATE_NAME := 46        # player character-name line (prominent, sits above the bar)
const PLATE_LEVEL := 20       # player level line — deliberately small, tucked under the name
const PLATE_PIXEL := 0.0016
const PLATE_OUTLINE := 16
const PAD_FONT := 52
const PAD_PIXEL := 0.0016
const PAD_OUTLINE := 16
const OUTLINE_COLOR := Color(0, 0, 0, 0.9)

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
