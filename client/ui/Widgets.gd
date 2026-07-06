class_name Widgets
extends RefCounted
## UI-overhaul P0 — reusable chrome factories so panels stop re-deriving the same scaffold.
## Each _build_* migrates onto these one at a time (the Practice Vendor is the pattern-proof).

const WIN_CFG := "user://settings.cfg"   # reuse the audio/fx settings file (a [windows] section)

# The standard pop-up scaffold, now a MOVABLE + RESIZABLE window: a full-rect non-blocking root holds a
# floating PanelContainer you drag by its header and resize by a bottom-right grip; position + size persist
# per title. root → PanelContainer → Margin → VBox, with a header (title + key hint + optional ✕) and a rule.
# `on_close` (a Callable) wires the ✕. Returns {root, panel, body, title} — caller adds `root` to the HUD.
static func panel(title: String, key_hint := "", min_width := 560.0, on_close = null) -> Dictionary:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # non-modal: click the game around a floating window
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
	head.mouse_filter = Control.MOUSE_FILTER_STOP     # the drag handle
	head.mouse_default_cursor_shape = Control.CURSOR_MOVE
	vb.add_child(head)
	var t := Label.new()
	t.text = title
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE      # let the drag reach the header
	t.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	t.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	head.add_child(t)
	if key_hint != "":
		var kh := Label.new()
		kh.text = key_hint
		kh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		kh.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_make_window(root, pc, head, title, min_width)
	return {"root": root, "panel": pc, "body": vb, "title": t}

# Wire drag (header) + resize (bottom-right grip) + persistence onto a Widgets panel.
static func _make_window(root: Control, pc: PanelContainer, head: Control, title: String, min_width: float) -> void:
	# resize grip (bottom-right), a sibling of pc kept pinned to the panel's corner by `pin`
	var grip := ColorRect.new()
	grip.color = Color(Palette.BORDER_BRIGHT, 0.5)
	grip.custom_minimum_size = Vector2(16, 16)
	grip.size = Vector2(16, 16)
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.visible = false
	root.add_child(grip)
	var pin := func() -> void:
		grip.position = pc.position + pc.size - grip.size
	pc.resized.connect(pin)                  # content-driven size changes keep the grip aligned
	# drag by the header (a move only changes position → doesn't emit `resized`, so re-pin explicitly)
	var drag := {"on": false, "off": Vector2.ZERO}
	head.gui_input.connect(func(ev) -> void:
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
			if ev.pressed:
				drag["off"] = root.get_local_mouse_position() - pc.position
			else:
				_save_window(title, pc)
		elif ev is InputEventMouseMotion and drag["on"]:
			_place_panel(root, pc, root.get_local_mouse_position() - drag["off"])
			pin.call())
	# resize by the grip
	var rz := {"on": false, "start": Vector2.ZERO, "base": Vector2.ZERO}
	grip.gui_input.connect(func(ev) -> void:
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			rz["on"] = ev.pressed
			if ev.pressed:
				rz["start"] = root.get_local_mouse_position()
				rz["base"] = pc.size
			else:
				_save_window(title, pc)
		elif ev is InputEventMouseMotion and rz["on"]:
			var d: Vector2 = root.get_local_mouse_position() - rz["start"]
			pc.custom_minimum_size = Vector2(maxf(min_width * 0.6, float(rz["base"].x) + d.x), maxf(120.0, float(rz["base"].y) + d.y))
			pin.call())
	# on show: restore (first time), re-clamp, re-pin the grip; hook the viewport resize once we're in-tree
	var placed := {"v": false, "vp": false}
	root.visibility_changed.connect(func() -> void:
		grip.visible = root.visible
		if not root.visible:
			return
		if not placed["v"]:
			placed["v"] = true
			_restore_window(root, pc, title, min_width)
		if not placed["vp"]:                 # re-clamp + re-pin when the game window is resized
			placed["vp"] = true
			var vpn := root.get_viewport()
			if vpn != null:
				vpn.size_changed.connect(func() -> void:
					if root.visible:
						_place_panel(root, pc, pc.position)
						pin.call())
		_place_panel(root, pc, pc.position)  # keep it on-screen
		pin.call())

# clamp a panel top-left so it stays on screen
static func _place_panel(root: Control, pc: Control, p: Vector2) -> void:
	var vp := root.size
	pc.position = Vector2(clampf(p.x, 0.0, maxf(0.0, vp.x - pc.size.x)), clampf(p.y, 0.0, maxf(0.0, vp.y - pc.size.y)))

static func _save_window(title: String, pc: Control) -> void:
	var cfg := ConfigFile.new()
	cfg.load(WIN_CFG)                        # keep the audio/fx sections
	cfg.set_value("windows", title, {"x": pc.position.x, "y": pc.position.y,
		"cw": pc.custom_minimum_size.x, "ch": pc.custom_minimum_size.y})
	cfg.save(WIN_CFG)

static func _restore_window(root: Control, pc: PanelContainer, title: String, min_width: float) -> void:
	pc.reset_size()                          # compute the content-driven size first
	var saved = null
	var cfg := ConfigFile.new()
	if cfg.load(WIN_CFG) == OK and cfg.has_section_key("windows", title):   # has_section_key → no missing-key error
		saved = cfg.get_value("windows", title)
	var vp := root.size
	if saved is Dictionary:
		if float(saved.get("ch", 0.0)) > 1.0:   # the user had resized it
			pc.custom_minimum_size = Vector2(maxf(min_width * 0.6, float(saved.get("cw", min_width))), float(saved["ch"]))
			pc.reset_size()
		_place_panel(root, pc, Vector2(float(saved.get("x", 0.0)), float(saved.get("y", 0.0))))
	else:
		pc.position = Vector2(maxf(0.0, (vp.x - pc.size.x) * 0.5), maxf(0.0, (vp.y - pc.size.y) * 0.5))

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
