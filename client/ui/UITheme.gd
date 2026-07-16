class_name UITheme
extends RefCounted
## UI-overhaul P0 — the single Theme every Control inherits. Built in code (no editor round-trip;
## tweak Palette + relaunch to iterate). The root Window carries it for popups/tooltips, but a
## Window's theme does NOT reach Controls under a CanvasLayer — theme inheritance only walks
## Control/Window ancestors, and a CanvasLayer is neither, so the chain breaks there (both UI
## roots are CanvasLayers: Client._hud and the Account screen). `attach()` below closes that gap
## by assigning the Theme at every chain-break point. Per-panel add_theme_* overrides still win
## where they're semantic (rarity borders, currency colors).

static var _theme: Theme = null

static func get_theme() -> Theme:
	if _theme == null:
		_theme = _build()
	return _theme

# UI-consistency pass: make the Theme actually reach a CanvasLayer's Controls. Assigns the game
# Theme at every inheritance chain-break point (a Control whose parent is NOT a Control — Controls
# under a Control inherit for free). Hooks SceneTree.node_added rather than layer.child_entered_tree
# so Controls that enter later BELOW non-Control wrappers (Node/Node3D) are styled too; the
# assignment is idempotent (one shared Theme resource), so HudLayout's reparenting into HudMod_*
# wrappers re-fires harmlessly. The hook disconnects when the layer leaves the tree — a relogin
# rebuilds the HUD and stale tree-wide connections must not stack.
static func attach(layer: CanvasLayer) -> void:
	var tree := layer.get_tree()
	if tree == null:
		push_warning("UITheme.attach: layer must be inside the tree")
		return
	var on_added := func(n: Node) -> void:
		if n is Control and not (n.get_parent() is Control) and _inside(layer, n):
			(n as Control).theme = get_theme()
	tree.node_added.connect(on_added)
	layer.tree_exiting.connect(func() -> void:
		if tree.node_added.is_connected(on_added):
			tree.node_added.disconnect(on_added))
	for c in layer.get_children():   # anything built before attach (defensive; callers attach first)
		_theme_breaks(c)

# assign the Theme at every chain-break point of an already-built subtree
static func _theme_breaks(n: Node) -> void:
	if n is Control and not (n.get_parent() is Control):
		(n as Control).theme = get_theme()
	for c in n.get_children():
		_theme_breaks(c)

static func _inside(layer: Node, n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p == layer:
			return true
		p = p.get_parent()
	return false

static func _flat(bg: Color, border: Color, border_w: int, radius: int, margin: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(border_w)
	sb.border_color = border
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	return sb

static func _build() -> Theme:
	var t := Theme.new()
	t.default_font_size = Palette.SIZE_BODY

	# panels — the pop-up chrome (PanelContainer) + bare Panel (popups/frames). HUD-config P10:
	# the windows join the pattern language — navy body, cyan-tinted rail, crisper corners.
	var panel := _flat(Palette.BG_PANEL, Color(Palette.SB_CYAN, 0.32), 1, 6, 4)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", _flat(Palette.BG_PANEL, Color(Palette.SB_CYAN, 0.28), 1, 5, 4))

	# buttons — the sports-tech language (navy body + cyan rail; brighter cyan on hover; a
	# cyan-lit press). Clear affordance so buttons read as interactive, not flat grey blocks.
	var b_norm := _flat(Color(Palette.SB_NAVY.lightened(0.05), 0.92), Color(Palette.SB_CYAN, 0.35), 1, 5, 6)
	b_norm.content_margin_left = 13.0
	b_norm.content_margin_right = 13.0
	b_norm.content_margin_top = 5.0
	b_norm.content_margin_bottom = 5.0
	var b_hover := _flat(Color(Palette.SB_NAVY.lightened(0.16), 0.97), Color(Palette.SB_CYAN, 0.75), 1, 5, 6)
	b_hover.content_margin_left = 13.0
	b_hover.content_margin_right = 13.0
	b_hover.content_margin_top = 5.0
	b_hover.content_margin_bottom = 5.0
	var b_press := _flat(Color(0.06, 0.15, 0.21, 0.98), Color(Palette.SB_CYAN, 1.0), 1, 5, 6)
	b_press.content_margin_left = 13.0
	b_press.content_margin_right = 13.0
	b_press.content_margin_top = 5.0
	b_press.content_margin_bottom = 5.0
	var b_off := _flat(Color(Palette.SB_INK, 0.55), Color(Palette.BORDER, 0.3), 1, 5, 6)
	b_off.content_margin_left = 13.0
	b_off.content_margin_right = 13.0
	b_off.content_margin_top = 5.0
	b_off.content_margin_bottom = 5.0
	for cls in ["Button", "OptionButton", "MenuButton"]:   # OptionButton (Settings/editor) shares the language
		t.set_stylebox("normal", cls, b_norm)
		t.set_stylebox("hover", cls, b_hover)
		t.set_stylebox("pressed", cls, b_press)
		t.set_stylebox("disabled", cls, b_off)
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_color("font_color", cls, Palette.TEXT_BRIGHT)
		t.set_color("font_hover_color", cls, Color(1, 1, 1))
		t.set_color("font_pressed_color", cls, Palette.SB_CYAN)
		t.set_color("font_disabled_color", cls, Palette.TEXT_FAINT)
		t.set_color("font_focus_color", cls, Palette.TEXT_BRIGHT)
	t.set_color("font_hover_pressed_color", "OptionButton", Palette.SB_CYAN)

	# checkboxes share the button text language (default check icons; brighter rest text for contrast)
	t.set_color("font_color", "CheckBox", Palette.TEXT_BRIGHT)
	t.set_color("font_hover_color", "CheckBox", Color(1, 1, 1))
	t.set_color("font_pressed_color", "CheckBox", Palette.SB_CYAN)
	t.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckBox", StyleBoxEmpty.new())

	# text
	t.set_color("font_color", "Label", Palette.TEXT)
	t.set_color("default_color", "RichTextLabel", Palette.TEXT)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_stylebox("focus", "RichTextLabel", StyleBoxEmpty.new())

	# inputs — ink well, cyan-tint rail at rest → bright cyan on focus
	var le := _flat(Color(Palette.SB_INK, 0.96), Color(Palette.SB_CYAN, 0.3), 1, 5, 7)
	le.content_margin_left = 11.0
	le.content_margin_right = 11.0
	var le_focus: StyleBoxFlat = le.duplicate()
	le_focus.border_color = Palette.SB_CYAN
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", Palette.TEXT_BRIGHT)
	t.set_color("font_placeholder_color", "LineEdit", Palette.TEXT_DIM)   # was TEXT_FAINT — too dim to read
	t.set_color("caret_color", "LineEdit", Palette.SB_CYAN)
	t.set_stylebox("normal", "TextEdit", le)                              # multi-line inputs match
	t.set_stylebox("focus", "TextEdit", le_focus)
	t.set_color("font_color", "TextEdit", Palette.TEXT_BRIGHT)

	# sliders — dark track, bright SB_CYAN fill + a cyan grabber knob (was soft ACCENT2 + default knob)
	t.set_stylebox("slider", "HSlider", _flat(Color(Palette.SB_INK, 0.95), Color(Palette.SB_CYAN, 0.2), 1, 4, 2))
	t.set_stylebox("grabber_area", "HSlider", _flat(Color(Palette.SB_CYAN, 0.85), Color(0, 0, 0, 0), 0, 4, 2))
	t.set_stylebox("grabber_area_highlight", "HSlider", _flat(Palette.SB_CYAN, Color(0, 0, 0, 0), 0, 4, 2))
	var knob := _dot_icon(Palette.SB_CYAN, 8)               # branded round grabber, not the default texture
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)
	t.set_icon("grabber_disabled", "HSlider", _dot_icon(Palette.TEXT_FAINT, 8))

	# scrollbars — cyan-tinted grabbers (more visible than the old slate) on a near-invisible track
	for sb_type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb_type, _flat(Color(Palette.SB_INK, 0.3), Color(0, 0, 0, 0), 0, 4, 2))
		t.set_stylebox("grabber", sb_type, _flat(Color(Palette.SB_CYAN, 0.4), Color(0, 0, 0, 0), 0, 4, 0))
		t.set_stylebox("grabber_highlight", sb_type, _flat(Color(Palette.SB_CYAN, 0.7), Color(0, 0, 0, 0), 0, 4, 0))
		t.set_stylebox("grabber_pressed", sb_type, _flat(Palette.SB_CYAN, Color(0, 0, 0, 0), 0, 4, 0))

	# right-click context menus + OptionButton dropdowns — navy body, cyan rail, cyan-lit hover
	t.set_stylebox("panel", "PopupMenu", _flat(Palette.BG_PANEL, Color(Palette.SB_CYAN, 0.35), 1, 6, 6))
	t.set_stylebox("hover", "PopupMenu", _flat(Color(Palette.SB_CYAN, 0.18), Color(0, 0, 0, 0), 0, 4, 2))
	t.set_color("font_color", "PopupMenu", Palette.TEXT_BRIGHT)
	t.set_color("font_hover_color", "PopupMenu", Palette.SB_CYAN)
	t.set_color("font_accelerator_color", "PopupMenu", Palette.TEXT_DIM)
	t.set_color("font_separator_color", "PopupMenu", Color(Palette.SB_CYAN, 0.4))

	# separators — P10: the rule under every window title reads as a subtle cyan rail
	var sep := StyleBoxLine.new()
	sep.color = Color(Palette.SB_CYAN, 0.30)
	t.set_stylebox("separator", "HSeparator", sep)
	var vsep := StyleBoxLine.new()
	vsep.color = Color(Palette.SB_CYAN, 0.30)
	vsep.vertical = true
	t.set_stylebox("separator", "VSeparator", vsep)

	# progress bars — bright SB_CYAN fill (was soft ACCENT2)
	t.set_stylebox("background", "ProgressBar", _flat(Color(Palette.SB_INK, 0.55), Color(Palette.SB_CYAN, 0.2), 1, 4, 1))
	t.set_stylebox("fill", "ProgressBar", _flat(Palette.SB_CYAN, Color(0, 0, 0, 0), 0, 4, 1))

	# native hover tooltips — were unstyled (default pale Godot box); now the pattern's ink+cyan
	var tip := _flat(Color(Palette.SB_INK, 0.98), Color(Palette.SB_CYAN, 0.5), 1, 5, 8)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", Palette.TEXT_BRIGHT)

	# CheckBox on/off glyphs in the pattern colors (default was Godot's grey tick)
	t.set_icon("unchecked", "CheckBox", _check_icon(false))
	t.set_icon("checked", "CheckBox", _check_icon(true))

	return t

# a small filled disc texture (slider grabber) — SB_* branded, drawn to an Image
static func _dot_icon(col: Color, d: int) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := d * 0.5
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			if dist <= r:
				img.set_pixel(x, y, Color(col, 1.0) if dist <= r - 1.0 else Color(col, 0.5))
	return ImageTexture.create_from_image(img)

# a 18px checkbox glyph: cyan-railed box, lime fill + tick when checked
static func _check_icon(checked: bool) -> ImageTexture:
	var s := 18
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in s:
		for x in s:
			var edge := x <= 1 or x >= s - 2 or y <= 1 or y >= s - 2
			if edge:
				img.set_pixel(x, y, Color(Palette.SB_CYAN, 0.85 if checked else 0.55))
			elif checked:
				img.set_pixel(x, y, Color(Palette.SB_LIME, 0.22))
	if checked:                                            # a chunky tick
		for i in range(4, 8):
			img.set_pixel(i, i + 4, Color(Palette.SB_LIME, 1.0))
			img.set_pixel(i, i + 5, Color(Palette.SB_LIME, 1.0))
		for i in range(8, 14):
			img.set_pixel(i, 16 - i, Color(Palette.SB_LIME, 1.0))
			img.set_pixel(i, 17 - i, Color(Palette.SB_LIME, 1.0))
	return ImageTexture.create_from_image(img)
