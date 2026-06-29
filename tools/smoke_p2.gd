extends SceneTree
## P2 mechanics smoke: run all-striker[5] vs all-<elite>[5] and confirm (a) matches terminate, (b) the
## Drill Sergeant EMITS summon events (the sim half of the summon bridge) and CREATES a damaging hazard
## zone, and (c) the hazard zone actually deals damage to players standing in it. (The server half of
## summon — spawning the adds — is verified live post-deploy; the harness has no server.)
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")

func _run(comp_a: Array, comp_b: Array, seed_value: int, max_t: float) -> Dictionary:
	var st = Sim.create_match(comp_a, comp_b, seed_value, "stadium")
	var saw_summon := false
	var saw_dmg_zone := false
	var zone_hp_lost := 0.0
	var guard := 0
	var cap := int(30.0 * max_t)
	while st["winner"] == null and guard < cap:
		# snapshot player HP + who's inside a dmg zone, BEFORE the tick applies the zone DOT
		var pre := {}
		for f in st["fighters"]:
			if f["team"] == 0 and f["alive"]:
				for z in st["zones"]:
					if float(z.get("dmg", 0.0)) > 0.0 and Vector2(f["x"] - z["x"], f["y"] - z["y"]).length() <= float(z["radius"]):
						pre[f["id"]] = f["hp"]
						break
		Sim.sim_tick(st, 1.0 / 30.0)
		guard += 1
		for ev in st["events"]:
			if ev.get("type") == "summon":
				saw_summon = true
		for z in st["zones"]:
			if float(z.get("dmg", 0.0)) > 0.0:
				saw_dmg_zone = true
		for f in st["fighters"]:
			if pre.has(f["id"]) and f["alive"] and pre[f["id"]] > f["hp"]:
				zone_hp_lost += pre[f["id"]] - f["hp"]
		st["events"].clear()        # mimic the server (keeps the scan bounded)
	return {"winner": st["winner"], "dur": st["t"], "summon": saw_summon, "dmgzone": saw_dmg_zone, "zonehp": zone_hp_lost}

func _init() -> void:
	print("=== P2 elite smoke (all-striker[5] vs all-<elite>[5], stadium, seed 7) ===")
	for e in ["drill_sergeant", "sled_juggernaut", "ball_machine"]:
		var pc := []
		var mc := []
		for _i in 5:
			pc.append("striker")
			mc.append(e)
		var r = _run(pc, mc, 7, 100.0)
		print("  %-16s winner=%s dur=%.1f  summon_emitted=%s  dmg_zone=%s  zone_dmg~%.0f" % [
			e, str(r["winner"]), r["dur"], str(r["summon"]), str(r["dmgzone"]), r["zonehp"]])
	quit()
