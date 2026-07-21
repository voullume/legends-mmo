extends SceneTree
## CI guard: prove every placed decor prop + ground texture actually LOADS + instantiates at runtime
## (the exact _prop_entry path). Guards against shipping an un-importable/valid=false asset — the v1.1.0
## regression where props were registered (ResourceLoader.exists() = true) but load() returned null, so
## the world rendered empty with per-frame errors. exists() is NOT enough; only load() catches it.
##
## Phase 8 (S1 review): DATA-DRIVEN — beyond the curated baseline list, this now scans every
## data/decals/*.json (kind=="prop" models) and every World.OBSTACLES prop id, resolving each through the
## SAME multi-dir fallback as Client._prop_entry, so any decal referencing a broken/missing GLB — in any
## current or future zone — fails CI automatically.

const World := preload("res://shared/World.gd")
const PROP_DIRS := ["res://models/meshy/props/", "res://models/kits/nature/", "res://models/kits/city/"]   # mirror Client.PROP_DIRS

func _resolve(id: String) -> String:
	for d in PROP_DIRS:
		var cand: String = d + id + ".glb"
		if ResourceLoader.exists(cand):
			return cand
	return ""

func _init() -> void:
	# curated baseline (world-decor set) + everything any decal JSON or obstacle row actually references
	var ids := {}
	for id in ["single_locker","player_bench","equipment_shelf","sports_ball_rack","championship_trophy",
		"bounty_terminal","leaderboard_kiosk","zone_terminal","boundary_pylon","player_tunnel_gate",
		"arena_service_door","equipment_transport_crate","straight_cover_barrier","spectator_safety_rail",
		"championship_arena_wall","glitchyard_wall","cable_spool_cart","coolant_pump_station",
		"industrial_ventilation_unit","maintenance_tool_cart","scrap_sports_equipment_pile"]:
		ids[id] = "baseline"
	var dd := DirAccess.open("res://data/decals")
	if dd != null:
		for fn in dd.get_files():
			if not fn.ends_with(".json"):
				continue
			var txt := FileAccess.get_file_as_string("res://data/decals/" + fn)
			var rows = JSON.parse_string(txt)
			if not (rows is Array):
				print("  ✗ decals JSON unparseable: ", fn)
				quit(1)
				return
			for r in rows:
				if r is Dictionary and str(r.get("kind", "")) == "prop":
					ids[str(r.get("model", ""))] = fn
	for mp in World.OBSTACLES:
		for ob in World.OBSTACLES[mp]:
			ids[str(ob.get("prop", ""))] = "OBSTACLES:" + str(mp)

	var fails := 0
	for id in ids:
		var p := _resolve(id)
		if p == "":
			print("  ✗ no GLB found for '%s' (referenced by %s)" % [id, ids[id]]); fails += 1; continue
		var scn = load(p)                     # the exact call that was returning null in v1.1.0
		if scn == null:
			print("  ✗ load() returned NULL: %s (%s)" % [id, ids[id]]); fails += 1; continue
		var inst = scn.instantiate()          # the .instantiate() that was crashing
		if inst == null:
			print("  ✗ instantiate() NULL: %s (%s)" % [id, ids[id]]); fails += 1; continue
		inst.free()
	for t in ["turf_albedo.png","scrapyard_albedo.png","rival_clay_albedo.png","court_albedo.png",
		"wildrange_albedo.png","howler_den_albedo.png","basecamp_albedo.png"]:
		var tp := "res://models/meshy/props/ground/%s" % t
		var tex = load(tp)
		if tex == null:
			print("  ✗ texture load NULL: ", t); fails += 1
	print("=== prop-load verify: %d/%d prop ids OK, textures OK, %d FAILURES ===" % [ids.size() - fails, ids.size(), fails])
	quit(1 if fails > 0 else 0)
