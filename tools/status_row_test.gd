extends SceneTree
## Permanent Hybrid-Cutout UI icon system — StatusRow texture-conversion suite (handoff §14). Drives
## a real StatusRow with wire-format `st` dicts and pins: the chip mark is now an icon TextureRect
## (not a two-letter Label), amount badges + duration bars survive, tooltips carry StatusIcons copy,
## overflow "+n" still caps, a retarget (uid swap) resets underbar baselines, Move Speed flips
## haste↔self-slow color while SHARING one asset, and a missing icon falls back to plain text.
## Headless-safe; exits non-zero on any failure.
##   ~/.local/bin/godot --headless --path . --script res://tools/status_row_test.gd

const StatusRowS := preload("res://client/ui/StatusRow.gd")
const IconReg := preload("res://client/ui/IconRegistry.gd")
const PaletteS := preload("res://client/ui/Palette.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

func _chip_by_key(row, key: String) -> Dictionary:
	for c in row._chips:
		if str(c["key"]) == key:
			return c
	return {}

func _init() -> void:
	print("[status_row_test] running")

	# ---- 1. a driven row builds icon TextureRect marks (not letter Labels) ----
	var row = StatusRowS.new()
	root.add_child(row)
	row.chip_px = 18
	row.drive({"dr": [25, 20], "ms": [120, 25], "sh": [57, 30], "gd": [1, 20]}, "unitA")
	ok(row.visible, "row visible when statuses present")
	ok(row._chips.size() == 4, "4 chips built (got %d)" % row._chips.size())
	for c in row._chips:
		ok(c["mark"] is TextureRect, "chip '%s' mark is a TextureRect" % c["key"])
		ok((c["mark"] as TextureRect).texture != null, "chip '%s' mark has a texture" % c["key"])
	var dr := _chip_by_key(row, "dr")
	ok((dr["mark"] as TextureRect).texture == IconReg.texture("damage_reduction"), "dr → damage_reduction texture")

	# ---- 2. amount badges (absorb / charges) survive ----
	ok(str((_chip_by_key(row, "sh")["amt"] as Label).text) == "57", "shield amount badge = 57")
	ok(str((_chip_by_key(row, "gd")["amt"] as Label).text) == "1", "guard charge badge = 1")

	# ---- 3. duration bars: timed visible, untimed hidden ----
	row.drive({"dr": [25, 20], "nx": 170}, "unitA")
	ok((_chip_by_key(row, "dr")["bar"] as ColorRect).visible, "timed dr → duration bar visible")
	ok(not (_chip_by_key(row, "nx")["bar"] as ColorRect).visible, "untimed nx → duration bar hidden")

	# ---- 4. tooltip carries StatusIcons copy ----
	var drtip := str((_chip_by_key(row, "dr")["root"] as Control).tooltip_text)
	ok(drtip.begins_with("Damage Reduction 25%"), "dr chip tooltip = StatusIcons copy (got '%s')" % drtip)

	# ---- 5. overflow "+n" caps the visible chips ----
	row.cap = 5
	row.drive({"stn": 5, "slw": [12, 30], "dot": [2, 23], "sh": [57, 30], "ba": [70, 30], "dr": [25, 20], "gd": [1, 20]}, "unitA")
	ok(row._chips.size() == 5, "cap 5 → 5 chips (got %d)" % row._chips.size())
	ok(row._over != null and str(row._over.text) == "+2", "overflow chip shows +2 (got '%s')" % (row._over.text if row._over else "nil"))

	# ---- 6. retarget (uid swap) resets underbar baselines ----
	row.drive({"dr": [25, 50]}, "unitA")                     # dr with 5.0s remaining → base 5.0
	ok(absf(float(_chip_by_key(row, "dr")["base"]) - 5.0) < 0.01, "unitA dr base = 5.0s")
	row.drive({"dr": [25, 20]}, "unitB")                     # SAME composition, NEW unit, 2.0s remaining
	ok(absf(float(_chip_by_key(row, "dr")["base"]) - 2.0) < 0.01, "retarget reset base to 2.0s (no carry-over)")

	# ---- 7. Move Speed: shared asset, color flips haste↔self-slow ----
	row.drive({"ms": [120, 25]}, "unitA")
	var haste := _chip_by_key(row, "ms")
	ok((haste["mark"] as TextureRect).modulate == PaletteS.HEAL, "haste ms modulated HEAL (lime/green)")
	var haste_tex = (haste["mark"] as TextureRect).texture
	row.drive({"ms": [80, 25]}, "unitA")
	var slow := _chip_by_key(row, "ms")
	ok((slow["mark"] as TextureRect).modulate == PaletteS.SB_ORANGE, "self-slow ms modulated SB_ORANGE")
	ok((slow["mark"] as TextureRect).texture == haste_tex, "haste + self-slow SHARE the move_speed asset")
	ok((slow["mark"] as TextureRect).texture == IconReg.texture("move_speed"), "shared asset is move_speed")

	# ---- 8. missing-icon fallback → plain text Label (never a two-letter abbrev... unless art absent) ----
	var mk = row._make_mark({"icon": "does_not_exist", "glyph": "XX", "color": Color.WHITE})
	ok(mk is Label and str((mk as Label).text) == "XX", "missing icon → glyph Label fallback")
	mk.free()

	# ---- 9. clearing to empty hides the row ----
	row.drive({}, "unitA")
	ok(not row.visible, "empty st → row hidden")
	ok(row._chips.is_empty(), "empty st → no chips")

	row.free()
	print("[status_row_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
