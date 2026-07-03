extends SceneTree
## RP0 AI-residents test (server-side; no net/supa). Proves: the roster spawns as team-0 fighters with the
## right identity + tier scaling; they are AI-driven (NOT `controlled`) and actually engage mobs when their
## world ticks; the polite/rude flag + kill-attribution helper behave. Determinism is proven separately.
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _res_in(srv, mapname: String, res_id: String):
	for f in srv._worlds[mapname]["fighters"]:
		if f.get("resident", false) and str(f.get("resId", "")) == res_id:
			return f
	return null

func _init() -> void:
	var srv = ServerScript.new()
	for mapname in World.MAPS:
		if World.is_instance_template(mapname):
			continue
		srv._worlds[mapname] = srv._new_world(mapname)
	srv._spawn_world_actors()
	srv._spawn_residents()

	# --- roster spawned + identity ---
	ok(srv._residents.size() == ServerScript.RESIDENTS.size(), "all %d residents spawned" % ServerScript.RESIDENTS.size())
	var sarge = _res_in(srv, "glitchyard_2", "sarge")
	var mercy = _res_in(srv, "glitchyard_1", "mercy")
	var vulture = _res_in(srv, "glitchyard_4", "vulture")
	ok(sarge != null and mercy != null and vulture != null, "residents spawned in their home zones")
	if sarge == null:
		print("=== residents: %d passed, %d failed ===" % [pass_n, fail_n]); quit(1); return
	var sg: Dictionary = sarge
	ok(int(sg["team"]) == 0, "resident is team 0 (a friendly AI player)")
	ok(str(sg.get("resName", "")) == "Sarge" and int(sg.get("resLevel", 0)) == 6, "resident carries name + level")
	ok(bool(sg.get("resPolite", false)) == true, "Sarge is polite")
	ok(bool((vulture as Dictionary).get("resPolite", true)) == false, "Vulture is the rude one")

	# --- tier scaling: a mid-tier lvl-6 linebacker has more HP than a fresh one (level HP + tier mult) ---
	var fresh = srv._spawn_fighter("linebacker", 0, Vector2(100, 100), "home")   # ungeared, no scaling
	ok(float(sg["maxHP"]) > float((srv._find(fresh))["maxHP"]) * 1.5, "tier scaling boosts resident HP (%.0f vs %.0f)" % [float(sg["maxHP"]), float((srv._find(fresh))["maxHP"])])
	ok(int(sg.get("resLevel", 0)) == 6, "resident level preserved")

	# --- AI-driven: tick the resident's world; it must ENGAGE a mob (deal damage) since it's not `controlled` ---
	var before_hp := {}
	for f in srv._worlds["glitchyard_2"]["fighters"]:
		if f["team"] == 1: before_hp[f["id"]] = float(f["hp"])
	for _i in 120:                                # ~4s
		srv._tick_world(srv._worlds["glitchyard_2"], "glitchyard_2")
	var mob_took_dmg := false
	for f in srv._worlds["glitchyard_2"]["fighters"]:
		if f["team"] == 1 and (not f["alive"] or float(f["hp"]) < float(before_hp.get(f["id"], 999999.0))):
			mob_took_dmg = true
	ok(mob_took_dmg, "resident engaged + damaged a mob (AI brain drives it)")
	ok(float(sarge["dmgDealt"]) > 0.0 or not bool(sarge["alive"]), "resident dealt damage (or died fighting)")

	# --- kill-attribution helper: nearest player within range (no players → -1) ---
	ok(srv._nearest_player_pid("glitchyard_2", Vector2(500, 280), 280.0) == -1, "no player nearby → no kill credit")

	# --- RP1 director: a routing resident JOURNEYS to the next zone when its dwell elapses ---
	var router_fid := ""
	for fid in srv._residents:
		if str((srv._residents[fid] as Dictionary).get("id", "")) == "sarge":
			router_fid = str(fid)
	ok(router_fid != "" and (srv._residents[router_fid].get("route") is Array), "sarge is a router (has a route)")
	if router_fid != "":
		(srv._res_dir[router_fid] as Dictionary)["next_move_t"] = 0   # force the dwell to elapse
		var rf: Dictionary = srv._find(router_fid)
		var before_map := str(rf["map"])
		srv._tick_residents(3.0)                     # > 2s cadence → the director runs
		var rf2: Dictionary = srv._find(router_fid)
		var after_map := str(rf2["map"])
		ok(after_map != before_map, "director advanced the router (%s → %s)" % [before_map, after_map])

		# walk the FULL route (incl. wraparound) — route_idx must stay in lockstep with the real zone
		var route: Array = srv._residents[router_fid].get("route", [])
		var synced := true
		for _step in route.size():
			(srv._res_dir[router_fid] as Dictionary)["next_move_t"] = 0
			srv._tick_residents(3.0)
			var idx := int((srv._res_dir[router_fid] as Dictionary).get("route_idx", -1))
			var zone := str((srv._find(router_fid) as Dictionary)["map"])
			if idx < 0 or idx >= route.size() or zone != str(route[idx]):
				synced = false
		ok(synced, "route_idx stays in lockstep with the real zone across a full wraparound")

		# review finding #1 is BENIGN: a router whose dwell elapsed while dead, on revive, moves once
		# immediately but LANDS in a valid next zone with route_idx synced — no state corruption.
		var rf3: Dictionary = srv._find(router_fid)
		rf3["alive"] = false                          # died with the dwell timer already due
		(srv._res_dir[router_fid] as Dictionary)["next_move_t"] = 0
		srv._tick_residents(3.0)                      # dead → skipped; timer NOT rescheduled
		rf3["alive"] = true                           # revived in place (as _advance_respawns would)
		var idx_before := int((srv._res_dir[router_fid] as Dictionary).get("route_idx", 0))
		srv._tick_residents(3.0)                      # now moves immediately — but cleanly
		var idx_after := int((srv._res_dir[router_fid] as Dictionary).get("route_idx", 0))
		var zone_after := str((srv._find(router_fid) as Dictionary)["map"])
		ok(idx_after == (idx_before + 1) % route.size() and zone_after == str(route[idx_after]),
			"post-respawn immediate move is non-corrupting (idx+1, zone synced)")

	print("=== residents (RP0): %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
