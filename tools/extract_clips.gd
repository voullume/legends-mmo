extends SceneTree
## Build step: extract rigged-mob animation clips from _src GLBs into portable Animation .res files
## (cyclic idle/walk/run loop; root motion stripped — Hips X/Z pinned, Y kept only for death). Generalized
## over a dummy id + its roles. Used for the foam dummies and the drill sergeant.
func _strip_root(clip: Animation, clamp_y: bool) -> void:
	for i in clip.get_track_count():
		if clip.track_get_type(i) != Animation.TYPE_POSITION_3D: continue
		if not str(clip.track_get_path(i)).ends_with(":Hips"): continue
		var kc := clip.track_get_key_count(i)
		if kc == 0: return
		var base: Vector3 = clip.track_get_key_value(i, 0)
		for k in kc:
			var v: Vector3 = clip.track_get_key_value(i, k)
			v.x = base.x; v.z = base.z
			if clamp_y: v.y = base.y
			clip.track_set_key_value(i, k, v)
		return

func _find(n: Node, T):
	if is_instance_of(n, T): return n
	for c in n.get_children():
		var r = _find(c, T)
		if r != null: return r
	return null

func _init() -> void:
	var jobs := {
		"drill_sergeant": ["idle", "walk", "run", "attack", "hit", "death", "cast"],
	}
	var cyclic := {"idle": true, "walk": true, "run": true}
	for d in jobs:
		for role in jobs[d]:
			var path := "res://models/meshy/mobs/rigged/_src/%s_%s.glb" % [d, role]
			if not ResourceLoader.exists(path):
				print("MISSING ", path); continue
			var scene = load(path).instantiate()
			var ap := _find(scene, AnimationPlayer) as AnimationPlayer
			if ap == null or ap.get_animation_list().is_empty():
				print("NO ANIM ", path); scene.queue_free(); continue
			var clip: Animation = ap.get_animation(ap.get_animation_list()[0]).duplicate(true)
			if cyclic.get(role, false): clip.loop_mode = Animation.LOOP_LINEAR
			_strip_root(clip, role != "death")
			var out := "res://models/meshy/mobs/rigged/clips/%s_%s.res" % [d, role]
			var err := ResourceSaver.save(clip, out)
			var hips := ""
			for i in clip.get_track_count():
				if str(clip.track_get_path(i)).ends_with(":Hips"): hips = str(clip.track_get_path(i)); break
			print("%-22s len=%.2f tracks=%d loop=%d hips='%s' save=%d" % [d + "_" + role, clip.length, clip.get_track_count(), clip.loop_mode, hips, err])
			scene.queue_free()
	quit()
