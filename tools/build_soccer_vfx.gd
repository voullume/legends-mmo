# Provenance / build tooling (dev-only, NOT a runtime asset). Run once to (re)generate the runtime
# soccer-ball VFX resources from the approved, imported OBJ:
#   godot --headless --path . --script res://tools/build_soccer_vfx.gd
#
# It reuses the approved geometry VERBATIM (same 60 verts / 32 faces / two material groups) and only
# recomputes FLAT per-face normals so the ball reads as the approved intentional facet look instead of
# the smoothed normals the OBJ importer generates. It does NOT remodel or regenerate the ball.
extends SceneTree

const DIR := "res://client/vfx/projectiles/soccer_ball/"

func _init() -> void:
	var src := load(DIR + "soccer_ball.obj") as ArrayMesh
	if src == null:
		push_error("[build_soccer_vfx] could not load imported soccer_ball.obj")
		quit(1)
		return

	# 1) materials — warm-white hexagons, charcoal pentagons (from the approved MTL), with a small
	# emission floor so the ball never collapses into a dark dot, and a faint copper rim accent.
	var white := StandardMaterial3D.new()
	white.resource_name = "soccer_white"
	white.albedo_color = Color(0.82, 0.76, 0.63)
	white.roughness = 0.7
	white.metallic = 0.05
	white.emission_enabled = true
	white.emission = Color(0.82, 0.76, 0.63)
	white.emission_energy_multiplier = 0.2
	white.rim_enabled = true
	white.rim = 0.25
	white.rim_tint = 0.4
	ResourceSaver.save(white, DIR + "materials/soccer_white.tres")

	var charcoal := StandardMaterial3D.new()
	charcoal.resource_name = "soccer_charcoal"
	charcoal.albedo_color = Color(0.03, 0.035, 0.045)
	charcoal.roughness = 0.78
	charcoal.metallic = 0.05
	charcoal.emission_enabled = true
	charcoal.emission = Color(0.35, 0.22, 0.12)       # faint copper seam glow
	charcoal.emission_energy_multiplier = 0.06
	charcoal.rim_enabled = true
	charcoal.rim = 0.3
	charcoal.rim_tint = 0.2
	ResourceSaver.save(charcoal, DIR + "materials/soccer_charcoal.tres")

	var white_ld := load(DIR + "materials/soccer_white.tres")
	var charcoal_ld := load(DIR + "materials/soccer_charcoal.tres")

	# 2) flat-shaded mesh — same vertices/faces, per-face normals (unindexed so nothing re-averages).
	var out := ArrayMesh.new()
	for s in range(src.get_surface_count()):
		var arr := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var i := 0
		while i < idx.size():
			var a: Vector3 = verts[idx[i]]
			var b: Vector3 = verts[idx[i + 1]]
			var c: Vector3 = verts[idx[i + 2]]
			var n := (b - a).cross(c - a).normalized()
			st.set_normal(n); st.add_vertex(a)
			st.set_normal(n); st.add_vertex(b)
			st.set_normal(n); st.add_vertex(c)
			i += 3
		var marr := st.commit_to_arrays()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, marr)
		var src_mat := src.surface_get_material(s)
		var nm := str(src_mat.resource_name) if src_mat != null else ""
		out.surface_set_material(s, charcoal_ld if nm == "charcoal" else white_ld)
		out.surface_set_name(s, nm)
	ResourceSaver.save(out, DIR + "soccer_ball_mesh.tres")
	print("[build_soccer_vfx] mesh surfaces=", out.get_surface_count(), " aabb=", out.get_aabb())

	# 3) soccer_ball.tscn — the reusable ball asset (Step 1 acceptance scene). Neutral Node3D root,
	# imported mesh beneath it, no collision, no gameplay script, shadows off.
	var mesh_ld := load(DIR + "soccer_ball_mesh.tres")
	var ball_root := Node3D.new()
	ball_root.name = "SoccerBall"
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh_ld
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball_root.add_child(mi)
	mi.owner = ball_root
	_save_scene(ball_root, DIR + "soccer_ball.tscn")

	# 4) scripted presentation scenes (behaviour lives in the .gd; the .tscn is just the scripted root).
	# soccer_projectile.tscn is the SHARED ball projectile (finesse + throughball + future variants);
	# each variant differs by registry tune + impact scene, NOT by a duplicated projectile scene.
	_save_scene(load(DIR + "SoccerProjectileVFX.gd").new(), DIR + "soccer_projectile.tscn")
	_save_scene(load(DIR + "FinesseImpactVFX.gd").new(), DIR + "finesse_impact.tscn")
	_save_scene(load(DIR + "ThroughballImpactVFX.gd").new(), DIR + "throughball_impact.tscn")
	_save_scene(load(DIR + "ClinicalImpactVFX.gd").new(), DIR + "clinical_impact.tscn")
	_save_scene(load(DIR + "ClinicalReleaseVFX.gd").new(), DIR + "clinical_release.tscn")
	_save_scene(load(DIR + "GoldenGoalImpactVFX.gd").new(), DIR + "goldengoal_impact.tscn")
	_save_scene(load(DIR + "GoldenChargeVFX.gd").new(), DIR + "goldengoal_charge.tscn")
	_save_scene(load(DIR + "GoldenRewardVFX.gd").new(), DIR + "goldengoal_reward.tscn")
	_save_scene(load(DIR + "DribbleVFX.gd").new(), DIR + "dribble.tscn")
	_save_scene(load(DIR + "YellowCardVFX.gd").new(), DIR + "yellowcard.tscn")
	_save_scene(load(DIR + "StepOverVFX.gd").new(), DIR + "stepover.tscn")
	_save_scene(load(DIR + "BicycleKickVFX.gd").new(), DIR + "bicyclekick.tscn")
	_save_scene(load(DIR + "BicycleImpactVFX.gd").new(), DIR + "bicycle_impact.tscn")

	print("[build_soccer_vfx] done")
	quit(0)

func _save_scene(root: Node, path: String) -> void:
	var ps := PackedScene.new()
	var err := ps.pack(root)
	if err != OK:
		push_error("[build_soccer_vfx] pack failed for %s (err %d)" % [path, err])
		return
	var serr := ResourceSaver.save(ps, path)
	if serr != OK:
		push_error("[build_soccer_vfx] save failed for %s (err %d)" % [path, serr])
