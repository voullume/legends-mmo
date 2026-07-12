extends SceneTree
## HUD pattern P1 gallery — renders the three frame tiers with live test content (short/long
## titles, timer, progress bars, two-line body, button row, icon/value rows) across the scale
## matrix (60–160%) on dark AND bright backgrounds, saving one PNG per page.
##
## Run WINDOWED (needs a rendered viewport, uses the project's 1600×900 canvas):
##   godot --path . --script res://tools/hud_gallery.gd -- --out /tmp/hud_gallery

const PaletteS := preload("res://client/ui/Palette.gd")
const HudFrameS := preload("res://client/ui/HudFrame.gd")
const HudFontsS := preload("res://client/ui/HudFonts.gd")
const UIThemeS := preload("res://client/ui/UITheme.gd")

var out_dir := "/tmp/hud_gallery"
var _stage: Control = null

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	root.theme = UIThemeS.get_theme()
	_run()

func _run() -> void:
	await process_frame
	await _page_hero(true)
	await _page_hero(false)
	await _page_panels(true)
	await _page_panels(false)
	await _page_scales()
	await _page_stretch()
	print("[gallery] pages saved to %s" % out_dir)
	quit(0)

# ---------------------------------------------------------------- plumbing

func _fresh_stage(dark: bool) -> Control:
	if _stage != null:
		_stage.queue_free()
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_stage)
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.028, 0.05) if dark else Color(0.78, 0.82, 0.76)
	_stage.add_child(bg)
	if not dark:
		# harsh bright stripe — worst case for rail legibility
		var stripe := ColorRect.new()
		stripe.color = Color(0.95, 0.95, 0.9)
		stripe.position = Vector2(0, 300)
		stripe.size = Vector2(1600, 300)
		_stage.add_child(stripe)
	return _stage

func _shot(name: String) -> void:
	await process_frame
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	img.save_png(out_dir + "/" + name + ".png")
	print("[gallery] %s.png" % name)

func _place(f: Control, pos: Vector2, sz: Vector2) -> void:
	f.position = pos
	f.size = sz
	_stage.add_child(f)

func _caption(text: String, pos: Vector2) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
	_stage.add_child(l)

# ---------------------------------------------------------------- content helpers

func _bar(w: float, h: float, frac: float, col: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.size = Vector2(w, h)
	c.add_child(bg)
	var fill := ColorRect.new()
	fill.color = col
	fill.position = Vector2(1, 1)
	fill.size = Vector2((w - 2.0) * frac, h - 2.0)
	c.add_child(fill)
	return c

func _body_label(text: String, sz: int = 13, wrap: bool = true) -> Label:
	var l := Label.new()
	l.text = text
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", PaletteS.TEXT)
	return l

func _kv_row(k: String, v: String, vcol: Color) -> HBoxContainer:
	var hb := HBoxContainer.new()
	var kl := Label.new()
	kl.text = k
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kl.add_theme_font_size_override("font_size", 13)
	kl.add_theme_color_override("font_color", PaletteS.TEXT_DIM)
	var vl := Label.new()
	vl.text = v
	vl.add_theme_font_size_override("font_size", 13)
	vl.add_theme_color_override("font_color", vcol)
	hb.add_child(kl)
	hb.add_child(vl)
	return hb

# ---------------------------------------------------------------- pages

func _hero_banner(sz: Vector2, status: String, title: String, timer: String, footer: String) -> Control:
	var boxed: Dictionary = HudFrameS.boxed(HudFrameS.Tier.HERO)
	var f: Control = boxed["frame"]
	f.size = sz
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	(boxed["body"] as MarginContainer).add_child(cc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	cc.add_child(vb)
	var k := clampf(sz.y / 260.0, 0.45, 1.0)
	var safe_w := sz.x - 2.0 * clampf(sz.x * 0.125, 42.0, 120.0) - 8.0
	if status != "":
		vb.add_child(HudFontsS.display_label(status, int(20.0 * k), PaletteS.SB_LIME, 0.28, PaletteS.SB_LIME, safe_w))
	vb.add_child(HudFontsS.display_label(title, int(30.0 * k), PaletteS.TEXT_BRIGHT, 0.22, Color(0, 0, 0, 0), safe_w))
	if timer != "":
		vb.add_child(HudFontsS.display_label(timer, int(56.0 * k), PaletteS.SB_LIME, 0.08, PaletteS.SB_LIME, safe_w))
	if footer != "":
		vb.add_child(HudFontsS.display_label(footer, int(15.0 * k), Color("#CFEFFF"), 0.26, Color(0, 0, 0, 0), safe_w))
	return f

func _page_hero(dark: bool) -> void:
	_fresh_stage(dark)
	var f1 := _hero_banner(Vector2(960, 260), "Match Found", "Arena: Skydome", "00:18", "Prepare to Compete")
	_place(f1, Vector2(320, 60), Vector2(960, 260))
	_caption("HERO 960×260 (reference composition)", Vector2(320, 40))
	var f2 := _hero_banner(Vector2(640, 170), "", "Head Coach Prime Awakens In The Glitchyard", "", "Boss Event")
	_place(f2, Vector2(120, 420), Vector2(640, 170))
	_caption("HERO 640×170 — long title", Vector2(120, 400))
	var f3 := _hero_banner(Vector2(360, 120), "", "Victory", "", "")
	_place(f3, Vector2(880, 440), Vector2(360, 120))
	_caption("HERO 360×120 — minimum size", Vector2(880, 420))
	var f4 := _hero_banner(Vector2(520, 150), "Zone", "The Glitchyard", "", "PvP Enabled")
	f4.accent3 = PaletteS.DANGER
	_place(f4, Vector2(120, 660), Vector2(520, 150))
	_caption("HERO 520×150 — zone card", Vector2(120, 640))
	var f5 := _hero_banner(Vector2(500, 150), "Camp Circuit", "Intensity IV", "02:00", "")
	_place(f5, Vector2(760, 660), Vector2(500, 150))
	_caption("HERO 500×150 — drill start", Vector2(760, 640))
	await _shot("hero_%s" % ("dark" if dark else "bright"))

func _panel_player(sz: Vector2) -> Control:
	var boxed: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {"header": true})
	var f: Control = boxed["frame"]
	f.size = sz
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	(boxed["body"] as MarginContainer).add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var lv := Label.new()
	lv.text = "17"
	lv.add_theme_font_size_override("font_size", 18)
	lv.add_theme_color_override("font_color", PaletteS.ACCENT)
	head.add_child(lv)
	var nm := Label.new()
	nm.text = "Voullume"
	nm.add_theme_font_size_override("font_size", 16)
	nm.add_theme_color_override("font_color", PaletteS.TEXT_BRIGHT)
	head.add_child(nm)
	var cls := Label.new()
	cls.text = "SLUGGER"
	cls.add_theme_font_size_override("font_size", 11)
	cls.add_theme_color_override("font_color", PaletteS.TEXT_DIM)
	cls.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(cls)
	vb.add_child(head)
	vb.add_child(_bar(sz.x - 28.0, 18.0, 0.72, PaletteS.HP))
	vb.add_child(_bar(sz.x - 28.0, 5.0, 0.4, PaletteS.SHIELD))
	vb.add_child(_bar(sz.x * 0.66, 7.0, 0.55, PaletteS.XP))
	return f

func _page_panels(dark: bool) -> void:
	_fresh_stage(dark)
	# player-frame-ish panel
	_place(_panel_player(Vector2(300, 130)), Vector2(60, 60), Vector2(300, 130))
	_caption("PANEL 300×130 — player frame w/ header tab", Vector2(60, 40))
	# quest-tracker-ish tall panel
	var q: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {"header": true, "accent2": PaletteS.SB_LIME})
	var qv := VBoxContainer.new()
	qv.add_theme_constant_override("separation", 3)
	(q["body"] as MarginContainer).add_child(qv)
	var qt := HudFontsS.display_label("Quests", 14, PaletteS.SB_CYAN, 0.2)
	qt.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	qv.add_child(qt)
	qv.add_child(_body_label("• Rookie Ribbons 2/5"))
	qv.add_child(_body_label("• Clear the Sideline Camp 0/1"))
	var done := _body_label("✓ Meet the Head Coach (ready)")
	done.add_theme_color_override("font_color", PaletteS.XP)
	qv.add_child(done)
	qv.add_child(_body_label("A longer two-line quest description wraps inside the safe area without touching the rails.", 12))
	_place(q["frame"], Vector2(420, 60), Vector2(280, 190))
	_caption("PANEL 280×190 — quest tracker", Vector2(420, 40))
	# target-frame-ish with buttons
	var t: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {"header": true, "accent3": PaletteS.DANGER})
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 4)
	(t["body"] as MarginContainer).add_child(tv)
	var tt := HudFontsS.display_label("Training Dummy", 14, PaletteS.TEXT_BRIGHT, 0.14)
	tt.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	tv.add_child(tt)
	tv.add_child(_bar(240.0, 14.0, 1.0, PaletteS.HP))
	tv.add_child(_kv_row("TYPE", "TRAINING UNIT", PaletteS.TEXT))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for btxt in ["Engage", "Inspect", "Ignore"]:
		var b := Button.new()
		b.text = btxt
		row.add_child(b)
	tv.add_child(row)
	_place(t["frame"], Vector2(780, 60), Vector2(290, 160))
	_caption("PANEL 290×160 — target + button row", Vector2(780, 40))
	# meter-ish compact
	var m: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {})
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 2)
	(m["body"] as MarginContainer).add_child(mv)
	mv.add_child(_kv_row("Voullume", "1,204", PaletteS.SB_CYAN))
	mv.add_child(_kv_row("Blitz-7", "981", PaletteS.TEXT))
	mv.add_child(_kv_row("Coach-AI", "610", PaletteS.TEXT))
	_place(m["frame"], Vector2(1160, 60), Vector2(230, 110))
	_caption("PANEL 230×110 — meter rows (no header)", Vector2(1160, 40))
	# utility: tooltip
	var u: Dictionary = HudFrameS.boxed(HudFrameS.Tier.UTILITY, {})
	var uv := VBoxContainer.new()
	(u["body"] as MarginContainer).add_child(uv)
	uv.add_child(_body_label("Shoulder Check — 12s cooldown", 13))
	uv.add_child(_body_label("Deals 180% weapon damage and staggers the target.", 12))
	_place(u["frame"], Vector2(60, 330), Vector2(300, 84))
	_caption("UTILITY 300×84 — tooltip", Vector2(60, 310))
	# utility: interaction prompt w/ stripe + keycap
	var p: Dictionary = HudFrameS.boxed(HudFrameS.Tier.UTILITY, {"stripe": true, "accent": PaletteS.SB_LIME})
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 8)
	(p["body"] as MarginContainer).add_child(ph)
	var keycap := Label.new()
	keycap.text = "[ F ]"
	keycap.add_theme_font_size_override("font_size", 15)
	keycap.add_theme_color_override("font_color", PaletteS.SB_LIME)
	ph.add_child(keycap)
	ph.add_child(_body_label("Forge — upgrade and reforge gear", 14, false))
	_place(p["frame"], Vector2(420, 330), Vector2(320, 42))
	_caption("UTILITY 320×42 — interaction prompt", Vector2(420, 310))
	# utility: confirm w/ buttons
	var cfd: Dictionary = HudFrameS.boxed(HudFrameS.Tier.UTILITY, {"stripe": true, "accent": PaletteS.SB_ORANGE})
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 6)
	(cfd["body"] as MarginContainer).add_child(cv)
	cv.add_child(_body_label("Sell 4 items for ◈ 1,240?", 14))
	var cr := HBoxContainer.new()
	cr.add_theme_constant_override("separation", 6)
	for btxt in ["Confirm", "Cancel"]:
		var b2 := Button.new()
		b2.text = btxt
		cr.add_child(b2)
	cv.add_child(cr)
	_place(cfd["frame"], Vector2(800, 330), Vector2(280, 96))
	_caption("UTILITY 280×96 — confirm", Vector2(800, 310))
	await _shot("panels_%s" % ("dark" if dark else "bright"))

func _page_scales() -> void:
	_fresh_stage(true)
	var scales := [0.6, 0.75, 1.0, 1.25, 1.5, 1.6]
	var x := 30.0
	for s in scales:
		var f := _hero_banner(Vector2(420, 120), "Boss Event", "Head Coach", "", "")
		var wrapper := Control.new()
		wrapper.position = Vector2(x, 40)
		wrapper.scale = Vector2(s, s)
		_stage.add_child(wrapper)
		f.size = Vector2(420, 120)
		wrapper.add_child(f)
		_caption("%d%%" % int(s * 100.0), Vector2(x, 20))
		if s <= 0.75:
			x += 420.0 * s + 24.0
		elif s == 1.0:
			x = 30.0
		if s >= 1.0:
			break
	# second row: remaining scales of the PANEL tier (heroes get huge; panels matter for modules)
	var y := 260.0
	x = 30.0
	for s in scales:
		var pf := _panel_player(Vector2(300, 130))
		var wrapper2 := Control.new()
		wrapper2.position = Vector2(x, y)
		wrapper2.scale = Vector2(s, s)
		_stage.add_child(wrapper2)
		pf.size = Vector2(300, 130)
		wrapper2.add_child(pf)
		_caption("PANEL %d%%" % int(s * 100.0), Vector2(x, y - 20.0))
		x += 300.0 * s + 26.0
	# third row: utility prompt at the matrix extremes
	y = 560.0
	x = 30.0
	for s in scales:
		var u: Dictionary = HudFrameS.boxed(HudFrameS.Tier.UTILITY, {"stripe": true, "accent": PaletteS.SB_LIME})
		var uh := HBoxContainer.new()
		uh.add_theme_constant_override("separation", 8)
		(u["body"] as MarginContainer).add_child(uh)
		var kc := Label.new()
		kc.text = "[ E ]"
		kc.add_theme_color_override("font_color", PaletteS.SB_LIME)
		uh.add_child(kc)
		var bl := _body_label("Talk to the Quest Giver", 14, false)
		uh.add_child(bl)
		var wrapper3 := Control.new()
		wrapper3.position = Vector2(x, y)
		wrapper3.scale = Vector2(s, s)
		_stage.add_child(wrapper3)
		var uf: Control = u["frame"]
		uf.size = Vector2(260, 40)
		wrapper3.add_child(uf)
		_caption("UTIL %d%%" % int(s * 100.0), Vector2(x, y - 20.0))
		x += 260.0 * s + 26.0
	await _shot("scales_dark")

func _page_stretch() -> void:
	_fresh_stage(true)
	var combos := [Vector2(360, 120), Vector2(700, 190), Vector2(1500, 230)]
	var y := 40.0
	for sz in combos:
		var f := _hero_banner(sz, "Instance Ready", "Camp Circuit", "", "")
		_place(f, Vector2(50, y), sz)
		_caption("HERO %dx%d" % [int(sz.x), int(sz.y)], Vector2(50, y - 18.0))
		y += sz.y + 34.0
	# extreme panel aspect ratios
	var wide: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {"header": true})
	(wide["body"] as MarginContainer).add_child(_bar(430.0, 12.0, 0.6, PaletteS.HP))
	_place(wide["frame"], Vector2(1080, 640), Vector2(470, 60))
	_caption("PANEL 470×60", Vector2(1080, 620))
	var tall: Dictionary = HudFrameS.boxed(HudFrameS.Tier.PANEL, {})
	var tv := VBoxContainer.new()
	(tall["body"] as MarginContainer).add_child(tv)
	for i in 6:
		tv.add_child(_kv_row("Row %d" % (i + 1), str(100 - i * 12), PaletteS.TEXT))
	_place(tall["frame"], Vector2(1080, 200), Vector2(170, 300))
	_caption("PANEL 170×300", Vector2(1080, 180))
	await _shot("stretch_dark")
