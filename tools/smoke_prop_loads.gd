extends SceneTree
## CI guard: prove every placed decor prop + ground texture actually LOADS + instantiates at runtime
## (the exact _prop_entry path). Guards against shipping an un-importable/valid=false asset — the v1.1.0
## regression where props were registered (ResourceLoader.exists() = true) but load() returned null, so
## the world rendered empty with per-frame errors. exists() is NOT enough; only load() catches it.
func _init() -> void:
	var props := ["single_locker","player_bench","equipment_shelf","sports_ball_rack","championship_trophy",
		"bounty_terminal","leaderboard_kiosk","zone_terminal","boundary_pylon","player_tunnel_gate",
		"arena_service_door","equipment_transport_crate","straight_cover_barrier","spectator_safety_rail",
		"championship_arena_wall","glitchyard_wall","cable_spool_cart","coolant_pump_station",
		"industrial_ventilation_unit","maintenance_tool_cart","scrap_sports_equipment_pile"]
	var fails := 0
	for id in props:
		var p := "res://models/meshy/props/%s.glb" % id
		if not ResourceLoader.exists(p):
			print("  ✗ not registered: ", id); fails += 1; continue
		var scn = load(p)                     # the exact call that was returning null
		if scn == null:
			print("  ✗ load() returned NULL: ", id); fails += 1; continue
		var inst = scn.instantiate()          # the .instantiate() that was crashing
		if inst == null:
			print("  ✗ instantiate() NULL: ", id); fails += 1; continue
		inst.free()
	for t in ["turf_albedo.png","scrapyard_albedo.png"]:
		var tp := "res://models/meshy/props/ground/%s" % t
		var tex = load(tp)
		if tex == null:
			print("  ✗ texture load NULL: ", t); fails += 1
	print("=== prop-load verify: %d/%d props OK, textures OK, %d FAILURES ===" % [props.size()-fails, props.size(), fails])
	quit(1 if fails > 0 else 0)
