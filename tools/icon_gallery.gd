extends SceneTree
## Permanent Hybrid-Cutout UI icon system — BEFORE/AFTER visual gallery (icon-integration handoff §15).
## Renders the acceptance-matrix scenarios with the REAL production components (IconRegistry / IconWidget
## / Widgets / StatusRow) on the game theme, plus a reconstruction of the pre-pass emoji/two-letter UI
## for comparison, and saves PNGs at 1920×1080 and a smaller supported size (1280×720).
##
## Renders into an exact-size offscreen SubViewport (so the captured image is pixel-exact regardless of
## the host window chrome). Run WINDOWED (needs a real GPU viewport — do NOT pass --headless):
##   ~/.local/bin/godot --path . --script res://tools/icon_gallery.gd -- --out <dir>

const PaletteS := preload("res://client/ui/Palette.gd")
const UIThemeS := preload("res://client/ui/UITheme.gd")
const HudFontsS := preload("res://client/ui/HudFonts.gd")
const WidgetsS := preload("res://client/ui/Widgets.gd")
const IconRegS := preload("res://client/ui/IconRegistry.gd")
const IconWidS := preload("res://client/ui/IconWidget.gd")
const StatusRowS := preload("res://client/ui/StatusRow.gd")

var out_dir := "/home/e/legends-mmo/docs/ui-pass-after-shots"
var _theme: Theme = null
var _sv: SubViewport = null
var _stage: Control = null

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	_theme = UIThemeS.get_theme()
	_run()

func _run() -> void:
	await process_frame
	for sz in [Vector2i(1920, 1080), Vector2i(1280, 720)]:
		var tag := "%dx%d" % [sz.x, sz.y]
		await _page_after(sz, tag)
		await _page_before(sz, tag)
	print("[icon_gallery] saved to %s" % out_dir)
	quit(0)

# ---------------------------------------------------------------- plumbing
func _fresh_stage(sz: Vector2i) -> Control:
	if _sv != null:
		_sv.queue_free()
	_sv = SubViewport.new()
	_sv.size = sz
	_sv.transparent_bg = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_sv)
	_stage = Control.new()
	_stage.theme = _theme
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.size = Vector2(sz)
	_sv.add_child(_stage)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.028, 0.05)          # the game's dark chrome ground
	_stage.add_child(bg)
	return _stage

func _shot(name: String) -> void:
	for _n in 4:
		await process_frame
	var img := _sv.get_texture().get_image()
	img.save_png(out_dir + "/" + name + ".png")
	print("[icon_gallery] %s.png (%dx%d)" % [name, img.get_width(), img.get_height()])

func _title(text: String, pos: Vector2, col: Color = PaletteS.SB_CYAN, size := 15) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	_stage.add_child(l)

func _cap(text: String, pos: Vector2) -> void:
	_title(text, pos, PaletteS.TEXT_DIM, 12)

# a faithful reconstruction of a Widgets.panel header: chromed PanelContainer + [icon · branded title ·
# key hint · ✕]. Mirrors panel()'s icon insertion + display-safe uppercase title policy (no drag/resize
# machinery — that behaviour is pinned by window_chrome_test; this is only for the visual).
func _header_preview(title: String, icon_id: String, key_hint: String, width: float) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(width, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PaletteS.SB_NAVY, 0.98)
	sb.set_border_width_all(1)
	sb.border_width_top = 3                          # cyan marquee rail
	sb.border_color = PaletteS.SB_CYAN
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	pc.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vb.add_child(head)
	if icon_id != "":
		head.add_child(IconWidS.make(icon_id, {"px": 24, "color": PaletteS.SB_CYAN}))
	var t := Label.new()
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if WidgetsS.display_safe(title):
		t.text = title.to_upper()
		var tf := HudFontsS.display_variant(PaletteS.SIZE_TITLE, 0.06)
		if tf != null:
			t.add_theme_font_override("font", tf)
	else:
		t.text = title
	t.add_theme_font_size_override("font_size", PaletteS.SIZE_TITLE)
	t.add_theme_color_override("font_color", PaletteS.TEXT_BRIGHT)
	head.add_child(t)
	if key_hint != "":
		var kh := Label.new()
		kh.text = key_hint
		kh.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		kh.add_theme_font_size_override("font_size", PaletteS.SIZE_CAPTION)
		kh.add_theme_color_override("font_color", PaletteS.TEXT_FAINT)
		head.add_child(kh)
	var x := Label.new()
	x.text = "✕"
	x.add_theme_color_override("font_color", PaletteS.TEXT_DIM)
	head.add_child(x)
	vb.add_child(HSeparator.new())
	var body := Label.new()
	body.text = "window body — %s" % title
	body.add_theme_font_size_override("font_size", 12)
	body.add_theme_color_override("font_color", PaletteS.TEXT_DIM)
	vb.add_child(body)
	return pc

# ---------------------------------------------------------------- AFTER page (new icon system)
func _page_after(sz: Vector2i, tag: String) -> void:
	_fresh_stage(sz)
	_title("HYBRID CUTOUT UI ICONS — AFTER   ·   %s" % tag, Vector2(40, 18), PaletteS.SB_CYAN, 20)

	# ---- window headers (icon-bearing + one icon-free) ----
	_title("WINDOW HEADERS  (icon-bearing · branded title · key hint · ✕)", Vector2(40, 56))
	var headers := [
		["Inventory", "inventory", "I / Esc"],
		["Forge", "forge", "F / Esc"],
		["Practice Vendor", "practice_vendor", "V / Esc"],
		["Camp Circuit", "camp_circuit", "C / Esc"],
		["Leaderboards", "leaderboards", "L / Esc"],
		["Plain Window (icon-free)", "", "Esc"],
	]
	var hy := 82.0
	for h in headers:
		var hp := _header_preview(str(h[0]), str(h[1]), str(h[2]), 380.0)
		hp.position = Vector2(40, hy)
		_stage.add_child(hp)
		hy += 92.0

	# ---- status rows ----
	var sx := 470.0
	_title("STATUS ROWS  (self / target / party · amount badges · duration bars · overflow · MS haste↔self-slow)", Vector2(sx, 56))
	var rows := [
		{"lbl": "Self 22px cap6 — shield/guard/burn amounts, MS haste (lime)", "px": 22, "cap": 6, "st": {"sh": [340, 55], "gd": [2, 30], "dot": [3, 42], "dr": [25, 60], "ms": [128, 40], "nx": 170}},
		{"lbl": "Target 18px — stun/slow/barrier/crit/attack-speed", "px": 18, "cap": 5, "st": {"stn": 12, "slw": [18, 40], "ba": [70, 50], "cr": [30, 35], "as": [132, 28]}},
		{"lbl": "Party 14px (hardest) — MS self-slow (orange) + overflow", "px": 14, "cap": 5, "st": {"ms": [80, 25], "by": 25, "rf": 20, "ev": 30, "ut": 22, "sh": [90, 40]}},
		{"lbl": "Overflow (+n) at cap 4", "px": 18, "cap": 4, "st": {"stn": 10, "dot": [2, 30], "sh": [120, 40], "dr": [25, 50], "gd": [1, 20], "ms": [130, 30]}},
	]
	# StatusRow is a Container — it must live inside a Container to lay out (as it does in every game
	# frame). Wrap caption + row pairs in a VBox so the chips space + size exactly like in play.
	var svb := VBoxContainer.new()
	svb.add_theme_constant_override("separation", 8)
	svb.position = Vector2(sx, 88.0)
	svb.custom_minimum_size = Vector2(740, 0)
	_stage.add_child(svb)
	for r in rows:
		var cap := Label.new()
		cap.text = str(r["lbl"])
		cap.add_theme_font_size_override("font_size", 12)
		cap.add_theme_color_override("font_color", PaletteS.TEXT_DIM)
		svb.add_child(cap)
		var row = StatusRowS.new()
		row.chip_px = int(r["px"])
		row.cap = int(r["cap"])
		svb.add_child(row)
		row.drive(r["st"], "gallery")             # StatusRow.decode ignores any key not in DEFS
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(0, 8)
		svb.add_child(pad)
	var ry := 88.0 + float(rows.size()) * 66.0

	# ---- buttons (states) ----
	_title("BUTTONS  (normal · disabled · destructive · selected)", Vector2(sx, ry + 4.0))
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 12)
	brow.position = Vector2(sx, ry + 28.0)
	_stage.add_child(brow)
	brow.add_child(IconWidS.icon_button("power_action", "Equip Best", PaletteS.ACCENT, Callable()))
	var dis := IconWidS.icon_button("attunement_key", "Forge Master Key", PaletteS.TEXT_BRIGHT, Callable(), {"disabled": true})
	brow.add_child(dis)
	brow.add_child(IconWidS.icon_button("delete", "Delete (Y)", PaletteS.DANGER, Callable()))
	brow.add_child(WidgetsS.toggle_btn("Rarity", true, Callable()))
	var brow2 := HBoxContainer.new()
	brow2.add_theme_constant_override("separation", 12)
	brow2.position = Vector2(sx, ry + 62.0)
	_stage.add_child(brow2)
	brow2.add_child(IconWidS.icon_button("credits", "Roll Epic  240", Color.html("#c77dff"), Callable(), {"icon_color": PaletteS.CREDITS}))
	brow2.add_child(IconWidS.icon_button("party", "Invite", PaletteS.ACCENT2, Callable()))
	brow2.add_child(IconWidS.icon_button("playbook_pages", "Audible  12", PaletteS.TEXT_BRIGHT, Callable(), {"icon_color": PaletteS.LAVENDER}))

	# ---- currency tray + reward rows ----
	var cyy := ry + 100.0
	_title("CURRENCY TRAY + REWARD ROWS  (structural icon + numeric label)", Vector2(sx, cyy))
	var tray := HBoxContainer.new()
	tray.add_theme_constant_override("separation", 18)
	tray.position = Vector2(sx, cyy + 22.0)
	_stage.add_child(tray)
	tray.add_child(IconWidS.row("credits", "1,240", {"px": 16, "color": PaletteS.CREDITS}))
	tray.add_child(IconWidS.row("scrap", "36", {"px": 16, "color": PaletteS.SCRAP}))
	tray.add_child(IconWidS.row("tokens", "12", {"px": 16, "color": PaletteS.TOKENS}))
	tray.add_child(IconWidS.row("item_power", "Item Power 75", {"px": 16, "color": PaletteS.ACCENT}))
	tray.add_child(IconWidS.row("playbook_pages", "8 / 10", {"px": 16, "color": PaletteS.LAVENDER}))

	# ---- capacity warnings ----
	var wy := cyy + 56.0
	_title("CAPACITY WARNINGS  (nearly-full = Warning · full = Inventory-Full X)", Vector2(sx, wy))
	var warn_near := IconWidS.row("warning", "BAG NEARLY FULL  ·  46 / 50", {"px": 22, "color": PaletteS.SB_ORANGE, "text_color": PaletteS.SB_ORANGE, "font_size": 18})
	warn_near.position = Vector2(sx, wy + 22.0)
	_stage.add_child(warn_near)
	var warn_full := IconWidS.row("inventory_full", "INVENTORY FULL  ·  50 / 50", {"px": 22, "color": PaletteS.DANGER, "text_color": PaletteS.DANGER, "font_size": 18})
	warn_full.position = Vector2(sx, wy + 52.0)
	_stage.add_child(warn_full)

	# ---- toasts ----
	var tx := 1230.0
	_title("TOASTS  (icon is a SIBLING of the RichTextLabel, never emoji in BBCode)", Vector2(tx, 56))
	var toasts := [
		["quest_complete", PaletteS.SUCCESS, "[color=#9fe8a0]Bounty complete —[/color] ready to claim (see the Quest Giver)"],
		["loot", PaletteS.ACCENT, "[color=#ffd24d]Looted[/color]  [color=#c77dff]Epic Cleats[/color]\n[color=#7f93a8]epic · feet  +18 SPD[/color]"],
		["warning", PaletteS.SB_ORANGE, "[color=#ff8a8a]Not enough credits for that (240 credits)[/color]"],
		["information", PaletteS.SB_CYAN, "[color=#8ad6ff]Audible queued for your next Camp run.[/color]"],
		["random_roll", PaletteS.ACCENT, "[b]Ramirez[/b] won [color=#c77dff]Epic Cleats[/color]  (roll 87)"],
	]
	var ty := 82.0
	for t in toasts:
		var card := _toast_card(str(t[0]), t[1], str(t[2]))
		card.position = Vector2(tx, ty)
		_stage.add_child(card)
		ty += 94.0

	await _shot("icons_after_" + tag)

# ---------------------------------------------------------------- BEFORE page (pre-pass reconstruction)
func _page_before(sz: Vector2i, tag: String) -> void:
	_fresh_stage(sz)
	_title("BEFORE (pre-pass): emoji titles · two-letter status chips · symbol-prefixed prose", Vector2(40, 18), PaletteS.DANGER_SOFT, 20)

	_title("WINDOW HEADER (old — emoji drops to the body font)", Vector2(40, 64))
	var oldhdr := _header_preview("📜 Quest Giver", "", "E / Esc", 380.0)
	oldhdr.position = Vector2(40, 88)
	_stage.add_child(oldhdr)

	_title("STATUS CHIPS (old two-letter pseudo-icons — no silhouette, no art)", Vector2(40, 208))
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 3)
	chips.position = Vector2(40, 232)
	_stage.add_child(chips)
	for c in [["SH", PaletteS.SHIELD], ["GD", PaletteS.SB_CYAN], ["DT", PaletteS.DANGER], ["DR", PaletteS.SB_CYAN], ["MS", PaletteS.HEAL], ["EV", PaletteS.HEAL], ["UT", PaletteS.HEAL]]:
		chips.add_child(_old_chip(str(c[0]), c[1]))

	_title("CURRENCY / PROSE (old ◈ ✦ ★ ⚠ prefixes baked into strings)", Vector2(40, 288))
	_stage.add_child(_old_line("◈ 1,240      36 scrap      12 tokens", Vector2(40, 312), PaletteS.CREDITS))
	_stage.add_child(_old_line("✦ Item Power 75      ★ EQUIPPED", Vector2(40, 340), PaletteS.ACCENT))
	_stage.add_child(_old_line("⚠  INVENTORY FULL  ·  50 / 50", Vector2(40, 368), PaletteS.DANGER))

	_title("BUTTONS / TOAST (old emoji-in-label)", Vector2(40, 410))
	var obr := HBoxContainer.new()
	obr.add_theme_constant_override("separation", 12)
	obr.position = Vector2(40, 434)
	_stage.add_child(obr)
	for b in ["⚡ Equip Best", "🗑  Delete  (Y)", "👥  Invite", "🔑 Forge Master Key"]:
		var btn := Button.new()
		btn.text = b
		btn.focus_mode = Control.FOCUS_NONE
		obr.add_child(btn)
	var otoast := _toast_card_plain(PaletteS.ACCENT, "[color=#ffd24d]★ Looted[/color]  [color=#c77dff]Epic Cleats[/color]\n[color=#7f93a8]epic · feet  +18 SPD[/color]")
	otoast.position = Vector2(40, 484)
	_stage.add_child(otoast)

	await _shot("icons_before_" + tag)

# ---------------------------------------------------------------- helpers
func _toast_card(icon_id: String, accent: Color, bb: String) -> PanelContainer:
	var card := _toast_shell(accent)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 9)
	hb.add_child(IconWidS.make(icon_id, {"px": 22, "color": IconRegS.color(icon_id)}))
	var rt := _toast_rt(bb)
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(rt)
	card.add_child(hb)
	return card

func _toast_card_plain(accent: Color, bb: String) -> PanelContainer:
	var card := _toast_shell(accent)
	card.add_child(_toast_rt(bb))
	return card

func _toast_shell(accent: Color) -> PanelContainer:
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PaletteS.BG_PANEL, 0.97)
	sb.set_border_width_all(1)
	sb.set_border_width(SIDE_LEFT, 4)
	sb.border_color = Color(accent, 0.9)
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(9)
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(560, 0)
	return card

func _toast_rt(bb: String) -> RichTextLabel:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.custom_minimum_size = Vector2(480, 0)
	rt.text = bb
	return rt

func _old_chip(letters: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(22, 22)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(PaletteS.SB_INK, 0.92)
	sb.set_border_width_all(1)
	sb.border_color = Color(color, 0.85)
	sb.set_corner_radius_all(4)
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = letters
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", color)
	p.add_child(l)
	return p

func _old_line(text: String, pos: Vector2, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", col)
	return l
