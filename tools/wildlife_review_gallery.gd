extends Node3D
## W1 visual QA renderer (docs/wildlife-expanse-zone2-plan.md): loads each staged wildlife GLB
## through the SAME asset path the client will use (rigged GLB + merged clips/<id>_<role>.res),
## poses every clip at 25/50/75% (+90% for death), captures viewport stills, and composes one
## contact sheet per mob plus a true-relative-scale idle lineup of all seven. Output:
## too_add_models/wildlife_review/. Run windowed (rendering needed):
##   godot --path . --resolution 1280x720 res://tools/wildlife_review_gallery.tscn

const OUT := "res://too_add_models/wildlife_review"
const MOBS := {
	"netvine_skink":      {"h": 0.927, "clips": ["idle", "walk", "attack", "hit", "death"]},
	"tacklehorn_grazer":  {"h": 1.774, "clips": ["idle", "walk", "attack", "hit", "death"]},
	"scrapmask_forager":  {"h": 1.116, "clips": ["idle", "walk", "attack", "hit", "death"]},
	"rallywing_magpie":   {"h": 1.867, "clips": ["idle", "walk", "attack", "flutter", "hit", "death"]},
	"arrowbound_howler":  {"h": 1.413, "clips": ["idle", "walk", "attack", "attack_pounce", "attack_howl", "hit", "death"]},
	"emerald_warfrog":    {"h": 1.765, "clips": ["idle", "walk", "attack", "attack_ground_slam", "attack_croak", "hit", "death"]},
	"splinterback_elite": {"h": 1.723, "clips": ["idle", "walk", "attack", "attack_quill_barrage", "hit", "death"]},
}

var _cam: Camera3D

func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer: return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null: return r
	return null

func _load_mob(id: String) -> Node3D:
	var inst: Node3D = load("res://models/meshy/mobs/rigged/%s.glb" % id).instantiate()
	var ap := _find_ap(inst)
	if ap != null:
		var lib := ap.get_animation_library("")
		if lib == null:
			lib = AnimationLibrary.new()
			ap.add_animation_library("", lib)
		for role in MOBS[id]["clips"]:
			var cp := "res://models/meshy/mobs/rigged/clips/%s_%s.res" % [id, role]
			if ResourceLoader.exists(cp) and not lib.has_animation(role):
				lib.add_animation(role, load(cp))
	return inst

func _shoot() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()

func _sheet(rows: Array, labels: Array, out_path: String) -> void:
	var w: int = rows[0].get_width()
	var h: int = rows[0].get_height()
	var cap := 24
	var page := Image.create(w, (h + cap) * rows.size(), false, Image.FORMAT_RGB8)
	page.fill(Color(0.05, 0.05, 0.08))
	for i in rows.size():
		page.blit_rect(rows[i], Rect2i(0, 0, w, h), Vector2i(0, i * (h + cap) + cap))
	page.save_png(ProjectSettings.globalize_path(out_path))
	print("saved ", out_path, "  (labels top-to-bottom: ", ", ".join(labels), ")")

func _frame_cam(h: float) -> void:
	var d := maxf(h * 1.35, 1.5)
	_cam.position = Vector3(d * 0.75, h * 0.62 + d * 0.28, d)
	_cam.look_at(Vector3(0, h * 0.45, 0))

func _ready() -> void:
	_cam = $Camera3D
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	await get_tree().process_frame
	for id in MOBS:
		var inst := _load_mob(id)
		add_child(inst)
		var ap := _find_ap(inst)
		_frame_cam(float(MOBS[id]["h"]))
		var strips: Array = []
		var labels: Array = []
		for role in MOBS[id]["clips"]:
			if ap == null or not ap.has_animation(role):
				print("SKIP %s_%s (no clip)" % [id, role]); continue
			var length := ap.get_animation(role).length
			var fracs: Array = [0.25, 0.5, 0.75] if role != "death" else [0.25, 0.5, 0.9]
			var cells: Array = []
			for fr in fracs:
				ap.play(role)
				ap.seek(length * fr, true)
				ap.pause()
				var img := await _shoot()
				img.resize(img.get_width() / 3, img.get_height() / 3, Image.INTERPOLATE_LANCZOS)
				cells.append(img)
			var strip := Image.create(cells[0].get_width() * cells.size(), cells[0].get_height(), false, Image.FORMAT_RGB8)
			for c in cells.size():
				strip.blit_rect(cells[c], Rect2i(Vector2i.ZERO, Vector2i(cells[c].get_width(), cells[c].get_height())), Vector2i(c * cells[c].get_width(), 0))
			strips.append(strip)
			labels.append(role)
		if strips.size() > 0:
			_sheet(strips, labels, "%s/%s_clips.png" % [OUT, id])
		remove_child(inst)
		inst.queue_free()
	# true-relative-scale idle lineup of all 7
	var x := 0.0
	var tallest := 0.0
	var widths := {"netvine_skink": 0.8, "tacklehorn_grazer": 1.1, "scrapmask_forager": 1.1,
		"rallywing_magpie": 0.9, "arrowbound_howler": 1.4, "emerald_warfrog": 1.9, "splinterback_elite": 1.9}
	for id in MOBS:
		var inst := _load_mob(id)
		add_child(inst)
		x += float(widths[id]) * 0.75
		inst.position.x = x
		x += float(widths[id]) * 0.75 + 0.35
		tallest = maxf(tallest, float(MOBS[id]["h"]))
		var ap := _find_ap(inst)
		if ap != null and ap.has_animation("idle"):
			ap.play("idle")
			ap.seek(0.5, true)
			ap.pause()
	_cam.position = Vector3(x * 0.5, tallest * 0.85, x * 0.62 + tallest * 1.4)
	_cam.look_at(Vector3(x * 0.5, tallest * 0.42, 0))
	var img := await _shoot()
	img.save_png(ProjectSettings.globalize_path(OUT + "/lineup_idle.png"))
	print("saved ", OUT, "/lineup_idle.png")
	print("GALLERY DONE")
	get_tree().quit()
