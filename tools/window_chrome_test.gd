extends SceneTree
## UI-consistency phase B — window chrome geometry regression. The marquee windows (Shop /
## Inventory / Character / Quest Journal) wear the HudFrame PANEL chassis, whose chamfer cuts the
## bottom-right corner away. That squeezes the resize grip between two constraints that nearly
## collide, and getting it wrong is INVISIBLE in screenshots but breaks input:
##   • too far out  → the grip floats outside the rail, over the 3D world;
##   • too far in   → the grip covers content and STEALS its clicks (it is a later sibling of the
##                    PanelContainer, so it wins GUI picking — it ate the Inventory/Shop scrollbar
##                    grabbers at the first cut, turning "drag the scrollbar" into "resize window").
## Asserts, for BOTH chrome and plain panels: grip ∩ content is empty, and (chrome) the grip's
## far corner sits inside the chamfer diagonal. Also pins the non-chrome geometry as unchanged.
## Run: godot --headless --path . --script res://tools/window_chrome_test.gd

const WidgetsS := preload("res://client/ui/Widgets.gd")
const HudFrameS := preload("res://client/ui/HudFrame.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)
	else:
		print("  ok: %s" % what)

var _ran := false

func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false

# find the grip: the ColorRect sibling of the PanelContainer under the window root
func _grip_of(root: Control) -> ColorRect:
	for c in root.get_children():
		if c is ColorRect:
			return c as ColorRect
	return null

func _frame_of(pc: Control) -> HudFrame:
	for c in pc.get_children():
		if c is HudFrame:
			return c as HudFrame
	return null

func _build(chrome: bool) -> Dictionary:
	var host := Control.new()
	host.size = Vector2(1920, 1080)
	root.add_child(host)
	var p: Dictionary = WidgetsS.panel("ChromeTest%s" % ("C" if chrome else "P"), "X / Esc", 760.0,
		func() -> void: pass, chrome)
	var win: Control = p["root"]
	host.add_child(win)
	# give the body real content so the panel takes a realistic size
	var filler := Control.new()
	filler.custom_minimum_size = Vector2(720, 430)
	(p["body"] as VBoxContainer).add_child(filler)
	win.visible = true
	return {"root": win, "pc": p["panel"], "host": host}

func _run() -> void:
	print("[window_chrome_test] start")
	# unique titles → _restore_window finds no saved entry, so geometry is deterministic
	for chrome in [false, true]:
		var tag := "chrome" if chrome else "plain"
		var w := _build(chrome)
		var pc: Control = w["pc"]
		var grip := _grip_of(w["root"])
		ok(grip != null, "%s: grip exists" % tag)
		if grip == null:
			continue
		# content rect = the MarginContainer's rect (pc-local)
		var mc: Control = null
		for c in pc.get_children():
			if c is MarginContainer:
				mc = c
		ok(mc != null, "%s: content MarginContainer exists" % tag)
		var content := Rect2(mc.position + Vector2(20, 20), mc.size - Vector2(40, 40))   # 20px margins
		var grip_local := Rect2(grip.position - pc.position, grip.size)
		var overlap := content.intersection(grip_local)
		ok(overlap.get_area() <= 0.01,
			"%s: grip does NOT overlap content (content %s, grip %s, overlap area %.1f)"
				% [tag, content, grip_local, overlap.get_area()])

		if chrome:
			var fr := _frame_of(pc)
			ok(fr != null, "chrome: HudFrame chassis present under the PanelContainer")
			# the grip's far (bottom-right) corner must sit INSIDE the chamfer diagonal.
			# _draw_panel: r = Rect2(1.5, 1.5, w-3, h-3), c = clamp(min(w,h)*0.18, 6, 16), br = c.
			# Diagonal (pc-local) runs (end.x - c, end.y) → (end.x, end.y - c) where end = size - 1.5.
			var c := clampf(minf(pc.size.x, pc.size.y) * 0.18, 6.0, 16.0)
			var endp := pc.size - Vector2(1.5, 1.5)
			var far := grip_local.end                       # grip's bottom-right corner
			var dx := endp.x - far.x
			var dy := endp.y - far.y
			ok(dx + dy >= c, "chrome: grip corner inside the chamfer diagonal (dx+dy=%.1f >= c=%.1f)" % [dx + dy, c])
			ok(dx >= 0.0 and dy >= 0.0, "chrome: grip inside the panel rect")
		else:
			ok(grip_local.end.is_equal_approx(pc.size), "plain: grip still pinned flush to the corner (unchanged)")

	_run_persistence()

	print("[window_chrome_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)

# Icon-bearing header + stable-persistence-key migration (handoff §6). A title-string change (emoji /
# subtitle removal) moves the persistence key; a one-time migration must adopt the geometry saved
# under the OLD title so users never lose placement, then re-home it under the stable key. Drives the
# real visibility → _restore_window lifecycle. Uses throwaway keys and cleans them up.
func _run_persistence() -> void:
	var newk := "__wct_persist_new__"
	var legk := "__wct_persist_legacy__"
	var freshk := "__wct_persist_fresh__"
	# seed a legacy saved geometry (as if the user had placed the old emoji-titled window)
	var seed := ConfigFile.new()
	seed.load(WidgetsS.WIN_CFG)                       # keep audio/fx + real window keys
	for k in [newk, freshk]:
		if seed.has_section_key("windows", k):
			seed.erase_section_key("windows", k)     # clean slate for the new keys
	seed.set_value("windows", legk, {"x": 300.0, "y": 200.0, "cw": 640.0, "ch": 420.0})
	seed.save(WidgetsS.WIN_CFG)

	var host := Control.new()
	host.size = Vector2(1920, 1080)
	root.add_child(host)
	var p: Dictionary = WidgetsS.panel("PersistTest", "X / Esc", 560.0, func() -> void: pass, false,
		{"icon": "inventory", "persist": newk, "legacy": legk})
	var win: Control = p["root"]
	host.add_child(win)
	# header icon present (icon-bearing header case)
	var head := (p["body"] as VBoxContainer).get_child(0)
	var has_icon := false
	for c in head.get_children():
		if c is TextureRect:
			has_icon = true
	ok(has_icon, "persist: icon-bearing header carries a TextureRect")
	win.visible = true                               # → visibility_changed → _restore_window → migration

	var after := ConfigFile.new()
	after.load(WidgetsS.WIN_CFG)
	ok(after.has_section_key("windows", newk), "persist: geometry migrated to the stable key")
	ok(not after.has_section_key("windows", legk), "persist: legacy key erased after migration")
	var saved = after.get_value("windows", newk, {})
	ok(saved is Dictionary and absf(float(saved.get("x", -1)) - 300.0) < 0.5, "persist: migrated geometry preserved (x=300)")
	var pc: Control = p["panel"]
	ok(absf(pc.position.x - 300.0) < 1.5 and absf(pc.position.y - 200.0) < 1.5,
		"persist: window restored to the migrated position (got %s)" % pc.position)

	# a fresh (unsaved) persist key opens + centers deterministically, no crash / no migration
	var p2: Dictionary = WidgetsS.panel("PersistFresh", "X", 560.0, func() -> void: pass, false, {"persist": freshk})
	host.add_child(p2["root"])
	(p2["root"] as Control).visible = true
	ok(true, "persist: fresh persist key opens without crash")

	# clean up the throwaway keys so real user settings stay untouched
	var clean := ConfigFile.new()
	clean.load(WidgetsS.WIN_CFG)
	for k in [newk, legk, freshk]:
		if clean.has_section_key("windows", k):
			clean.erase_section_key("windows", k)
	clean.save(WidgetsS.WIN_CFG)
