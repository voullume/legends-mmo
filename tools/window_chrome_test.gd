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

	print("[window_chrome_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
