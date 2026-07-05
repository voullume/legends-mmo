class_name Widgets
extends RefCounted
## UI-overhaul P0 — reusable chrome factories so panels stop re-deriving the same scaffold.
## Each _build_* migrates onto these one at a time (the Practice Vendor is the pattern-proof).

# The standard pop-up scaffold: CenterContainer(full-rect, hidden) → PanelContainer → Margin →
# VBox, with a styled header row (title + a dim right-aligned key hint + an optional ✕ close button)
# and a rule under it. `on_close` (if a valid Callable) wires the ✕. Returns {root, panel, body, title}
# — caller adds `root` to the HUD and fills `body`.
static func panel(title: String, key_hint := "", min_width := 560.0, on_close = null) -> Dictionary:
	var root := CenterContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.visible = false
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(min_width, 0)
	root.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vb.add_child(head)
	var t := Label.new()
	t.text = title
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	t.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	head.add_child(t)
	if key_hint != "":
		var kh := Label.new()
		kh.text = key_hint
		kh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		kh.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
		kh.add_theme_color_override("font_color", Palette.TEXT_FAINT)
		head.add_child(kh)
	if on_close is Callable and (on_close as Callable).is_valid():
		var x := Button.new()
		x.text = "✕"
		x.focus_mode = Control.FOCUS_NONE
		x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var xsb := StyleBoxEmpty.new()
		x.add_theme_stylebox_override("normal", xsb)
		x.add_theme_stylebox_override("focus", xsb)
		var xh := StyleBoxFlat.new()
		xh.bg_color = Color(Palette.DANGER, 0.25)
		xh.set_corner_radius_all(4)
		xh.set_content_margin_all(2)
		x.add_theme_stylebox_override("hover", xh)
		x.add_theme_stylebox_override("pressed", xh)
		x.add_theme_color_override("font_color", Palette.TEXT_DIM)
		x.add_theme_color_override("font_hover_color", Palette.TEXT_BRIGHT)
		x.pressed.connect(on_close)
		head.add_child(x)
	vb.add_child(HSeparator.new())
	return {"root": root, "panel": pc, "body": vb, "title": t}

# A section header inside a panel body.
static func section(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	l.add_theme_color_override("font_color", Palette.ACCENT2)
	return l

# Dim wrapped helper copy (the "how this works" line under a title).
static func hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	l.add_theme_color_override("font_color", Palette.TEXT_FAINT)
	return l

# A status line (balances, counts) — caller recolors per meaning via Palette.
static func status(color: Color = Palette.TEXT_DIM) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	l.add_theme_color_override("font_color", color)
	return l

# A small rounded chip: colored text on a dark pill with a matching border.
static func chip(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color, 0.13)
	sb.set_border_width_all(1)
	sb.border_color = Color(color, 0.65)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 2.0
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	l.add_theme_color_override("font_color", color.lightened(0.15))
	p.add_child(l)
	p.set_meta("label", l)
	return p

# A horizontal bar: dark track + colored fill. Returns {root, fill, w, h} — set the fill with
# `Widgets.set_bar(bar, frac)` (fill keeps a 1px inset so the track edge always reads).
static func bar(w: float, h: float, color: Color) -> Dictionary:
	var root := Control.new()
	root.custom_minimum_size = Vector2(w, h)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.size = Vector2(w, h)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	var fill := ColorRect.new()
	fill.color = color
	fill.position = Vector2(1, 1)
	fill.size = Vector2(w - 2.0, h - 2.0)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fill)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return {"root": root, "fill": fill, "w": w, "h": h}

static func set_bar(b: Dictionary, frac: float) -> void:
	(b["fill"] as ColorRect).size.x = maxf(0.0, (float(b["w"]) - 2.0) * clampf(frac, 0.0, 1.0))
