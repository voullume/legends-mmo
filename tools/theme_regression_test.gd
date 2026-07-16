extends SceneTree
## UI-consistency pass §0 — theme-propagation regression test. In Godot 4.6 a Window's theme does
## NOT reach Controls under a CanvasLayer (theme inheritance only walks Control/Window ancestors),
## which is why the game Theme never rendered pre-v1.7.1. UITheme.attach(layer) is the fix; this
## harness pins it:
##   • the negative control (the original bug — default stylebox resolves without attach),
##   • direct HUD Controls under the layer,
##   • Controls BELOW non-Control wrappers (subtree entry AND late insertion),
##   • HudLayout's reparenting into HudMod_* wrappers,
##   • hook scoping (nodes outside the layer untouched) + detach on layer exit (relogin safety).
## Headless-safe: godot --headless --path . --script res://tools/theme_regression_test.gd
## Exits non-zero on any failure (CI-compatible; greppable "FAIL").

const UIThemeS := preload("res://client/ui/UITheme.gd")
const PaletteS := preload("res://client/ui/Palette.gd")
const HudLayoutS := preload("res://client/ui/HudLayout.gd")

const TEST_CFG := "user://theme_regression_test.cfg"

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)
	else:
		print("  ok: %s" % what)

# the panel bg a PanelContainer actually resolves through the theme chain
func _panel_bg(c: Control) -> Color:
	var sb := c.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		return (sb as StyleBoxFlat).bg_color
	return Color(-1, -1, -1, -1)   # non-flat default → definitely not ours

func _themed(c: Control) -> bool:
	return _panel_bg(c).is_equal_approx(PaletteS.BG_PANEL)

# _initialize runs BEFORE the root Window is fully inside the tree (get_tree() is null on fresh
# children, theme lookup can't resolve) — run on the first process frame instead, matching the
# production call sites (_ready / _build_hud run in-tree).
var _ran := false

func _process(_delta: float) -> bool:
	if not _ran:
		_ran = true
		_run()
	return false

func _run() -> void:
	print("[theme_regression_test] start")

	# --- negative control: the original bug. Window theme set, no attach — the chain breaks at
	# the CanvasLayer and the default theme resolves (was (0.1,0.1,0.1,0.6) when this was found).
	root.theme = UIThemeS.get_theme()
	var wrap3d_neg := Node3D.new()
	root.add_child(wrap3d_neg)
	var layer_neg := CanvasLayer.new()
	wrap3d_neg.add_child(layer_neg)
	var pc_neg := PanelContainer.new()
	layer_neg.add_child(pc_neg)
	ok(not _themed(pc_neg), "without attach: CanvasLayer breaks Window-theme inheritance (the bug)")
	var direct := PanelContainer.new()
	root.add_child(direct)
	ok(_themed(direct), "control directly under the Window resolves the game theme")
	direct.free()
	wrap3d_neg.free()

	# --- the fix: Window → Node3D → CanvasLayer (the game's real shape), attach()ed
	var wrap3d := Node3D.new()
	root.add_child(wrap3d)
	var layer := CanvasLayer.new()
	wrap3d.add_child(layer)
	UIThemeS.attach(layer)

	# 1) direct HUD Control
	var pc1 := PanelContainer.new()
	layer.add_child(pc1)
	ok(_themed(pc1), "direct child Control of the layer is themed")

	# 2) nested Control inherits through its Control parent (no direct assignment needed)
	var inner := PanelContainer.new()
	pc1.add_child(inner)
	ok(_themed(inner), "Control under a themed Control inherits")
	ok(inner.theme == null, "nested Control inherits WITHOUT a direct assignment (chain intact)")

	# 3) Control below a non-Control wrapper — entering together as one subtree
	var wrapper := Node.new()
	var pc2 := PanelContainer.new()
	wrapper.add_child(pc2)
	layer.add_child(wrapper)
	ok(_themed(pc2), "Control below a non-Control wrapper (subtree entry) is themed")

	# 4) Control inserted LATER below an already-in-tree non-Control wrapper
	var wrapper2 := Node3D.new()
	layer.add_child(wrapper2)
	var pc3 := PanelContainer.new()
	wrapper2.add_child(pc3)
	ok(_themed(pc3), "Control late-inserted below a non-Control wrapper is themed")

	# 5) HudLayout reparenting: register() moves the module into a HudMod_* wrapper — the theme
	# must survive the re-entry (assignment is idempotent) and the wrapper itself gets themed.
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	HudLayoutS.cfg_path = TEST_CFG
	HudLayoutS.reset_registry()
	var host := Control.new()
	host.size = Vector2(1600, 900)
	layer.add_child(host)
	var module := PanelContainer.new()
	module.size = Vector2(260, 120)
	host.add_child(module)
	var mod_inner := PanelContainer.new()
	module.add_child(mod_inner)
	HudLayoutS.register("player_frame", module, {"defaults": {"ox": 12.0, "oy": 10.0}})
	ok((module.get_parent() as Control).name == "HudMod_player_frame", "module reparented by HudLayout")
	ok(_themed(module), "module stays themed after HudLayout reparenting")
	ok(_themed(mod_inner), "module's nested Control stays themed after reparenting")

	# 6) scoping: a chain-broken Control OUTSIDE the layer is not touched by the hook
	var out_wrap := Node.new()
	root.add_child(out_wrap)
	var pc_out := PanelContainer.new()
	out_wrap.add_child(pc_out)
	ok(pc_out.theme == null, "hook leaves Controls outside the layer alone")
	ok(not _themed(pc_out), "chain-broken Control outside the layer resolves default (unscoped)")
	out_wrap.free()

	# 7) detach on layer exit (relogin safety): free the layer, then verify a fresh layer's hook
	# still works and the dead layer's connection is gone (no stale tree-wide handlers stack).
	HudLayoutS.reset_registry()   # release wrapper refs before freeing the subtree
	wrap3d.free()
	var conns_after := root.get_tree().node_added.get_connections().size()
	ok(conns_after == 0, "node_added hook disconnected when the layer left the tree (got %d)" % conns_after)
	var layer2 := CanvasLayer.new()
	root.add_child(layer2)
	UIThemeS.attach(layer2)
	var pc4 := PanelContainer.new()
	layer2.add_child(pc4)
	ok(_themed(pc4), "a fresh layer attach()ed after relogin themes its Controls")
	layer2.free()

	print("[theme_regression_test] %d checks, %d failures" % [checks, fails])
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	quit(1 if fails > 0 else 0)
