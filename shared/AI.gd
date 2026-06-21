extends RefCounted
## Team AI + movement — focus fire, peel, support routing, step_toward, separation.
## Faithful port of the sim's WoW-arena-style logic.

const GameData := preload("res://shared/GameData.gd")
const Combat := preload("res://shared/Combat.gd")
const Geom := preload("res://shared/Geom.gd")

# --- target scoring & focus ---
static func kill_score(f, enemy) -> float:
	var c = GameData.CLASSES[enemy["classId"]]
	var hp_frac = (enemy["hp"] + enemy["shield"]) / enemy["maxHP"]
	var s = (1.0 - hp_frac) * 2.2
	s += (1.0 - c["stats"]["END"] / 80.0) * 0.9
	s += (enemy["dmgDealt"] / 2000.0) * 0.4
	s -= Geom.dist(f, enemy) / 700.0
	if enemy["shield"] > 0: s -= 0.25
	if enemy["untarget"] > 0 or enemy["evade"] > 0: s -= 2.0
	return s

static func pick_focus_target(state, team) -> Variant:
	var allies = []
	var enemies = []
	for fr in state["fighters"]:
		if not fr["alive"]: continue
		if fr["team"] == team: allies.append(fr)
		else: enemies.append(fr)
	if enemies.is_empty() or allies.is_empty(): return null
	var cx = 0.0
	var cy = 0.0
	for a in allies:
		cx += a["x"]
		cy += a["y"]
	var centroid = {"x": cx / allies.size(), "y": cy / allies.size()}
	var best: Variant = null
	var best_s = -1.0e9
	for e in enemies:
		var s = kill_score(centroid, e)
		if s > best_s:
			best_s = s
			best = e
	var cur: Variant = null
	if state["focus"][team] != null:
		for fr in state["fighters"]:
			if fr["id"] == state["focus"][team] and fr["alive"]:
				cur = fr
				break
	if cur != null:
		var cur_s = kill_score(centroid, cur)
		if best_s < cur_s * GameData.SWAP_HYSTERESIS:
			return cur["id"]
	return best["id"]

static func peel_target(state, f) -> Variant:
	for a in state["fighters"]:
		if a["team"] == f["team"] and a["alive"] and a["id"] != f["id"]:
			if a["hp"] / a["maxHP"] < GameData.PEEL_HP:
				for e in state["fighters"]:
					if e["team"] != f["team"] and e["alive"] and Geom.dist(e, a) < GameData.PEEL_RANGE:
						return {"ally": a, "threat": e}
	return null

static func desired_range(class_id) -> float:
	var c = GameData.CLASSES[class_id]
	var basic: Variant = null
	for a in c["abilities"]:
		if a.get("basic", false):
			basic = a
			break
	if basic["type"] == "melee": return 50.0
	return min(float(basic["range"]) - 40.0, 250.0)

# --- movement ---
static func step_toward(state, f, tx, ty, dt, speed_mult := 1.0) -> void:
	var dx = tx - f["x"]
	var dy = ty - f["y"]
	var d = Vector2(dx, dy).length()
	if d < 2: return
	var block: Variant = null
	var bd = INF
	for o in state["map"]["obstacles"]:
		var od = Vector2(o["x"] - f["x"], o["y"] - f["y"]).length()
		if od < bd and od < d + o["r"] and od < o["r"] + 130 and Geom.seg_blocked(f["x"], f["y"], tx, ty, o, 18.0):
			block = o
			bd = od
	if block != null:
		var ox = f["x"] - block["x"]
		var oy = f["y"] - block["y"]
		var od2 = Vector2(ox, oy).length()
		if od2 == 0: od2 = 1.0
		var ang_f = atan2(oy, ox)
		var ang_t = atan2(ty - block["y"], tx - block["x"])
		var d_ang = ang_t - ang_f
		while d_ang > PI: d_ang -= 2.0 * PI
		while d_ang < -PI: d_ang += 2.0 * PI
		var dir = 1.0 if d_ang >= 0 else -1.0
		var radial = clampf((block["r"] + 24.0 - od2) * 0.06, -0.35, 0.35)
		dx = (-oy / od2) * dir + (ox / od2) * radial
		dy = (ox / od2) * dir + (oy / od2) * radial
		d = Vector2(dx, dy).length()
	var fc = GameData.CLASSES[f["classId"]]
	var ms = f["ms"] * speed_mult
	ms *= ((1.0 - f["slowAmt"]) if f["slowT"] > 0 else 1.0)
	ms *= (f["buffs"]["ms"] if f["buffs"]["msT"] > 0 else 1.0)
	ms *= (0.45 if f["atkCommitT"] > 0 else 1.0)
	if f["hatChainT"] > 0 and fc.has("chainMS"): ms *= fc["chainMS"]
	var turn = min(1.0, (4.5 + fc["stats"]["SPD"] * 0.11) * dt)
	f["hx"] += (dx / d - f["hx"]) * turn
	f["hy"] += (dy / d - f["hy"]) * turn
	var hd = Vector2(f["hx"], f["hy"]).length()
	if hd == 0: hd = 1.0
	f["hx"] /= hd
	f["hy"] /= hd
	var align = max(0.35, (f["hx"] * dx + f["hy"] * dy) / d)
	var step = min(d, ms * align * dt)
	f["x"] += f["hx"] * step
	f["y"] += f["hy"] * step
	f["facing"] = 1 if f["hx"] >= 0 else -1

static func separation(state, f, dt) -> void:
	for a in state["fighters"]:
		if a["team"] != f["team"] or a["id"] == f["id"] or not a["alive"]: continue
		var d = Geom.dist(f, a)
		if d < GameData.SPREAD_DIST and d > 0.1:
			var push = (GameData.SPREAD_DIST - d) * 1.6 * dt
			f["x"] += ((f["x"] - a["x"]) / d) * push
			f["y"] += ((f["y"] - a["y"]) / d) * push
	for o in state["map"]["obstacles"]:
		var d2 = Vector2(f["x"] - o["x"], f["y"] - o["y"]).length()
		var mn = o["r"] + 14
		if d2 < mn and d2 > 0.1:
			f["x"] += ((f["x"] - o["x"]) / d2) * (mn - d2)
			f["y"] += ((f["y"] - o["y"]) / d2) * (mn - d2)
		elif d2 <= 0.1:
			f["x"] = o["x"] + mn
	for z in state["zones"]:
		if z["team"] == f["team"]: continue
		var d3 = Vector2(f["x"] - z["x"], f["y"] - z["y"]).length()
		if d3 < z["radius"] + 18 and d3 > 0.1:
			var pushz = 60.0 * dt
			f["x"] += ((f["x"] - z["x"]) / d3) * pushz
			f["y"] += ((f["y"] - z["y"]) / d3) * pushz
	Geom.clamp_arena(f)

# --- support routing ---
static func _fire_support(f, ab) -> void:
	f["cds"][ab["key"]] = ab["cd"] * (1.0 - f["cdr"])
	f["lastCastKey"] = ab["key"]

static func _echo(c, f) -> float:
	f["supportCasts"] += 1
	if c.has("echoEvery") and f["supportCasts"] % int(c["echoEvery"]) == 0:
		return c.get("echoPct", 0.5)
	return 0.0

static func solo_support_tick(state, f) -> bool:
	var c = GameData.CLASSES[f["classId"]]
	var enemy_near = false
	for e in state["fighters"]:
		if e["team"] != f["team"] and e["alive"] and Geom.dist(f, e) < 320:
			enemy_near = true
			break
	for ab in c["abilities"]:
		if f["cds"][ab["key"]] > 0: continue
		if ab["type"] == "allyheal" and f["hp"] / f["maxHP"] < 0.6:
			Combat.apply_heal(state, f, f, f["maxHP"] * ab["healPct"])
			_fire_support(f, ab)
			return true
		if ab["type"] == "teamheal" and f["hp"] / f["maxHP"] < 0.45:
			Combat.apply_heal(state, f, f, f["maxHP"] * ab["healPct"])
			if ab.get("cleanse", false):
				f["stun"] = 0.0
				f["slowT"] = 0.0
			_fire_support(f, ab)
			return true
		if ab["type"] == "allybuff":
			if ab.has("shieldPct"):
				if f["hp"] / f["maxHP"] < 0.85 and f["shield"] < f["maxHP"] * 0.05:
					Combat.apply_shield(state, f, f, f["maxHP"] * ab["shieldPct"], ab["dur"])
					_fire_support(f, ab)
					return true
			elif ab.has("buff") and enemy_near:
				var b = ab["buff"]
				if b.has("nextdmg"): f["buffs"]["nextdmg"] = b["nextdmg"]
				if b.has("crit"):
					f["buffs"]["crit"] = b["crit"]
					f["buffs"]["critT"] = b["dur"]
				if b.has("atkspd"):
					f["buffs"]["atkspd"] = b["atkspd"]
					f["buffs"]["atkspdT"] = b.get("dur", 2.2)
				_fire_support(f, ab)
				return true
	return false

static func support_tick(state, f, dt) -> bool:
	var c = GameData.CLASSES[f["classId"]]
	var allies = []
	for a in state["fighters"]:
		if a["team"] == f["team"] and a["alive"] and a["id"] != f["id"]:
			allies.append(a)
	if allies.is_empty(): return solo_support_tick(state, f)

	for ab in c["abilities"]:
		if f["cds"][ab["key"]] > 0: continue
		if ab["type"] == "allyheal":
			var low: Variant = null
			var low_frac = 1.0e9
			for a in allies:
				if a["hp"] / a["maxHP"] < 0.55 and Geom.has_los(state, f, a):
					var fr = a["hp"] / a["maxHP"]
					if fr < low_frac:
						low_frac = fr
						low = a
			if low != null:
				Combat.apply_heal(state, f, low, low["maxHP"] * ab["healPct"])
				var e = _echo(c, f)
				if e > 0: Combat.apply_heal(state, f, low, low["maxHP"] * ab["healPct"] * e)
				_fire_support(f, ab)
				return true
		if ab["type"] == "teamheal":
			var hurt = 0
			for a in allies:
				if a["hp"] / a["maxHP"] < 0.6: hurt += 1
			if hurt >= 2 or f["hp"] / f["maxHP"] < 0.4:
				var grp = allies.duplicate()
				grp.append(f)
				for a in grp:
					Combat.apply_heal(state, f, a, a["maxHP"] * ab["healPct"])
					if ab.get("cleanse", false):
						a["stun"] = 0.0
						a["slowT"] = 0.0
				_fire_support(f, ab)
				return true
		if ab["type"] == "allybuff":
			if ab.has("shieldPct"):
				var tgt: Variant = null
				var tfrac = 1.0e9
				for a in allies:
					if a["shield"] < a["maxHP"] * 0.05 and Geom.has_los(state, f, a):
						var fr = a["hp"] / a["maxHP"]
						if fr < tfrac:
							tfrac = fr
							tgt = a
				if tgt != null and tgt["hp"] / tgt["maxHP"] > 0.85: tgt = null
				if tgt != null:
					if ab.get("dashTo", false) and Geom.dist(f, tgt) > 90:
						step_toward(state, f, tgt["x"], tgt["y"], 0.18, 6.0)
					Combat.apply_shield(state, f, tgt, tgt["maxHP"] * ab["shieldPct"], ab["dur"])
					var e = _echo(c, f)
					if e > 0: Combat.apply_shield(state, f, tgt, tgt["maxHP"] * ab["shieldPct"] * e, ab["dur"])
					_fire_support(f, ab)
					return true
			elif ab.has("buff"):
				var tgt: Variant = null
				var best_pwr = -1
				for a in allies:
					var pwr = GameData.CLASSES[a["classId"]]["stats"]["PWR"]
					if pwr > best_pwr:
						best_pwr = pwr
						tgt = a
				if tgt != null:
					var b = ab["buff"]
					if b.has("nextdmg"): tgt["buffs"]["nextdmg"] = b["nextdmg"]
					if b.has("crit"):
						tgt["buffs"]["crit"] = b["crit"]
						tgt["buffs"]["critT"] = b["dur"]
					if b.has("atkspd"):
						tgt["buffs"]["atkspd"] = b["atkspd"]
						tgt["buffs"]["atkspdT"] = b.get("dur", 2.2)
					_echo(c, f)
					_fire_support(f, ab)
					return true
	return false
