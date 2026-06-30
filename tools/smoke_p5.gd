extends SceneTree
# Phase-5 polish smoke — verifies each new combat primitive: kbImmune, frontal-DR, pull, bait-into-wall
# self-stun, Wobble→stumble, angular-spread, and ricochet. Deterministic; exercises helpers + a few
# functional ticks against a hand-built state with a cover wall.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const Geom = preload("res://shared/Geom.gd")
const Combat = preload("res://shared/Combat.gd")
const Abilities = preload("res://shared/Abilities.gd")
const Rng = preload("res://shared/Rng.gd")

func _ab(cls, key):
	for a in GameData.CLASSES[cls]["abilities"]:
		if a["key"] == key: return a
	return null

func _init():
	var rng = Rng.new(7)
	var fails := []

	# ---- 1. kbImmune helper ----
	var striker = GameData.create_fighter("striker", 0, 0, rng, 5)
	var sled = GameData.create_fighter("sled_juggernaut", 1, 0, rng, 5)
	if Combat.kb_immune(sled) != true: fails.append("sled should be kbImmune")
	if Combat.kb_immune(striker) != false: fails.append("striker should NOT be kbImmune")

	# ---- 2. frontal-DR helper (sled has frontalDR 0.55) ----
	sled["x"] = 500.0; sled["y"] = 400.0
	var atk = {"x": 400.0, "y": 400.0}   # west of the sled
	sled["hx"] = -1.0; sled["hy"] = 0.0  # facing WEST → attacker in front
	var front = Combat.frontal_mult(atk, sled)
	sled["hx"] = 1.0; sled["hy"] = 0.0   # facing EAST → attacker behind
	var back = Combat.frontal_mult(atk, sled)
	if not (front < 0.99): fails.append("frontal hit should be reduced, got %.2f" % front)
	if not (abs(back - 1.0) < 0.01): fails.append("flank/back hit should be full, got %.2f" % back)

	# ---- 3. Wobble → stumble at WOBBLE_MAX ----
	var w = GameData.create_fighter("striker", 0, 1, rng, 5)
	for i in 3: Sim._apply_wobble(w, 1.0)
	if w["stun"] > 0.0: fails.append("3 wobble stacks should NOT stumble yet")
	Sim._apply_wobble(w, 1.0)   # 4th → stumble
	if w["stun"] <= 0.0: fails.append("4 wobble stacks should stumble (stun)")
	if w["wobble"] != 0.0: fails.append("wobble should reset after stumble")

	# ---- build a state with a cover wall for the functional checks ----
	var p0 = GameData.create_fighter("striker", 0, 0, rng, 5); p0["x"] = 250.0; p0["y"] = 400.0
	var boss = GameData.create_fighter("head_coach", 1, 0, rng, 5); boss["x"] = 600.0; boss["y"] = 400.0
	var st := {
		"t": 0.0, "seed": 7, "rng": rng, "fighters": [p0, boss], "zone": true,
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": [], "compB": [], "teamSize": 5, "mapId": "t", "map": {"id": "t", "obstacles": [{"x": 450.0, "y": 400.0, "r": 50.0}]},
	}

	# ---- 4. pull: the boss's Resistance Pull yanks p0 toward the boss (p0 within the 300 radius) ----
	p0["x"] = 400.0; p0["y"] = 400.0; boss["casting"] = null
	var before_d = Geom.dist(p0, boss)   # 200
	boss["casting"] = {"key": "respull", "t": 100.0, "total": 0.8, "ab": _ab("head_coach", "respull")}
	Sim.sim_tick(st, 1.0 / 30.0)
	var after_d = Geom.dist(p0, boss)
	if not (after_d < before_d - 80.0): fails.append("Resistance Pull should yank p0 toward the boss (%.0f→%.0f)" % [before_d, after_d])

	# ---- 5. spread: Scatter Volley creates a fan of direction-mode projectiles (clear LOS, off the wall line) ----
	st["projectiles"].clear()
	var ball = GameData.create_fighter("ball_machine", 1, 1, rng, 5); ball["x"] = 600.0; ball["y"] = 200.0
	st["fighters"].append(ball)
	p0["x"] = 350.0; p0["y"] = 200.0; p0["alive"] = true; p0["hp"] = p0["maxHP"]   # y=200 → clear of the wall at y=400
	Abilities.try_cast(st, ball, _ab("ball_machine", "scatter"), p0)
	var dir_count := 0
	for pr in st["projectiles"]:
		if pr.has("dx"): dir_count += 1
	if dir_count != 5: fails.append("Scatter Volley should fire 5 direction-mode projectiles, got %d" % dir_count)

	# ---- 6. ricochet: a direction-mode projectile from OUTSIDE the wall reflects off it, decrementing bounces ----
	var proj = {"x": 300.0, "y": 400.0, "dx": 1.0, "dy": 0.0, "speed": 380.0, "dmg": 10.0,
		"team": 1, "owner": ball["id"], "key": "bankshot", "bounces": 2, "born": 0.0, "delay": 0.0}
	st["projectiles"] = [proj]
	st["fighters"] = [ball]   # owner present (team-1, won't self-hit); no team-0 target in the path
	# travel east into the wall at (450,400) r50 (left edge ~400) — should reflect (dx flips), stay alive
	for i in 20: Sim._step_dir_projectile(st, proj, 1.0 / 30.0, st["fighters"])
	if proj.get("dead", false): fails.append("ricochet projectile died instead of bouncing (bounces left=%s)" % proj.get("bounces"))
	if int(proj.get("bounces", 2)) >= 2: fails.append("ricochet should have consumed a bounce, left=%s" % proj.get("bounces"))
	if float(proj["dx"]) >= 0.0: fails.append("ricochet should have reflected the x-direction (dx=%.2f)" % proj["dx"])

	# ---- 7. bait-into-wall: a charge whose target is behind cover self-stuns the charger ----
	var sled2 = GameData.create_fighter("sled_juggernaut", 1, 2, rng, 5); sled2["x"] = 250.0; sled2["y"] = 400.0
	var hidden = GameData.create_fighter("striker", 0, 2, rng, 5); hidden["x"] = 600.0; hidden["y"] = 400.0  # boss-side, wall (450) between
	st["fighters"] = [sled2, hidden]
	Abilities.exec_dash_attack(st, sled2, hidden, _ab("sled_juggernaut", "driveblock"))
	if sled2["stun"] <= 0.0: fails.append("a charge blocked by a wall should self-stun the charger")
	if Geom.dist(sled2, hidden) < 70.0: fails.append("a wall-blocked charge should NOT reach the target")

	# ---- report ----
	if fails.is_empty():
		print("smoke_p5: PASS — kbImmune, frontal-DR, Wobble→stumble, pull, spread, ricochet, bait-into-wall all correct")
	else:
		print("smoke_p5: FAIL")
		for f in fails: print("   - ", f)
	quit()
