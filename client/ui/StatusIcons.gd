class_name StatusIcons
extends RefCounted
## UI-consistency §3c — the CENTRAL buff/debuff registry. Decodes the compact snapshot `st` dict
## (see Server.status_st: timers = tenths-of-seconds ints, magnitudes = percent ints) into
## normalized chip entries; classification (buff/debuff), display priority, glyphs, colors and
## tooltip copy all live HERE — the StatusRow component renders whatever this returns, so every
## frame (self / target / focus / party) stays in lockstep. Glyph chips only (chrome language,
## no art dependency); real icon textures can replace `glyph` later without touching the flow.

# Registry — insertion order IS the stable sort tiebreaker. `w` = wire format:
#   t   → plain tenths int (remaining seconds)
#   pt  → [percent, tenths]
#   at  → [amount, tenths]          (shield: absorb value)
#   tp  → [tenths, percent]         (slow — note the reversed order on the wire)
#   ct  → [count, tenths]           (guard charges / dot stacks)
#   p   → plain percent, NO timer   (nextdmg — active until consumed)
const DEFS := {
	"stn": {"glyph": "✕", "name": "Stunned", "debuff": true, "color": Palette.DANGER, "w": "t"},
	"slw": {"glyph": "SL", "name": "Slowed", "debuff": true, "color": Palette.SB_ORANGE, "w": "tp"},
	"dot": {"glyph": "DT", "name": "Burning", "debuff": true, "color": Palette.DANGER, "w": "ct"},
	"sh": {"glyph": "SH", "name": "Shield", "debuff": false, "color": Palette.SHIELD, "w": "at"},
	"ba": {"glyph": "BA", "name": "Barrier", "debuff": false, "color": Palette.LAVENDER, "w": "pt"},
	"dr": {"glyph": "DR", "name": "Damage Reduction", "debuff": false, "color": Palette.SB_CYAN, "w": "pt"},
	"gd": {"glyph": "GD", "name": "Guard", "debuff": false, "color": Palette.SB_CYAN, "w": "ct"},
	"rf": {"glyph": "RF", "name": "Reflect", "debuff": false, "color": Palette.SB_CYAN, "w": "t"},
	"by": {"glyph": "BY", "name": "Shield Pierce", "debuff": false, "color": Palette.ACCENT, "w": "t"},
	"nx": {"glyph": "NX", "name": "Empowered", "debuff": false, "color": Palette.ACCENT, "w": "p"},
	"cr": {"glyph": "CR", "name": "Critical Chance", "debuff": false, "color": Palette.ACCENT, "w": "pt"},
	"as": {"glyph": "AS", "name": "Attack Speed", "debuff": false, "color": Palette.ACCENT, "w": "pt"},
	"ms": {"glyph": "MS", "name": "Move Speed", "debuff": false, "color": Palette.HEAL, "w": "pt"},
	"ev": {"glyph": "EV", "name": "Evasion", "debuff": false, "color": Palette.HEAL, "w": "t"},
	"ut": {"glyph": "UT", "name": "Untargetable", "debuff": false, "color": Palette.HEAL, "w": "t"},
}

# Decode a snapshot `st` dict into DISPLAY-SORTED chip entries:
#   {key, glyph, color, debuff, remaining (secs; -1.0 = untimed), amount (short chip text, "" = none),
#    tip (tooltip), order (registry index)}
# Sort contract (deterministic): debuffs first · then timed effects by shortest remaining
# (untimed after timed) · then stable registry order.
static func decode(st: Dictionary) -> Array:
	var out := []
	var order := 0
	for key in DEFS:
		var def: Dictionary = DEFS[key]
		if st.has(key):
			var e := _decode_one(str(key), def, st[key])
			e["order"] = order
			out.append(e)
		order += 1
	out.sort_custom(func(a, b) -> bool:
		if bool(a["debuff"]) != bool(b["debuff"]):
			return bool(a["debuff"])
		var at := float(a["remaining"])
		var bt := float(b["remaining"])
		if (at >= 0.0) != (bt >= 0.0):
			return at >= 0.0                     # timed before untimed
		if at >= 0.0 and absf(at - bt) > 0.001:
			return at < bt                       # shortest remaining first
		return int(a["order"]) < int(b["order"]))
	return out

static func _decode_one(key: String, def: Dictionary, v) -> Dictionary:
	var remaining := -1.0
	var amount := ""
	var pct := 0
	match str(def["w"]):
		"t":
			remaining = float(v) / 10.0
		"pt":
			pct = int((v as Array)[0])
			remaining = float((v as Array)[1]) / 10.0
		"at":
			amount = str(int((v as Array)[0]))
			remaining = float((v as Array)[1]) / 10.0
		"tp":
			remaining = float((v as Array)[0]) / 10.0
			pct = int((v as Array)[1])
		"ct":
			amount = str(int((v as Array)[0]))
			remaining = float((v as Array)[1]) / 10.0
		"p":
			pct = int(v)
	var color: Color = def["color"]
	var debuff: bool = def["debuff"]
	var name := str(def["name"])
	var tip := name
	match key:
		"ms":
			if pct < 100:                        # the same wire slot carries haste AND self-slow
				debuff = true                    # (e.g. Goal-Line Stand) — direction decides the read
				color = Palette.SB_ORANGE
				name = "Self-Slow"
				tip = "Self-Slow −%d%%" % (100 - pct)
			else:
				tip = "Haste +%d%%" % (pct - 100)
		"as":
			tip = "Attack Speed +%d%%" % (pct - 100)
		"cr":
			tip = "Critical Chance +%d%%" % pct
		"dr":
			tip = "Damage Reduction %d%%" % pct
		"ba":
			tip = "Barrier — %d%% damage reduction" % pct
		"slw":
			tip = "Slowed %d%%" % pct
		"nx":
			tip = "Empowered — next special ×%.1f (until used)" % (float(pct) / 100.0)
		"sh":
			tip = "Shield — absorbs %s" % amount
		"gd":
			tip = "Guard — knocks back the next melee attacker (%s charge%s)" % [amount, "" if amount == "1" else "s"]
		"dot":
			tip = "Burning ×%s" % amount
		"rf":
			tip = "Reflect — returns the next hit"
		"by":
			tip = "Shield Pierce — attacks bypass shields"
		"ev":
			tip = "Evasion — dodging attacks"
		"ut":
			tip = "Untargetable"
		"stn":
			tip = "Stunned"
	if remaining >= 0.0:
		tip += "  ·  %.1fs" % remaining
	return {"key": key, "glyph": str(def["glyph"]), "color": color, "debuff": debuff,
		"remaining": remaining, "amount": amount, "tip": tip}
