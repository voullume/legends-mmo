class_name UITheme
extends RefCounted
## UI-overhaul P0 — the single Theme every Control inherits. Built in code (no editor round-trip;
## tweak Palette + relaunch to iterate) and set ONCE on the root Window: a CanvasLayer isn't a
## Control, so `_hud.theme` doesn't exist — the Window's theme is what propagates to every Control
## under it (all _hud panels, the Account screen, popups). Per-panel add_theme_* overrides still
## win where they're semantic (rarity borders, currency colors).

static var _theme: Theme = null

static func get_theme() -> Theme:
	if _theme == null:
		_theme = _build()
	return _theme

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

	# buttons — rest / hover / pressed / disabled states (the "free juice" every panel inherits)
	var b_norm := _flat(Palette.BG_INSET, Palette.BORDER, 1, 6, 6)
	b_norm.content_margin_left = 12.0
	b_norm.content_margin_right = 12.0
	var b_hover := _flat(Palette.BG_HOVER, Palette.BORDER_BRIGHT, 1, 6, 6)
	b_hover.content_margin_left = 12.0
	b_hover.content_margin_right = 12.0
	var b_press := _flat(Palette.BG_PRESSED, Palette.ACCENT, 1, 6, 6)
	b_press.content_margin_left = 12.0
	b_press.content_margin_right = 12.0
	var b_off := _flat(Color(Palette.BG_INSET, 0.5), Color(Palette.BORDER, 0.4), 1, 6, 6)
	b_off.content_margin_left = 12.0
	b_off.content_margin_right = 12.0
	t.set_stylebox("normal", "Button", b_norm)
	t.set_stylebox("hover", "Button", b_hover)
	t.set_stylebox("pressed", "Button", b_press)
	t.set_stylebox("disabled", "Button", b_off)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Palette.TEXT)
	t.set_color("font_hover_color", "Button", Palette.TEXT_BRIGHT)
	t.set_color("font_pressed_color", "Button", Palette.ACCENT)
	t.set_color("font_disabled_color", "Button", Palette.TEXT_FAINT)
	t.set_color("font_focus_color", "Button", Palette.TEXT)

	# checkboxes share the button text language
	t.set_color("font_color", "CheckBox", Palette.TEXT)
	t.set_color("font_hover_color", "CheckBox", Palette.TEXT_BRIGHT)
	t.set_color("font_pressed_color", "CheckBox", Palette.TEXT)
	t.set_stylebox("normal", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("hover", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("pressed", "CheckBox", StyleBoxEmpty.new())
	t.set_stylebox("focus", "CheckBox", StyleBoxEmpty.new())

	# text
	t.set_color("font_color", "Label", Palette.TEXT)
	t.set_color("default_color", "RichTextLabel", Palette.TEXT)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	t.set_stylebox("focus", "RichTextLabel", StyleBoxEmpty.new())

	# inputs
	var le := _flat(Color(0.045, 0.058, 0.085, 0.96), Palette.BORDER, 1, 6, 6)
	le.content_margin_left = 10.0
	le.content_margin_right = 10.0
	var le_focus: StyleBoxFlat = le.duplicate()
	le_focus.border_color = Palette.ACCENT2
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", Palette.TEXT_BRIGHT)
	t.set_color("font_placeholder_color", "LineEdit", Palette.TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", Palette.ACCENT2)

	# sliders (settings volumes) — slim dark track, accent fill
	t.set_stylebox("slider", "HSlider", _flat(Color(0.04, 0.05, 0.075, 0.95), Palette.BORDER, 1, 4, 2))
	t.set_stylebox("grabber_area", "HSlider", _flat(Color(Palette.ACCENT2, 0.75), Color(0, 0, 0, 0), 0, 4, 2))
	t.set_stylebox("grabber_area_highlight", "HSlider", _flat(Palette.ACCENT2, Color(0, 0, 0, 0), 0, 4, 2))

	# scrollbars — slim slate grabbers on a near-invisible track
	for sb_type in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb_type, _flat(Color(0, 0, 0, 0.25), Color(0, 0, 0, 0), 0, 4, 2))
		t.set_stylebox("grabber", sb_type, _flat(Color(0.32, 0.38, 0.48, 0.7), Color(0, 0, 0, 0), 0, 4, 0))
		t.set_stylebox("grabber_highlight", sb_type, _flat(Color(0.42, 0.49, 0.60, 0.9), Color(0, 0, 0, 0), 0, 4, 0))
		t.set_stylebox("grabber_pressed", sb_type, _flat(Palette.ACCENT2, Color(0, 0, 0, 0), 0, 4, 0))

	# right-click context menus
	t.set_stylebox("panel", "PopupMenu", _flat(Palette.BG, Palette.BORDER_BRIGHT, 1, 6, 6))
	t.set_stylebox("hover", "PopupMenu", _flat(Palette.BG_HOVER, Color(0, 0, 0, 0), 0, 4, 2))
	t.set_color("font_color", "PopupMenu", Palette.TEXT)
	t.set_color("font_hover_color", "PopupMenu", Palette.TEXT_BRIGHT)

	# separators — P10: the rule under every window title reads as a subtle cyan rail
	var sep := StyleBoxLine.new()
	sep.color = Color(Palette.SB_CYAN, 0.30)
	t.set_stylebox("separator", "HSeparator", sep)
	var vsep := StyleBoxLine.new()
	vsep.color = Color(Palette.SB_CYAN, 0.30)
	vsep.vertical = true
	t.set_stylebox("separator", "VSeparator", vsep)

	# progress bars (future HUD bars can lean on these defaults)
	t.set_stylebox("background", "ProgressBar", _flat(Color(0, 0, 0, 0.55), Palette.BORDER, 1, 4, 1))
	t.set_stylebox("fill", "ProgressBar", _flat(Palette.ACCENT2, Color(0, 0, 0, 0), 0, 4, 1))

	return t
