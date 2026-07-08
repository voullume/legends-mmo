extends SceneTree
## Inspect optimized GLBs in models/incoming/_optimized/: prints each one's real bounding-box size (the SAME AABB
## the game uses to render + scale a prop) and a SUGGESTED collision footprint factor for World.PROP_FOOTPRINT.
##
## PROP_FOOTPRINT[model] = block-radius-per-unit-height, so collision r = FOOTPRINT * placed_height (sim units).
## Derivation: rendered footprint (world) = (max(W,D)/2) * (h / H); sim = world * 20 (SCALE 0.05) ⇒
##   FOOTPRINT ≈ 10 * max(W,D) / H   (H = model height). We round + let you eyeball/adjust.
##
## Run:  godot --headless --path . --script res://tools/asset_inspect.gd   (after --import)
const SRC := "res://models/incoming/_optimized/"

func _corners(node: Node, x: Transform3D, acc: Array) -> void:
	if node is Node3D:
		x = x * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var a: AABB = (node as MeshInstance3D).mesh.get_aabb()
		for i in 8:
			var c := a.position + Vector3(a.size.x * float(i & 1), a.size.y * float((i >> 1) & 1), a.size.z * float((i >> 2) & 1))
			acc.append(x * c)
	for ch in node.get_children():
		_corners(ch, x, acc)

func _init() -> void:
	var d := DirAccess.open(SRC)
	if d == null:
		print("no folder at %s — drop GLBs in models/incoming/ then run tools/optimize_assets.sh first" % SRC)
		quit(); return
	print("=== asset inspect — %s ===" % SRC)
	print("  (H×W×D in model units · suggested collision factor for World.PROP_FOOTPRINT)")
	var count := 0
	for fn in d.get_files():
		if not fn.to_lower().ends_with(".glb"):
			continue
		count += 1
		var scene = load(SRC + fn)
		if scene == null:
			print("  %-26s  — FAILED to load (did you run --import?)" % fn.get_basename())
			continue
		var inst = scene.instantiate()
		var pts := []
		_corners(inst, Transform3D.IDENTITY, pts)
		inst.free()
		if pts.is_empty():
			print("  %-26s  — no meshes found" % fn.get_basename())
			continue
		var mn: Vector3 = pts[0]
		var mx: Vector3 = pts[0]
		for p in pts:
			mn = mn.min(p)
			mx = mx.max(p)
		var s: Vector3 = mx - mn
		var W := s.x
		var H := maxf(s.y, 0.001)
		var D := s.z
		# footprint factor is scale-INVARIANT (a ratio), so it's right no matter what scale the model was authored at.
		# It's the VISUAL footprint — dial DOWN for soft/passable props (bushes), leave OFF entirely for flat décor.
		var foot := snappedf(10.0 * maxf(W, D) / H, 0.1)
		var shape := "wide" if maxf(W, D) > H * 1.3 else ("tall" if H > maxf(W, D) * 1.3 else "boxy")
		print("  %-26s  H%5.2f W%5.2f D%5.2f  (%s)   → PROP_FOOTPRINT ~%.1f" % [fn.get_basename(), H, W, D, shape, foot])
	if count == 0:
		print("  (empty — drop GLBs in models/incoming/, run tools/optimize_assets.sh, then --import)")
	quit()
