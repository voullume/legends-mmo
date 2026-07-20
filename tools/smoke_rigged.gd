extends SceneTree
## Offline measurement harness for rigged-mob metadata (recreates the tool Client.gd:526-528
## references): render_h = rendered mesh height at model scale 1, estimated from the composed
## skeleton bone-rest extent x 1.07 (the flesh margin; matches how the original values were
## produced — bind-pose mesh AABBs are useless here because Meshy exports bake a 0.01 armature
## scale that bone rests counteract). foot_y = lowest composed bone-rest Y (Client grounds with
## yoff = -foot_y * scale). The raw mesh-AABB column is a cross-check only.
## Sanity rows (must roughly reproduce): foam_dummy 1.31/0.075, foam_dummy2 1.45/0.0,
## drill_sergeant 1.71/0.03.

const IDS := [
	"foam_dummy", "foam_dummy2", "drill_sergeant",
	"netvine_skink", "tacklehorn_grazer", "scrapmask_forager", "rallywing_magpie",
	"arrowbound_howler", "emerald_warfrog", "splinterback_elite",
]
const FLESH := 1.07

func _find_all(n: Node, T, xf: Transform3D, out: Array) -> void:
	var local := xf
	if n is Node3D:
		local = xf * (n as Node3D).transform
	if is_instance_of(n, T):
		out.append([n, local])
	for c in n.get_children():
		_find_all(c, T, local, out)

func _init() -> void:
	print("id                     render_h  foot_y | bones  boneExtY | meshAABB_h")
	for id in IDS:
		var path := "res://models/meshy/mobs/rigged/%s.glb" % id
		if not ResourceLoader.exists(path):
			print("%-22s MISSING" % id); continue
		var inst = load(path).instantiate()
		var skels := []
		_find_all(inst, Skeleton3D, Transform3D.IDENTITY, skels)
		var meshes := []
		_find_all(inst, MeshInstance3D, Transform3D.IDENTITY, meshes)
		var mesh_h := 0.0
		var mesh_min := INF
		for pair in meshes:
			var aabb: AABB = (pair[0] as MeshInstance3D).get_aabb()
			for i in 8:
				var p: Vector3 = pair[1] * aabb.get_endpoint(i)
				mesh_h = maxf(mesh_h, p.y)
				mesh_min = minf(mesh_min, p.y)
		# W3 hardening (review note): the wildlife foot_y=0.0 assumption rests on min-Y ≈ 0 — surface
		# a re-export that moves the feet instead of silently corrupting render_h/foot_y.
		if mesh_min < -0.02 or mesh_min > 0.05:
			print("  ^ WARNING %s: mesh min-Y %.3f != 0 — foot_y assumption broken, re-measure!" % [id, mesh_min])
		if skels.is_empty():
			print("%-22s NO SKELETON (meshAABB_h=%.3f)" % [id, mesh_h]); inst.queue_free(); continue
		var lo := INF
		var hi := -INF
		var nbones := 0
		for pair in skels:
			var sk: Skeleton3D = pair[0]
			var xf: Transform3D = pair[1]
			nbones += sk.get_bone_count()
			for b in sk.get_bone_count():
				var y := (xf * sk.get_bone_global_rest(b).origin).y
				lo = minf(lo, y); hi = maxf(hi, y)
		inst.queue_free()
		var ext := hi - lo
		print("%-22s %8.3f %7.3f | %5d %9.3f | %10.3f" % [id, ext * FLESH, lo, nbones, ext, mesh_h])
	quit()
