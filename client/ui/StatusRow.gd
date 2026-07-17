class_name StatusRow
extends HBoxContainer
## UI-consistency §3c — THE reusable status-chip row. One instance rides under each frame's HP
## strip (self / target / focus / party); every behavior lives here or in StatusIcons (the
## registry) — the frames only call drive(st) with the fighter's snapshot `st` dict each frame.
##   • classification / priority / deterministic sort → StatusIcons.decode
##   • cap + "+n" overflow chip (self 6, others 5 — set `cap`)
##   • compact icon chrome: a Hybrid-Cutout SVG (IconWidget/IconRegistry) centered in the ink chip,
##     modulated to the buff/debuff semantic color, over the amount badge + duration underbar. The
##     centered mark replaces the old two-letter glyph Label; the glyph survives ONLY as a fallback
##     if a texture is ever absent (never a two-letter abbreviation once the asset exists).
##   • native tooltip per chip (themed TooltipPanel); MOUSE_FILTER_PASS so combat clicks and the
##     party-row select still land underneath.
## Chips rebuild only when the status COMPOSITION changes; per-frame drives just refresh the
## underbar/amount/tooltip in place (snapshots arrive every tick — values are set, not ticked).

var cap := 5                # max status chips before the overflow chip takes over
var chip_px := 18           # square chip edge, px (self 22 / target-focus 18 / party rows 14)

var _sig := ""              # rendered composition signature ("keyC|…|+n") — rebuild gate
var _uid := ""              # whose statuses these are — a unit swap resets underbar baselines
var _chips := []            # [{key, root, glyph, amt, bar, base}] in display order
var _over: Label = null     # the "+n" overflow label (inside its own chip chassis)

func _init() -> void:
	add_theme_constant_override("separation", 3)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

# `uid` = the displayed unit's id: retargeting between units with the SAME chip composition must
# still reset the chips (else the old unit's underbar baselines carry over — review catch).
func drive(st: Dictionary, uid := "") -> void:
	if uid != _uid:
		_uid = uid
		if _sig != "":
			_clear()
	var entries: Array = StatusIcons.decode(st) if not st.is_empty() else []
	visible = not entries.is_empty()
	if entries.is_empty():
		if _sig != "":
			_clear()
		return
	var shown: Array = entries.slice(0, cap)
	var hidden: int = entries.size() - shown.size()
	var sig := ""
	for e in shown:
		# classification rides the signature: the shared buffs.ms slot can flip haste↔self-slow
		# without changing keys, and the chip's color/border are fixed at build time
		sig += str(e["key"]) + ("D" if bool(e["debuff"]) else "B") + "|"
	sig += "+%d" % hidden
	if sig != _sig:
		_rebuild(shown, hidden)
		_sig = sig
	for i in shown.size():                       # refresh the live bits in place
		_update_chip(_chips[i], shown[i])

func _clear() -> void:
	_sig = ""
	_chips.clear()
	_over = null
	for c in get_children():
		c.queue_free()

func _rebuild(shown: Array, hidden: int) -> void:
	_clear()
	for e in shown:
		_chips.append(_make_chip(e))
	if hidden > 0:
		var od := _chip_chassis(Palette.TEXT_DIM, false)
		_over = Label.new()
		_over.text = "+%d" % hidden
		_over.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_over.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_over.set_anchors_preset(Control.PRESET_FULL_RECT)
		_over.add_theme_font_size_override("font_size", _glyph_size())
		_over.add_theme_color_override("font_color", Palette.TEXT_DIM)
		_over.mouse_filter = Control.MOUSE_FILTER_IGNORE
		(od["root"] as Control).add_child(_over)
		(od["root"] as Control).tooltip_text = "%d more status effect%s" % [hidden, "" if hidden == 1 else "s"]
		add_child(od["root"])

func _glyph_size() -> int:
	return maxi(8, int(chip_px * 0.5))

# the shared chip chassis: ink body + a colored rail (debuffs run hotter borders by design)
func _chip_chassis(color: Color, debuff: bool) -> Dictionary:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(chip_px, chip_px)
	p.mouse_filter = Control.MOUSE_FILTER_PASS   # tooltip works; clicks fall through to the frame
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SB_INK, 0.92)
	sb.set_border_width_all(1)
	sb.border_color = Color(color, 0.95 if debuff else 0.7)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(0)
	p.add_theme_stylebox_override("panel", sb)
	return {"root": p, "sb": sb}

func _make_chip(e: Dictionary) -> Dictionary:
	var cd := _chip_chassis(e["color"], bool(e["debuff"]))
	var root: PanelContainer = cd["root"]
	var inner := Control.new()                   # free-position canvas inside the chip
	inner.custom_minimum_size = Vector2(chip_px, chip_px)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(inner)
	var g := _make_mark(e)                        # centered icon TextureRect (or glyph fallback)
	inner.add_child(g)
	var a := Label.new()                         # amount badge (absorb / charges / stacks), bottom-right
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	a.size = Vector2(chip_px - 2, 10)
	a.position = Vector2(0, chip_px - 11)
	a.add_theme_font_size_override("font_size", maxi(7, int(chip_px * 0.38)))
	a.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	a.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	a.add_theme_constant_override("outline_size", 3)
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(a)
	var bar := ColorRect.new()                   # remaining-duration underbar (vs max seen)
	bar.color = Color(e["color"], 0.9)
	bar.position = Vector2(1, chip_px - 3)
	bar.size = Vector2(chip_px - 2, 2)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(bar)
	add_child(root)
	return {"key": str(e["key"]), "root": root, "mark": g, "amt": a, "bar": bar,
		"base": maxf(0.001, float(e["remaining"]))}

# the centered chip mark: the Hybrid-Cutout SVG icon (modulated to the chip's semantic color), inset
# 1px inside the chassis border so the amount badge + duration underbar drawn over it stay legible —
# even at the 14px party-row size (the hardest case, handoff §10). Falls back to the old centered
# two-letter glyph Label only when the texture is genuinely absent (staged migration / missing asset).
func _make_mark(e: Dictionary) -> Control:
	var icon_id := str(e.get("icon", ""))
	if icon_id != "" and IconRegistry.texture(icon_id) != null:
		var art := maxi(8, chip_px - 2)
		var ic := IconWidget.make(icon_id, {"px": art, "color": e["color"]})
		# anchor the icon to FILL the chip (1px inset, 2px reserved at the bottom for the duration
		# underbar) so its size is DERIVED from the chip on every layout — a plain explicit `.size`
		# on a free-canvas TextureRect does not survive a relayout and blows up to the texture size.
		ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ic.offset_left = 1
		ic.offset_top = 1
		ic.offset_right = -1
		ic.offset_bottom = -2
		return ic
	var g := Label.new()                         # text fallback (never a two-letter abbrev once art exists)
	g.text = str(e["glyph"])
	g.size = Vector2(chip_px, chip_px - 2)
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_theme_font_size_override("font_size", _glyph_size())
	g.add_theme_color_override("font_color", e["color"])
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return g

func _update_chip(c: Dictionary, e: Dictionary) -> void:
	(c["amt"] as Label).text = str(e["amount"])
	(c["root"] as Control).tooltip_text = str(e["tip"])
	var rem := float(e["remaining"])
	var bar: ColorRect = c["bar"]
	if rem < 0.0:
		bar.visible = false                      # untimed (nextdmg) — active until consumed
		return
	bar.visible = true
	if rem > float(c["base"]):                   # refreshed/extended → new full width
		c["base"] = rem
	bar.size.x = maxf(1.0, (chip_px - 2) * clampf(rem / float(c["base"]), 0.0, 1.0))
