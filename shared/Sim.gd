extends RefCounted
## Main simulation — simTick + createMatch + runHeadlessMatch + winProb.
## Faithful port of the web sim's tick loop. Visual events omitted (render-only).

const Rng := preload("res://shared/Rng.gd")
const GameData := preload("res://shared/GameData.gd")
const Geom := preload("res://shared/Geom.gd")
const Combat := preload("res://shared/Combat.gd")
const Abilities := preload("res://shared/Abilities.gd")
const AI := preload("res://shared/AI.gd")

static func _find_fighter(state, id) -> Variant:
	for f in state["fighters"]:
		if f["id"] == id:
			return f
	return null

static func _find_alive(state, id) -> Variant:
	if id == null: return null
	for f in state["fighters"]:
		if f["id"] == id and f["alive"]:
			return f
	return null

static func _nearest_enemy(state, f) -> Variant:
	var best: Variant = null
	var bd = INF
	for e in state["fighters"]:
		if e["team"] != f["team"] and e["alive"]:
			var dd = Geom.dist(f, e)
			if dd < bd:
				bd = dd
				best = e
	return best

static func _ab_order(c) -> Array:
	# ult > special > basic, source order preserved within each rank (matches JS stable sort)
	var order = []
	for ab in c["abilities"]:
		if ab.get("ult", false): order.append(ab)
	for ab in c["abilities"]:
		if not ab.get("ult", false) and not ab.get("basic", false): order.append(ab)
	for ab in c["abilities"]:
		if ab.get("basic", false): order.append(ab)
	return order

static func sim_tick(state, dt) -> void:
	state["t"] += dt
	var fighters = state["fighters"]

	# QB pocket-DR aura
	for f in fighters:
		f["_pocketDR"] = 0.0
	for qb in fighters:
		var c = GameData.CLASSES[qb["classId"]]
		if not qb["alive"] or not c.has("pocketDR"): continue
		var has_allies = false
		for a in fighters:
			if a["team"] == qb["team"] and a["alive"] and a["id"] != qb["id"]:
				has_allies = true
				break
		if not has_allies:
			qb["_pocketDR"] = c["pocketDR"]
			continue
		for a in fighters:
			if a["team"] == qb["team"] and a["alive"] and a["id"] != qb["id"] and Geom.dist(qb, a) < c["pocketRange"]:
				a["_pocketDR"] = c["pocketDR"]

	# team focus (0.5s cadence)
	if state["t"] - state["lastFocusEval"] > 0.5:
		state["focus"][0] = AI.pick_focus_target(state, 0)
		state["focus"][1] = AI.pick_focus_target(state, 1)
		state["lastFocusEval"] = state["t"]

	# zones
	for z in state["zones"]:
		z["t"] -= dt
	var live_zones = []
	for z in state["zones"]:
		if z["t"] > 0: live_zones.append(z)
	state["zones"] = live_zones

	# projectiles
	for p in state["projectiles"]:
		if p["delay"] > 0:
			p["delay"] -= dt
			continue
		var tgt = _find_fighter(state, p["tx"])
		if tgt == null or not tgt["alive"]:
			p["dead"] = true
			continue
		var dx = tgt["x"] - p["x"]
		var dy = tgt["y"] - p["y"]
		var d = Vector2(dx, dy).length()
		var step = p["speed"] * dt
		if d <= step + 14:
			var src = _find_fighter(state, p["owner"])
			if src != null:
				Combat.deal_damage(state, src, tgt, p["dmg"], {"projectile": true, "basic": p.get("basic", false), "key": p["key"]})
				if p.get("stun", null) != null: tgt["stun"] = max(tgt["stun"], p["stun"])
				if p.get("slow", null) != null:
					tgt["slowT"] = p["slow"]["dur"]
					tgt["slowAmt"] = p["slow"]["amt"]
				if p.get("teamShieldPct", null) != null:
					for a in fighters:
						if a["team"] == src["team"] and a["alive"]:
							Combat.apply_shield(state, src, a, a["maxHP"] * p["teamShieldPct"], 3.0)
			p["dead"] = true
		else:
			p["x"] += (dx / d) * step
			p["y"] += (dy / d) * step
			for o in state["map"]["obstacles"]:
				if Vector2(p["x"] - o["x"], p["y"] - o["y"]).length() < o["r"]:
					p["dead"] = true
					break
	var live_proj = []
	for p in state["projectiles"]:
		if not p.get("dead", false) and state["t"] - p["born"] < 4: live_proj.append(p)
	state["projectiles"] = live_proj

	# fighters
	for f in fighters:
		if not f["alive"]: continue
		var c = GameData.CLASSES[f["classId"]]

		# timers
		for k in f["cds"]:
			f["cds"][k] = max(0.0, f["cds"][k] - dt)
		f["stun"] = max(0.0, f["stun"] - dt)
		f["evade"] = max(0.0, f["evade"] - dt)
		f["untarget"] = max(0.0, f["untarget"] - dt)
		f["slowT"] = max(0.0, f["slowT"] - dt)
		f["flash"] = max(0.0, f["flash"] - dt)
		f["noDmgT"] += dt
		f["buffs"]["critT"] = max(0.0, f["buffs"]["critT"] - dt)
		f["buffs"]["atkspdT"] = max(0.0, f["buffs"]["atkspdT"] - dt)
		f["buffs"]["drT"] = max(0.0, f["buffs"]["drT"] - dt)
		f["buffs"]["msT"] = max(0.0, f["buffs"]["msT"] - dt)
		f["buffs"]["bypass"] = max(0.0, f["buffs"]["bypass"] - dt)
		f["buffs"]["reflect"] = max(0.0, f["buffs"]["reflect"] - dt)
		f["hatChainT"] = max(0.0, f["hatChainT"] - dt)
		f["atkCommitT"] = max(0.0, f["atkCommitT"] - dt)
		if f["momentumT"] > 0:
			f["momentumT"] -= dt
		elif f["momentum"] > 0:
			f["momentum"] = max(0.0, f["momentum"] - dt * 1.5)
		if f["shieldT"] > 0:
			f["shieldT"] -= dt
			if f["shieldT"] <= 0: f["shield"] = 0.0

		# clean sheet (Goalkeeper)
		if c.has("cleanSheetRate") and f["noDmgT"] > c["cleanSheetDelay"] and f["shield"] < c["cleanSheetCap"]:
			f["shield"] = min(float(c["cleanSheetCap"]), f["shield"] + c["cleanSheetRate"] * dt)
			f["shieldT"] = max(f["shieldT"], 1.0)

		# barrier expiry blast (Penalty Save)
		if f["barrierT"] > 0:
			f["barrierT"] -= dt
			if f["barrierT"] <= 0 and f["_barrierAb"] != null:
				var bab = f["_barrierAb"]
				var bfrac = min(1.0, f["barrierStored"] / 300.0)
				var blast = bab["blastDmg"] * (0.45 + 0.55 * bfrac)
				for e in fighters:
					if e["team"] != f["team"] and e["alive"] and Geom.dist(f, e) < bab["blastRadius"]:
						Combat.deal_damage(state, f, e, blast / f["dmgMult"], {"key": "penaltysave"})
				f["barrier"] = 0.0
				f["_barrierAb"] = null

		if f["stun"] > 0: continue

		# finish casts
		if f["casting"] != null:
			f["casting"]["t"] += dt
			if f["casting"]["t"] >= f["casting"]["total"]:
				var ab = f["casting"]["ab"]
				var ctgt: Variant = null
				if f["casting"].has("targetId") and f["casting"]["targetId"] != null:
					ctgt = _find_fighter(state, f["casting"]["targetId"])
				if ab["type"] == "melee" and ctgt != null and ctgt["alive"] and Geom.dist(f, ctgt) < ab["range"] + 30:
					Combat.deal_damage(state, f, ctgt, ab["dmg"], {"melee": true, "key": ab["key"]})
					if ab.has("knockback"):
						var kd = Vector2(ctgt["x"] - f["x"], ctgt["y"] - f["y"]).length()
						if kd == 0: kd = 1.0
						ctgt["x"] += ((ctgt["x"] - f["x"]) / kd) * ab["knockback"]
						ctgt["y"] += ((ctgt["y"] - f["y"]) / kd) * ab["knockback"]
						Geom.clamp_arena(ctgt)
				elif ab["type"] == "meleeAoe":
					for e in fighters:
						if e["team"] != f["team"] and e["alive"] and Geom.dist(f, e) < ab["radius"]:
							Combat.deal_damage(state, f, e, ab["dmg"], {"melee": true, "key": ab["key"]})
							if ab.has("knockback"):
								var kd = Vector2(e["x"] - f["x"], e["y"] - f["y"]).length()
								if kd == 0: kd = 1.0
								e["x"] += ((e["x"] - f["x"]) / kd) * ab["knockback"]
								e["y"] += ((e["y"] - f["y"]) / kd) * ab["knockback"]
								Geom.clamp_arena(e)
				elif ab["type"] == "dashAttack" and ctgt != null and ctgt["alive"]:
					Abilities.exec_dash_attack(state, f, ctgt, ab)
				elif ab["type"] == "leapAttack" and ctgt != null and ctgt["alive"]:
					Combat.deal_damage(state, f, ctgt, ab["dmg"], {"melee": true, "airborne": ab.get("airborne", false), "key": ab["key"]})
				f["casting"] = null
			continue

		# PLAYER-CONTROLLED FIGHTER (Phase 1 seam): if an external controller has injected an
		# intent for this fighter, drive movement + abilities from it and skip the AI brain.
		# Inert for AI-only matches (state has no "controlled" key) — determinism preserved.
		var controlled: Dictionary = state.get("controlled", {})
		if controlled.has(f["id"]):
			_player_step(state, f, controlled[f["id"]], dt)
			continue

		# PRACTICE FREEZE (Phase 1): when set, non-controlled fighters hold position — no
		# targeting, offense, or movement — so the player can explore controls unrushed.
		# Absent in headless/AI-only matches, so determinism is unaffected.
		if state.get("botsFrozen", false):
			continue

		# support routing (does not block offense/movement)
		AI.support_tick(state, f, dt)

		# pick target: peel > focus > nearest
		var target: Variant = null
		var is_defender = c["lane"] == 0
		var peel = AI.peel_target(state, f) if is_defender else null
		if peel != null: target = peel["threat"]
		if target == null: target = _find_alive(state, state["focus"][f["team"]])
		if target == null: target = _nearest_enemy(state, f)
		if target == null: continue

		# offensive ability: ult > special > basic
		for ab in _ab_order(c):
			if f["cds"][ab["key"]] > 0: continue
			if ab["type"] == "allybuff" or ab["type"] == "allyheal" or ab["type"] == "teamheal": continue
			if ab.get("ult", false) and target["hp"] / target["maxHP"] > 0.7 and state["t"] < 8: continue
			if Abilities.try_cast(state, f, ab, target):
				break

		# movement brain
		var want = AI.desired_range(f["classId"])
		var d = Geom.dist(f, target)
		var ranged = want > 100
		var los = Geom.has_los(state, f, target)
		if not ranged and c["lane"] == 1:
			var has_front = false
			for a in fighters:
				if a["team"] == f["team"] and a["alive"] and a["id"] != f["id"] and GameData.CLASSES[a["classId"]]["lane"] == 0:
					has_front = true
					break
			var front_engaged = false
			if has_front:
				for a in fighters:
					if a["team"] == f["team"] and a["alive"] and GameData.CLASSES[a["classId"]]["lane"] == 0:
						for e in fighters:
							if e["team"] != f["team"] and e["alive"] and Geom.dist(a, e) < 100:
								front_engaged = true
								break
					if front_engaged: break
			var soft = target["hp"] / target["maxHP"] < 0.75
			if has_front and not front_engaged and not soft and state["t"] < 10: want = 175

		# pillar hugging
		var hug_point: Variant = null
		if state["map"]["obstacles"].size() > 0 and state["focus"][1 - f["team"]] == f["id"] and f["hp"] / f["maxHP"] < 0.55 and f["noDmgT"] < 4:
			var threat = _nearest_enemy(state, f)
			if threat != null and (Geom.dist(f, threat) < 230 or f["hp"] / f["maxHP"] < 0.35):
				var best: Variant = null
				var bdd = INF
				for o in state["map"]["obstacles"]:
					if o["r"] < 30: continue
					var od = Vector2(f["x"] - o["x"], f["y"] - o["y"]).length()
					if od < 280 and od < bdd:
						best = o
						bdd = od
				if best != null:
					var td = max(1.0, Vector2(best["x"] - threat["x"], best["y"] - threat["y"]).length())
					hug_point = {
						"x": best["x"] + ((best["x"] - threat["x"]) / td) * (best["r"] + 26),
						"y": best["y"] + ((best["y"] - threat["y"]) / td) * (best["r"] + 26)}

		# heal-seek
		var heal_seek: Variant = null
		if hug_point == null:
			var is_support = false
			for a in c["abilities"]:
				if a["type"] == "allyheal" or (a["type"] == "allybuff" and a.has("shieldPct")):
					is_support = true
					break
			if is_support:
				var blind: Variant = null
				var blind_frac = 1.0e9
				for a in fighters:
					if a["team"] == f["team"] and a["alive"] and a["id"] != f["id"] and a["hp"] / a["maxHP"] < 0.5 and not Geom.has_los(state, f, a):
						var fr = a["hp"] / a["maxHP"]
						if fr < blind_frac:
							blind_frac = fr
							blind = a
				if blind != null: heal_seek = blind

		# move-mode hysteresis
		f["flipT"] = max(0.0, f["flipT"] - dt)
		if ranged:
			if f["moveMode"] == "approach":
				if d < want + 6: f["moveMode"] = "strafe"
			elif f["moveMode"] == "kite":
				if d > want - 12: f["moveMode"] = "strafe"
			else:
				if d > want + 30: f["moveMode"] = "approach"
				elif d < want - 48: f["moveMode"] = "kite"
		else:
			if f["moveMode"] != "approach" and d > want + 16: f["moveMode"] = "approach"
			elif f["moveMode"] == "approach" and d < want - 2: f["moveMode"] = "orbit"

		# execute movement
		if hug_point != null and Vector2(hug_point["x"] - f["x"], hug_point["y"] - f["y"]).length() > 10:
			AI.step_toward(state, f, hug_point["x"], hug_point["y"], dt)
		elif heal_seek != null:
			AI.step_toward(state, f, heal_seek["x"], heal_seek["y"], dt, 0.9)
		elif ranged and not los:
			AI.step_toward(state, f, target["x"], target["y"], dt)
		elif f["moveMode"] == "approach":
			if not ranged: f["chaseT"] += dt
			var pursuit = 1.0
			if not ranged: pursuit = 1.0 + min(0.18, max(0.0, f["chaseT"] - 3) * 0.06)
			AI.step_toward(state, f, target["x"], target["y"], dt, pursuit)
		elif ranged and f["moveMode"] == "kite":
			var away = atan2(f["y"] - target["y"], f["x"] - target["x"]) + f["strafeDir"] * 0.55
			AI.step_toward(state, f, f["x"] + cos(away) * 120, f["y"] + sin(away) * 120, dt, 0.92)
		elif ranged:
			var ang = atan2(f["y"] - target["y"], f["x"] - target["x"]) + f["strafeDir"] * 0.9
			var sx = target["x"] + cos(ang) * want
			var sy = target["y"] + sin(ang) * want
			if f["flipT"] <= 0 and (sx < GameData.ARENA_PAD + 16 or sx > GameData.ARENA_W - GameData.ARENA_PAD - 16 or sy < GameData.ARENA_PAD + 16 or sy > GameData.ARENA_H - GameData.ARENA_PAD - 16):
				f["strafeDir"] *= -1
				f["flipT"] = 0.7
			AI.step_toward(state, f, sx, sy, dt, 0.65)
		else:
			f["chaseT"] = 0.0
			var ang2 = atan2(f["y"] - target["y"], f["x"] - target["x"]) + f["strafeDir"] * 0.45
			AI.step_toward(state, f, target["x"] + cos(ang2) * (want + 2), target["y"] + sin(ang2) * (want + 2), dt, 0.4)

		AI.separation(state, f, dt)

	# win check
	var a_alive = false
	var b_alive = false
	for f in fighters:
		if f["alive"]:
			if f["team"] == 0: a_alive = true
			else: b_alive = true
	if not a_alive or not b_alive or state["t"] > GameData.TIME_LIMIT:
		if not a_alive and not b_alive:
			state["winner"] = 0 if state["rng"].next() < 0.5 else 1
		elif not a_alive:
			state["winner"] = 1
		elif not b_alive:
			state["winner"] = 0
		else:
			var hp_a = 0.0
			var hp_b = 0.0
			for f in fighters:
				if f["team"] == 0: hp_a += f["hp"] / f["maxHP"]
				else: hp_b += f["hp"] / f["maxHP"]
			state["winner"] = 0 if hp_a >= hp_b else 1
			state["timeout"] = true

static func create_match(comp_a, comp_b, seed_value, map_id := ""):
	var rng = Rng.new(seed_value)
	var team_size = max(comp_a.size(), comp_b.size())
	var mid = map_id
	if mid == "" or not GameData.MAPS.has(mid):
		mid = GameData.MAP_IDS[int(rng.next() * GameData.MAP_IDS.size())]
	var fighters = []
	for i in comp_a.size():
		fighters.append(GameData.create_fighter(comp_a[i], 0, i, rng, team_size))
	for i in comp_b.size():
		fighters.append(GameData.create_fighter(comp_b[i], 1, i, rng, team_size))
	return {
		"t": 0.0, "seed": seed_value, "rng": rng, "fighters": fighters,
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": comp_a, "compB": comp_b, "teamSize": team_size, "mapId": mid, "map": GameData.MAPS[mid],
	}

static func run_headless_match(comp_a, comp_b, seed_value, map_id := ""):
	var state = create_match(comp_a, comp_b, seed_value, map_id)
	var dt = 1.0 / 30.0
	var guard = 0
	var cap = int(30 * (GameData.TIME_LIMIT + 5))
	while state["winner"] == null and guard < cap:
		sim_tick(state, dt)
		guard += 1
	return {
		"winner": state["winner"], "duration": snappedf(state["t"], 0.1),
		"timeout": state["timeout"], "mapId": state["mapId"], "fmt": state["teamSize"],
	}

static func win_prob(state) -> float:
	var a = 0.0
	var b = 0.0
	for f in state["fighters"]:
		if not f["alive"]: continue
		var ehp = f["hp"] + f["shield"] + f["maxHP"] * 0.15
		if f["team"] == 0: a += ehp
		else: b += ehp
	if a + b == 0: return 0.5
	return a / (a + b)

# --- Player control (Phase 1) ---------------------------------------------------
# A controlled fighter is driven by an `intent` Dictionary:
#   { "mx": float, "my": float, "ability": String }
# `mx/my` is a movement direction in sim space (magnitude <= 1); `ability` is the key
# of an ability to attempt this tick (consumed once). All resolution reuses the SAME
# Abilities/AI/Combat helpers the bots use — the human just replaces the AI driver.

static func _ability_by_key(c, key):
	for ab in c["abilities"]:
		if ab["key"] == key:
			return ab
	return null

static func _lowest_ally_or_self(state, f) -> Dictionary:
	var best: Dictionary = f
	var best_frac: float = f["hp"] / f["maxHP"]
	for a in state["fighters"]:
		if a["team"] == f["team"] and a["alive"] and a["id"] != f["id"]:
			var fr = a["hp"] / a["maxHP"]
			if fr < best_frac:
				best_frac = fr
				best = a
	return best

# Support abilities (allybuff/allyheal/teamheal) aren't handled by Abilities.try_cast
# (the bots route them through AI.support_tick). For a human we resolve them directly,
# self/lowest-ally targeted, no AI gating.
static func _player_support_cast(state, f, ab) -> void:
	var c = GameData.CLASSES[f["classId"]]
	var cd_mult: float = 1.0 - f["cdr"]
	match ab["type"]:
		"allyheal":
			var t := _lowest_ally_or_self(state, f)
			Combat.apply_heal(state, f, t, t["maxHP"] * ab["healPct"])
			var e_heal := AI._echo(c, f)   # Six-Pack echo parity (Setter)
			if e_heal > 0.0:
				Combat.apply_heal(state, f, t, t["maxHP"] * ab["healPct"] * e_heal)
		"teamheal":
			for a in state["fighters"]:
				if a["team"] == f["team"] and a["alive"]:
					Combat.apply_heal(state, f, a, a["maxHP"] * ab["healPct"])
					if ab.get("cleanse", false):
						a["stun"] = 0.0
						a["slowT"] = 0.0
		"allybuff":
			var t := _lowest_ally_or_self(state, f)
			if ab.has("shieldPct"):
				Combat.apply_shield(state, f, t, t["maxHP"] * ab["shieldPct"], ab["dur"])
				var e_shield := AI._echo(c, f)   # Six-Pack echo parity (Setter)
				if e_shield > 0.0:
					Combat.apply_shield(state, f, t, t["maxHP"] * ab["shieldPct"] * e_shield, ab["dur"])
			elif ab.has("buff"):
				var b = ab["buff"]
				if b.has("nextdmg"): t["buffs"]["nextdmg"] = b["nextdmg"]
				if b.has("crit"):
					t["buffs"]["crit"] = b["crit"]
					t["buffs"]["critT"] = b["dur"]
				if b.has("atkspd"):
					t["buffs"]["atkspd"] = b["atkspd"]
					t["buffs"]["atkspdT"] = b.get("dur", 2.2)
				if b.has("ms"):
					t["buffs"]["ms"] = b["ms"]
					t["buffs"]["msT"] = b["dur"]
				AI._echo(c, f)   # advance the echo counter (parity with AI.support_tick)
	f["cds"][ab["key"]] = ab["cd"] * cd_mult
	f["lastCastKey"] = ab["key"]

# Self-buff / barrier for a human: apply the effect UNCONDITIONALLY. try_cast gates these on
# the AI's defensive heuristics (only when pressured / low HP), which would silently swallow a
# human's button press at full HP — so player control resolves them directly.
static func _player_self_cast(_state, f, ab) -> void:
	match ab["type"]:
		"selfbuff":
			var b = ab["buff"]
			if b.has("dr"):
				f["buffs"]["dr"] = b["dr"]
				f["buffs"]["drT"] = b["dur"]
			if b.has("ms"):
				f["buffs"]["ms"] = b["ms"]
				f["buffs"]["msT"] = b["dur"]
			if b.has("bypass"): f["buffs"]["bypass"] = b["dur"]
			if b.has("reflect"): f["buffs"]["reflect"] = b["dur"]
		"barrier":
			f["barrier"] = ab["dr"]
			f["barrierT"] = ab["dur"]
			f["barrierStored"] = 0.0
			f["_barrierAb"] = ab
	f["cds"][ab["key"]] = ab["cd"] * (1.0 - f["cdr"])
	f["lastCastKey"] = ab["key"]

# Dash for a human: lunge in the steering/aim direction (the AI dash picks gap-close vs escape
# from heuristics and needs an enemy nearby; a player dashes where they're pointing).
static func _player_dash(_state, f, ab, mvx, mvy) -> void:
	var dx: float = mvx
	var dy: float = mvy
	var dl := Vector2(dx, dy).length()
	if dl < 0.001:                       # no steering input → dash along current heading
		dx = f["hx"]
		dy = f["hy"]
		dl = Vector2(dx, dy).length()
	if dl < 0.001:
		dx = float(f["facing"])
		dy = 0.0
		dl = 1.0
	f["x"] += (dx / dl) * ab["dist"]
	f["y"] += (dy / dl) * ab["dist"]
	Geom.clamp_arena(f)
	if ab.has("evade"): f["evade"] = ab["evade"]
	f["cds"][ab["key"]] = ab["cd"] * (1.0 - f["cdr"])
	f["lastCastKey"] = ab["key"]

static func _player_step(state, f, intent, dt) -> void:
	var c = GameData.CLASSES[f["classId"]]
	# movement: steer toward a point in the intent direction (reuses obstacle steering,
	# turn-rate facing, slow/buff/atk-commit speed modifiers).
	var mvx: float = intent.get("mx", 0.0)
	var mvy: float = intent.get("my", 0.0)
	var ml := Vector2(mvx, mvy).length()
	if ml > 0.001:
		# Direct, responsive movement for a human (no AI turn-rate steering — that exists for
		# bot "feel" and would stick a player who reverses against their spawn heading). Same
		# speed modifiers as AI.step_toward: slow, ms-buff, post-fire commit, hat-trick chain.
		var dirx := mvx / ml
		var diry := mvy / ml
		var spd: float = f["ms"]
		if f["slowT"] > 0: spd *= (1.0 - f["slowAmt"])
		if f["buffs"]["msT"] > 0: spd *= f["buffs"]["ms"]
		if f["atkCommitT"] > 0: spd *= 0.45
		if f["hatChainT"] > 0 and c.has("chainMS"): spd *= c["chainMS"]
		f["x"] += dirx * spd * dt
		f["y"] += diry * spd * dt
		f["hx"] = dirx
		f["hy"] = diry
		f["facing"] = 1 if dirx >= 0 else -1
		Geom.clamp_arena(f)
	# ability: attempt the queued key once (auto-target nearest enemy for offense).
	var key: String = intent.get("ability", "")
	if key != "":
		var ab: Variant = _ability_by_key(c, key)
		if ab != null and f["cds"].get(key, 0.0) <= 0.0 and f["casting"] == null:
			# Self/utility/support resolve through dedicated player paths (apply unconditionally);
			# offensive abilities use try_cast so range/LOS still gate them honestly.
			match ab["type"]:
				"allybuff", "allyheal", "teamheal":
					_player_support_cast(state, f, ab)
				"selfbuff", "barrier":
					_player_self_cast(state, f, ab)
				"dash":
					_player_dash(state, f, ab, mvx, mvy)
				_:
					var tgt = _nearest_enemy(state, f)
					if tgt != null:
						Abilities.try_cast(state, f, ab, tgt)
		intent["ability"] = ""
	AI.separation(state, f, dt)
