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
	var tf := HudFonts.display_variant(Palette.SIZE_TITLE, 0.06)   # window titles wear the display face
	if tf != null:
		t.add_theme_font_override("font", tf)
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
			var vp := root.size
			var maxw: float = maxf(min_width * 0.6, vp.x - pc.position.x - 6.0)   # keep the bottom-right grip on-screen
			var maxh: float = maxf(120.0, vp.y - pc.position.y - 6.0)
			pc.custom_minimum_size = Vector2(clampf(float(rz["base"].x) + d.x, min_width * 0.6, maxw), clampf(float(rz["base"].y) + d.y, 120.0, maxh))
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
						_clamp_size(root, pc, min_width)
						_place_panel(root, pc, pc.position)
						pin.call())
		_clamp_size(root, pc, min_width)
		_place_panel(root, pc, pc.position)  # keep it on-screen
		pin.call())
	_windows.append({"root": root, "recenter": func() -> void:   # Settings "Reset UI Layout" button
		pc.custom_minimum_size = Vector2(min_width, 0)
		pc.reset_size()
		pc.position = Vector2(maxf(0.0, (root.size.x - pc.size.x) * 0.5), maxf(0.0, (root.size.y - pc.size.y) * 0.5))
		pin.call()})

# clamp a panel top-left so it stays on screen
static func _place_panel(root: Control, pc: Control, p: Vector2) -> void:
	var vp := root.size
	pc.position = Vector2(clampf(p.x, 0.0, maxf(0.0, vp.x - pc.size.x)), clampf(p.y, 0.0, maxf(0.0, vp.y - pc.size.y)))

# cap a user-resized panel so it never exceeds the viewport (else the bottom-right grip goes off-screen)
static func _clamp_size(root: Control, pc: PanelContainer, min_width: float) -> void:
	if pc.custom_minimum_size.y < 1.0:
		return
	var vp := root.size
	pc.custom_minimum_size = Vector2(clampf(pc.custom_minimum_size.x, min_width * 0.6, maxf(min_width * 0.6, vp.x - 12.0)),
		clampf(pc.custom_minimum_size.y, 120.0, maxf(120.0, vp.y - 12.0)))

# static registry of every window (for the reset button); freed roots pruned on reset
static var _windows := []

# Settings "Reset UI Layout": wipe saved positions/sizes + re-center every live window.
static func reset_all_windows() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(WIN_CFG) == OK and cfg.has_section("windows"):
		cfg.erase_section("windows")
		cfg.save(WIN_CFG)
	var keep := []
	for w in _windows:
		if is_instance_valid(w["root"]):
			(w["recenter"] as Callable).call()
			keep.append(w)
	_windows = keep

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

# The display (Sportbound Strike) face is caps-only with LIMITED punctuation (A-Z 0-9 space
# . , : ! ? - _ / + & #). Anything else (parens, ✦, ◈, ·, em-dash, emoji) must NOT use it —
# per client/ui/fonts/FONTS-README.md — so headers with symbols/sentences fall back to the body font.
const _DISPLAY_OK := " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,:!?-_/+&#"
static func display_safe(text: String) -> bool:
	for ch in text.to_upper():
		if not _DISPLAY_OK.contains(ch):
			return false
	return true

# A section header inside a panel body — the display face + cyan when the text is display-safe,
# else the body font (still cyan). Short "READY TO TURN IN" gets the identity; "✦ Daily Bounties
# (resets in 2h)" stays readable in the body font.
static func section(text: String) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	l.add_theme_color_override("font_color", Palette.SB_CYAN)
	if display_safe(text):
		l.text = text.to_upper()
		var f := HudFonts.display_variant(Palette.SIZE_SECTION, 0.16)
		if f != null:
			l.add_theme_font_override("font", f)
	else:
		l.text = text
	return l

# A data-panel tile stylebox: SB_NAVY body + cyan rail (no rarity) OR a rarity border, chamfer-ish
# corners, brighter body + cyan-lit rail on hover. THE one tile look — replaces the three inline
# copies (_rarity_box / _inv_tile / _build_item_tile). `border` null → the plain cyan-rail tile.
static func tile_box(border = null, hover := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SB_NAVY.lightened(0.10 if hover else 0.03), 0.94)
	if border == null:
		sb.set_border_width_all(1)
		sb.border_color = Color(Palette.SB_CYAN, 0.6 if hover else 0.32)
	else:
		sb.set_border_width_all(2)
		sb.border_color = (border as Color).lightened(0.15) if hover else border
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(7)
	return sb

# A segmented-control toggle button: ACTIVE = filled cyan pill + bright text; inactive = flat text.
# Fixes the sort/filter/mode toggles that only signalled state by font color.
static func toggle_btn(text: String, active: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SB_CYAN, 0.20) if active else Color(0, 0, 0, 0)
	sb.set_border_width_all(1)
	sb.border_color = Color(Palette.SB_CYAN, 0.8) if active else Color(Palette.SB_CYAN, 0.12)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 9.0
	sb.content_margin_right = 9.0
	sb.content_margin_top = 3.0
	sb.content_margin_bottom = 3.0
	var hv: StyleBoxFlat = sb.duplicate()
	hv.bg_color = Color(Palette.SB_CYAN, 0.28 if active else 0.10)
	for st in ["normal", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, sb)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_color_override("font_color", Palette.SB_CYAN if active else Palette.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", Palette.TEXT_BRIGHT)
	b.add_theme_color_override("font_pressed_color", Palette.SB_CYAN if active else Palette.TEXT_DIM)
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b

# A tab row: buttons whose SELECTED one shows a cyan pill. Returns {root, buttons, select} —
# call select(i) to re-highlight after a switch. Fixes "which tab am I on?" (leaderboards etc.).
static func tab_row(labels: Array, on_select: Callable) -> Dictionary:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 4)
	var btns := []
	var state := {"sel": 0}
	var restyle := func() -> void:
		for i in btns.size():
			_style_tab(btns[i], i == int(state["sel"]))
	for i in labels.size():
		var b := Button.new()
		b.text = str(labels[i])
		b.focus_mode = Control.FOCUS_NONE
		var idx := i
		b.pressed.connect(func() -> void:
			state["sel"] = idx
			restyle.call()
			if on_select.is_valid():
				on_select.call(idx))
		btns.append(b)
		hb.add_child(b)
	restyle.call()
	return {"root": hb, "buttons": btns, "select": func(i: int) -> void:
		state["sel"] = i
		restyle.call()}

static func _style_tab(b: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SB_CYAN, 0.16) if active else Color(Palette.SB_NAVY, 0.5)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 11.0
	sb.content_margin_right = 11.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	sb.border_width_bottom = 2 if active else 0        # cyan underline on the active tab
	sb.border_color = Palette.SB_CYAN
	for st in ["normal", "pressed", "hover", "focus"]:
		b.add_theme_stylebox_override(st, sb if st != "hover" else _tab_hover(active))
	b.add_theme_color_override("font_color", Palette.TEXT_BRIGHT if active else Palette.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", Palette.TEXT_BRIGHT)
	b.add_theme_color_override("font_pressed_color", Palette.TEXT_BRIGHT)

static func _tab_hover(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.SB_CYAN, 0.22 if active else 0.09)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 11.0
	sb.content_margin_right = 11.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	sb.border_width_bottom = 2 if active else 0
	sb.border_color = Palette.SB_CYAN
	return sb

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
