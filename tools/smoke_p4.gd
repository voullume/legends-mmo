extends SceneTree
# Phase-4 boss smoke — verifies the Head Coach phase system, threshold summons, and the Full Camp Reset
# ult (cover-spare + power-core gate) all fire correctly + deterministically in the sim. Not a balance
# harness (no server) — it drives hp directly to exercise each phase band, then scripts one ult.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const Geom = preload("res://shared/Geom.gd")
const Rng = preload("res://shared/Rng.gd")

func _init():
	var rng = Rng.new(12345)
	var fails := []

	# 2 players (team 0) vs the boss + 4 cores (team 1), with a single cover wall for the LOS-spare test.
	var fighters := []
	var p0 = GameData.create_fighter("striker", 0, 0, rng, 5); p0["x"] = 300.0; p0["y"] = 400.0
	var p1 = GameData.create_fighter("striker", 0, 1, rng, 5); p1["x"] = 320.0; p1["y"] = 460.0
	var boss = GameData.create_fighter("head_coach", 1, 0, rng, 5)
	boss["x"] = 900.0; boss["y"] = 400.0; boss["maxHP"] = 4000.0; boss["hp"] = 4000.0; boss["mobTier"] = "boss"
	fighters = [p0, p1, boss]
	for i in 4:
		var core = GameData.create_fighter("power_core", 1, 10 + i, rng, 5)
		core["x"] = 850.0 + i * 20.0; core["y"] = 300.0 + i * 50.0; core["isCore"] = true
		fighters.append(core)
	var st := {
		"t": 0.0, "seed": 12345, "rng": rng, "fighters": fighters, "projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": ["striker", "striker"], "compB": ["head_coach"], "teamSize": 5, "mapId": "bosstest",
		"map": {"id": "bosstest", "obstacles": [{"x": 600.0, "y": 400.0, "r": 60.0}]},
	}

	# ---- MULTI-BAND BURST: a single tick crossing bands 1 AND 2 must fire BOTH waves, not just the deepest ----
	boss["hp"] = boss["maxHP"] * 0.30   # 100% → 30% in one tick crosses the 70% and 40% thresholds
	st["events"].clear()
	Sim.sim_tick(st, 1.0 / 30.0)
	var mb := 0
	for e in st["events"]:
		if str(e.get("type", "")) == "summon": mb += 1
	if int(boss["phase"]) != 2: fails.append("multi-band: phase should be 2 after a 100%%→30%% drop, got %d" % boss["phase"])
	if mb != 2: fails.append("multi-band burst should fire 2 waves (bands 1+2), got %d" % mb)
	boss["phase"] = 0; boss["_threshSummoned"] = {}   # reset for the gradual single-band test below

	# ---- PHASE BANDS: drive boss hp across each threshold, tick once, assert phase + a one-time summon ----
	var summons := 0
	for band in [[0.65, 1], [0.35, 2], [0.10, 3]]:
		boss["hp"] = boss["maxHP"] * band[0]
		st["events"].clear()
		Sim.sim_tick(st, 1.0 / 30.0)
		if int(boss["phase"]) != band[1]:
			fails.append("phase at hp=%.0f%% should be %d, got %d" % [band[0] * 100, band[1], boss["phase"]])
		var s := 0
		for e in st["events"]:
			if str(e.get("type", "")) == "summon": s += 1
		summons += s
		if s != 1:
			fails.append("entering phase %d should emit exactly 1 summon, got %d" % [band[1], s])

	# re-tick at the same low hp → NO new summon (latched), phase stays 3
	st["events"].clear()
	Sim.sim_tick(st, 1.0 / 30.0)
	for e in st["events"]:
		if str(e.get("type", "")) == "summon": fails.append("threshold summon re-fired after latch")
	if int(boss["phase"]) != 3: fails.append("phase regressed off 3")

	# ---- CAMPRESET ult: cover-spare + core gate. p0 has clear LOS (hit); p1 hides behind the wall (spared) ----
	p0["x"] = 300.0; p0["y"] = 250.0   # off the wall line → clear LOS to boss
	p1["x"] = 300.0; p1["y"] = 400.0   # behind the wall on the boss line (boss 900,400) → LOS blocked → spared
	p0["hp"] = p0["maxHP"]; p1["hp"] = p1["maxHP"]; p0["alive"] = true; p1["alive"] = true
	var los0 = Geom.has_los(st, p0, boss)
	var los1 = Geom.has_los(st, p1, boss)
	if not los0: fails.append("p0 should have clear LOS to boss (test setup)")
	if los1: fails.append("p1 should be LOS-blocked by the wall (test setup)")
	boss["casting"] = {"key": "campreset", "t": 100.0, "total": 3.0, "ab": _ab("campreset")}
	var hp0b = p0["hp"]; var hp1b = p1["hp"]
	Sim.sim_tick(st, 1.0 / 30.0)
	if p0["hp"] >= hp0b: fails.append("ult: exposed p0 took NO damage (cover-spare misfired or 0 dmg)")
	if p1["hp"] < hp1b: fails.append("ult: cover-blocked p1 took damage (should be spared)")

	# ---- CORE GATE: kill all 4 cores → next ult cancelled (0 dmg to the exposed p0) ----
	for cf in st["fighters"]:
		if cf.get("isCore", false): cf["alive"] = false; cf["hp"] = 0.0
	p0["hp"] = p0["maxHP"]; p0["alive"] = true
	boss["casting"] = {"key": "campreset", "t": 100.0, "total": 3.0, "ab": _ab("campreset")}
	var hp0c = p0["hp"]
	Sim.sim_tick(st, 1.0 / 30.0)
	if p0["hp"] < hp0c: fails.append("ult with 0 cores alive should be CANCELLED (0 dmg), but p0 took damage")

	# ---- report ----
	print("smoke_p4: phase_reached_3=%s  threshold_summons=%d  los(exposed)=%s los(blocked)=%s" % [
		int(boss["phase"]) == 3, summons, los0, los1])
	if fails.is_empty():
		print("smoke_p4: PASS — phase system, latched threshold summons, ult cover-spare + core-cancel all correct")
	else:
		print("smoke_p4: FAIL")
		for f in fails: print("   - ", f)
	quit()

func _ab(key):
	for a in GameData.CLASSES["head_coach"]["abilities"]:
		if a["key"] == key: return a
	return null
