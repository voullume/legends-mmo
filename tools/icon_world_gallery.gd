extends SceneTree
## Permanent Hybrid-Cutout UI icon system — 3D WORLD-MARKER capture (handoff §15). Renders the
## service-pad markers (icon Sprite3D + Label3D text) at NEAR and FAR fade, and the four entity-plate
## tier markers (power_core / elite / resident / shielded boss) beside plain Label3D text, in a real
## 3D SubViewport. Proves Sprite3D world markers exist alongside — never inside — Label3D text.
##
## Run WINDOWED (needs a real GPU viewport — do NOT pass --headless):
##   ~/.local/bin/godot --path . --script res://tools/icon_world_gallery.gd -- --out <dir>

const WorldUIS := preload("res://client/ui/WorldUI.gd")
const IconRegS := preload("res://client/ui/IconRegistry.gd")

var out_dir := "/home/e/legends-mmo/docs/ui-pass-after-shots"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run()

func _run() -> void:
	await process_frame
	var sz := Vector2i(1920, 1080)
	var sv := SubViewport.new()
	sv.size = sz
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)

	# dark 3D ground so the billboards read like they do over the field
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.02, 0.035, 0.06)
	env.environment = e
	sv.add_child(env)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.6, 6.0)
	cam.fov = 60.0
	sv.add_child(cam)
	cam.make_current()

	# --- service-pad markers at NEAR / MID / FAR distance to show the icon↔text spacing across range ---
	var shop := WorldUIS.pad_marker("shop", "Shop", Color(1.0, 0.88, 0.5), Vector3(-3.2, 1.4, 0.0))
	sv.add_child(shop)                                        # near, full alpha
	WorldUIS.fade_pad_marker(shop, 1.0)
	var vendor := WorldUIS.pad_marker("practice_vendor", "Practice Vendor", Color(0.5, 0.9, 1.0), Vector3(0.0, 2.2, -9.0))
	sv.add_child(vendor)                                      # mid distance
	WorldUIS.fade_pad_marker(vendor, 0.85)
	var forge := WorldUIS.pad_marker("forge", "Forge", Color(1.0, 0.6, 0.4), Vector3(4.6, 3.2, -22.0))
	sv.add_child(forge)                                       # far — where the perspective gap compresses most
	WorldUIS.fade_pad_marker(forge, 0.55)

	# --- entity-plate tier markers beside plain Label3D text ---
	var plates := [
		["power_core", "POWER CORE", WorldUIS.CORE, -4.2],
		["elite", "Lv 14  ELITE", WorldUIS.MOB_ELITE, -1.4],
		["resident", "Blitz-7", Color(0.80, 0.72, 1.0), 1.4],
		["shielded", "SHIELDED — DESTROY THE CORES", WorldUIS.BOSS_SHIELDED, 4.2],
	]
	for p in plates:
		var holder := Node3D.new()
		holder.position = Vector3(float(p[3]), -0.8, 0.0)
		sv.add_child(holder)
		var sp := WorldUIS.plate_tier_marker()
		sp.texture = IconRegS.texture(str(p[0]))
		sp.modulate = p[2]
		sp.visible = true
		sp.position.y = 0.7
		holder.add_child(sp)
		var lbl := WorldUIS.pad_label(str(p[1]), p[2], Vector3.ZERO)
		holder.add_child(lbl)

	for _n in 6:
		await process_frame
	var img := sv.get_texture().get_image()
	img.save_png(out_dir + "/icons_world_markers_1920x1080.png")
	print("[icon_world_gallery] icons_world_markers_1920x1080.png (%dx%d)" % [img.get_width(), img.get_height()])
	quit(0)
