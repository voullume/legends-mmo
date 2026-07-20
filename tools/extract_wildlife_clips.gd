extends SceneTree
## W1 build step (docs/wildlife-expanse-zone2-plan.md): extract the wildlife mobs' EMBEDDED
## animation clips into portable .res files at models/meshy/mobs/rigged/clips/<id>_<role>.res —
## the convention _load_rigged_mobs expects. Unlike tools/extract_clips.gd (per-role _src GLBs,
## Meshy biped ":Hips" roots), these GLBs carry all clips in one AnimationPlayer and use custom
## Blender skeletons, so roles map by clip name and root motion is MEASURED and reported, not
## blindly stripped: the manifests author locomotion in-place, and death/hop displacement lives
## on an intentional visual root that must be preserved.

const JOBS := {
	"netvine_skink":      {"idle": "idle", "move": ["walk", "run"], "attack": "attack", "hit": "hit", "death": "death"},
	"tacklehorn_grazer":  {"idle": "idle", "move": ["walk", "run"], "attack": "attack", "hit": "hit", "death": "death"},
	"scrapmask_forager":  {"idle": "idle", "move": ["walk", "run"], "attack": "attack", "hit": "hit", "death": "death"},
	"rallywing_magpie":   {"idle": "idle", "move": ["walk", "run"], "attack": "attack", "hit": "hit", "death": "death", "flutter": "flutter"},
	"arrowbound_howler":  {"idle": "idle", "move": ["walk", "run"], "attack_bite": "attack", "attack_pounce": "attack_pounce", "attack_howl": "attack_howl", "hit": "hit", "death": "death"},
	"emerald_warfrog":    {"idle": "idle", "move": ["walk", "run"], "attack_swipe": "attack", "attack_ground_slam": "attack_ground_slam", "attack_croak": "attack_croak", "hit": "hit", "death": "death"},
	"splinterback_elite": {"idle": "idle", "move": ["walk", "run"], "attack_head_slam": "attack", "attack_quill_barrage": "attack_quill_barrage", "hit": "hit", "death": "death"},
}
const LOOPING := {"idle": true, "walk": true, "run": true}

func _find(n: Node, T):
	if is_instance_of(n, T): return n
	for c in n.get_children():
		var r = _find(c, T)
		if r != null: return r
	return null

## Max XZ / Y drift of any position track across the clip (drift = key farthest from key 0).
func _drift(clip: Animation) -> Vector2:
	var worst := Vector2.ZERO
	for i in clip.get_track_count():
		if clip.track_get_type(i) != Animation.TYPE_POSITION_3D: continue
		var kc := clip.track_get_key_count(i)
		if kc < 2: continue
		var base: Vector3 = clip.track_get_key_value(i, 0)
		for k in kc:
			var v: Vector3 = clip.track_get_key_value(i, k) - base
			worst.x = maxf(worst.x, Vector2(v.x, v.z).length())
			worst.y = maxf(worst.y, absf(v.y))
	return worst

func _init() -> void:
	var fails := 0
	for id in JOBS:
		var path := "res://models/meshy/mobs/rigged/%s.glb" % id
		if not ResourceLoader.exists(path):
			print("MISSING ", path); fails += 1; continue
		var scene = load(path).instantiate()
		var ap := _find(scene, AnimationPlayer) as AnimationPlayer
		if ap == null:
			print("NO ANIMPLAYER ", id); fails += 1; scene.queue_free(); continue
		var have := {}
		for an in ap.get_animation_list():
			have[an.get_slice("/", an.get_slice_count("/") - 1)] = an
		for src_name in JOBS[id]:
			if not have.has(src_name):
				print("MISSING CLIP %s in %s (have: %s)" % [src_name, id, ap.get_animation_list()]); fails += 1; continue
			var roles = JOBS[id][src_name]
			if typeof(roles) != TYPE_ARRAY: roles = [roles]
			for role in roles:
				var clip: Animation = ap.get_animation(have[src_name]).duplicate(true)
				clip.loop_mode = Animation.LOOP_LINEAR if LOOPING.get(role, false) else Animation.LOOP_NONE
				var d := _drift(clip)
				var out := "res://models/meshy/mobs/rigged/clips/%s_%s.res" % [id, role]
				var err := ResourceSaver.save(clip, out)
				if err != OK: fails += 1
				var flag := "  <-- LOCOMOTION DRIFT" if (role in ["idle", "walk", "run"] and d.x > 0.05) else ""
				print("%-40s len=%5.2f tracks=%3d loop=%d driftXZ=%.3f driftY=%.3f save=%d%s" % [
					id + "_" + role, clip.length, clip.get_track_count(), clip.loop_mode, d.x, d.y, err, flag])
		scene.queue_free()
	print("EXTRACT DONE fails=%d" % fails)
	quit(1 if fails > 0 else 0)
