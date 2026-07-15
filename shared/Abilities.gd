extends RefCounted
## Ability execution — tryCast + execDashAttack (ports of the sim's offense/utility).
## Visual event-pushing is omitted (render-only; no effect on logic).

const GameData := preload("res://shared/GameData.gd")
const Combat := preload("res://shared/Combat.gd")
const Geom := preload("res://shared/Geom.gd")

static func _fire(f, ab, cd_mult) -> void:
	f["cds"][ab["key"]] = ab["cd"] * cd_mult
	f["lastCastKey"] = ab["key"]

# 8-skill expansion: THE shared on-hit rider resolution — one code path for stun / knockdown / slow /
# knockback / pull, used by immediate casts here AND cast-finish resolution in Sim (effect parity: an
# ability behaves identically whether or not it has a cast time). Field-gated → byte-identical no-op
# for every ability that doesn't carry the field. Call AFTER deal_damage (damage first, then riders).
static func apply_hit_riders(state, f, tgt, ab) -> void:
	if ab.has("stun"):
		tgt["stun"] = max(tgt["stun"], ab["stun"])
	if ab.has("knockdown"):
		tgt["stun"] = max(tgt["stun"], ab["knockdown"])
	if ab.has("slow"):
		tgt["slowT"] = ab["slow"]["dur"]
		tgt["slowAmt"] = ab["slow"]["amt"]
	if ab.has("knockback") and not Combat.kb_immune(tgt):
		var kx = tgt["x"] - f["x"]
		var ky = tgt["y"] - f["y"]
		var kd = Vector2(kx, ky).length()
		if kd == 0: kd = 1.0
		tgt["x"] += (kx / kd) * ab["knockback"]
		tgt["y"] += (ky / kd) * ab["knockback"]
		Geom.clamp_arena(tgt)
	if ab.has("pull") and not Combat.kb_immune(tgt):     # P5: yank toward the caster (off cover)
		var pd = Vector2(f["x"] - tgt["x"], f["y"] - tgt["y"]).length()
		var pamt = minf(float(ab["pull"]), pd - 30.0)
		if pamt > 0.0:
			tgt["x"] += ((f["x"] - tgt["x"]) / pd) * pamt
			tgt["y"] += ((f["y"] - tgt["y"]) / pd) * pamt
			Geom.clamp_arena(tgt)

# a dash's optional follow-up selfBuff (Scramble's DR, Approach's speed burst) — applied after the
# movement itself succeeded, both for the AI dash here and the directional player dash in Sim.
static func apply_move_buff(f, ab) -> void:
	if ab.has("selfBuff"):
		Combat.apply_buff_dict(f, ab["selfBuff"])

static func _nearest_enemy(state, f) -> Variant:
	var best: Variant = null
	var bd = INF
	for e in state["fighters"]:
		if Combat.is_hostile(state, f, e) and e["alive"]:
			var dd = Geom.dist(f, e)
			if dd < bd:
				bd = dd
				best = e
	return best

static func _enemy_within(state, f, r) -> bool:
	for e in state["fighters"]:
		if Combat.is_hostile(state, f, e) and e["alive"] and Geom.dist(f, e) < r:
			return true
	return false

static func try_cast(state, f, ab, target) -> bool:
	var c = GameData.CLASSES[f["classId"]]
	var cd_mult = (1.0 - f["cdr"]) / (f["buffs"]["atkspd"] if (f["buffs"]["atkspdT"] > 0 and ab.get("basic", false)) else 1.0)

	match ab["type"]:
		"projectile":
			if Geom.dist(f, target) > ab["range"]:
				return false
			if not Geom.has_los(state, f, target):
				return false
			if ab.has("cast"):
				# casted projectile (e.g. Golden Goal): the shot spawns ONLY at cast completion — Sim's
				# cast-finish branch re-checks life/hostility/range/LOS and a stun interrupt prevents the
				# spawn entirely. The cooldown is spent NOW, with the cast (interrupt = the cd is lost).
				f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "targetId": target["id"], "ab": ab}
				_fire(f, ab, cd_mult)
				return true
			f["atkCommitT"] = 0.35
			state["projectiles"].append(make_projectile(state, f, target, ab))
			_fire(f, ab, cd_mult)
			return true
		"barrage":
			if Geom.dist(f, target) > ab["range"]:
				return false
			for i in int(ab["count"]):
				state["projectiles"].append({
					"x": f["x"], "y": f["y"], "tx": target["id"], "speed": ab["speed"], "dmg": ab["dmg"],
					"team": f["team"], "owner": f["id"], "key": ab["key"], "born": state["t"],
					"delay": i * 0.22, "basic": false, "stun": null, "slow": null, "teamShieldPct": null,
				})
			_fire(f, ab, cd_mult)
			return true
		"melee":
			if Geom.dist(f, target) > ab["range"]:
				return false
			# AI-only prioritization (Strip Ball): a bot doesn't burn a dispel melee on a target with nothing
			# to strip — it falls through to its next ability. A human's press (controlled) always resolves.
			if ab.has("dispelBuffs") and not state.get("controlled", {}).has(f["id"]) and not Combat.has_dispellable(target):
				return false
			if ab.has("cast"):
				f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "targetId": target["id"], "ab": ab}
				_fire(f, ab, cd_mult)
				return true
			Combat.deal_damage(state, f, target, ab["dmg"], {"melee": true, "basic": ab.get("basic", false), "key": ab["key"]})
			apply_hit_riders(state, f, target, ab)
			if c.has("momentumGain"):
				f["momentum"] = min(c["momentumMax"], f["momentum"] + 1)
				f["momentumT"] = 4.0
			_fire(f, ab, cd_mult)
			return true
		"meleeAoe":
			var in_r = []
			for e in state["fighters"]:
				if Combat.is_hostile(state, f, e) and e["alive"] and Geom.dist(f, e) < ab["radius"]:
					in_r.append(e)
			if in_r.is_empty():
				return false
			if ab.has("cast"):
				f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "ab": ab}
				_fire(f, ab, cd_mult)
				return true
			for e in in_r:
				Combat.deal_damage(state, f, e, ab["dmg"], {"melee": true, "key": ab["key"]})
				apply_hit_riders(state, f, e, ab)     # parity with cast-finish (stun/slow/knockback/pull)
			_fire(f, ab, cd_mult)
			return true
		"dashAttack":
			if not Geom.has_los(state, f, target):
				return false
			if Geom.dist(f, target) > ab["dist"] + 40:
				return false
			if ab.has("cast"):
				f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "targetId": target["id"], "ab": ab}
				_fire(f, ab, cd_mult)
				return true
			exec_dash_attack(state, f, target, ab)
			_fire(f, ab, cd_mult)
			return true
		"leapAttack":
			if not Geom.has_los(state, f, target):
				return false
			if Geom.dist(f, target) > ab["dist"] + 30:
				return false
			if ab.has("untargetable"):
				f["untarget"] = ab["untargetable"]
			f["x"] = target["x"] + (state["rng"].next() - 0.5) * 30.0
			f["y"] = target["y"] + (state["rng"].next() - 0.5) * 30.0
			Geom.clamp_arena(f)
			if ab.has("cast"):
				f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "targetId": target["id"], "ab": ab}
				_fire(f, ab, cd_mult)
				return true
			Combat.deal_damage(state, f, target, ab["dmg"], {"melee": true, "airborne": ab.get("airborne", false), "key": ab["key"]})
			apply_hit_riders(state, f, target, ab)     # parity with cast-finish
			_fire(f, ab, cd_mult)
			return true
		"dash":
			if ab.get("gapClose", false) and target != null and Geom.dist(f, target) > 110 and (state["t"] > 4 or target["hp"] / target["maxHP"] < 0.9):
				var gx = target["x"] - f["x"]
				var gy = target["y"] - f["y"]
				var gd = Vector2(gx, gy).length()
				if gd == 0: gd = 1.0
				f["x"] += (gx / gd) * min(ab["dist"], gd - 40)
				f["y"] += (gy / gd) * min(ab["dist"], gd - 40)
				Geom.clamp_arena(f)
				if ab.has("evade"): f["evade"] = ab["evade"]
				apply_move_buff(f, ab)
				_fire(f, ab, cd_mult)
				return true
			var near = _nearest_enemy(state, f)
			if near == null or Geom.dist(f, near) > 110:
				return false
			var dx = f["x"] - near["x"]
			var dy = f["y"] - near["y"]
			var dd = Vector2(dx, dy).length()
			if dd == 0: dd = 1.0
			f["x"] += (dx / dd) * ab["dist"]
			f["y"] += (dy / dd) * ab["dist"]
			Geom.clamp_arena(f)
			if ab.has("evade"): f["evade"] = ab["evade"]
			apply_move_buff(f, ab)
			_fire(f, ab, cd_mult)
			return true
		"selfbuff":
			var b = ab["buff"]
			var pressured = _enemy_within(state, f, 160.0)
			if (b.has("dr") or b.has("reflect")) and not pressured and f["hp"] / f["maxHP"] > 0.6:
				return false
			# escape/reposition stances (Mound Presence, Claim the Cross, Goal-Line Stand) are pressure
			# tools, not chase buffs: the AI only casts an aiPressure ability with an enemy actually near.
			if ab.get("aiPressure", false) and not pressured:
				return false
			Combat.apply_buff_dict(f, b)
			_fire(f, ab, cd_mult)
			return true
		"zone":
			if not Geom.has_los(state, f, target):
				return false
			var zd := {"x": target["x"], "y": target["y"], "radius": ab["radius"], "team": f["team"], "owner": f["id"], "t": ab["dur"]}
			if ab.has("dmg"): zd["dmg"] = ab["dmg"]          # hazard zone: per-second DOT to hostiles inside
			if ab.has("slow"): zd["slow"] = ab["slow"]       # hazard zone: slow hostiles inside
			state["zones"].append(zd)
			_fire(f, ab, cd_mult)
			return true
		"summon":
			# Request adds from the SERVER (post-tick bridge): the sim only EMITS the event (draws zero rng),
			# the server spawns + caps + tags them. Gated on a nearby hostile so an idle camp doesn't summon.
			# Spawns around the summoner (f.x/y) so adds emerge from it and chase.
			if not _enemy_within(state, f, 460.0):
				return false
			state["events"].append({"type": "summon", "owner": f["id"], "mobType": str(ab["mobType"]),
				"count": int(ab.get("count", 1)), "x": f["x"], "y": f["y"], "t": state["t"]})
			_fire(f, ab, cd_mult)
			return true
		"barrier":
			var pressured = _enemy_within(state, f, 180.0)
			if not pressured or f["hp"] / f["maxHP"] > 0.55:
				return false
			f["barrier"] = ab["dr"]
			f["barrierT"] = ab["dur"]
			f["barrierStored"] = 0.0
			f["_barrierAb"] = ab
			_fire(f, ab, cd_mult)
			return true
		"campreset":
			# Boss ult (Full Camp Reset) — just OPEN a long telegraph cast; the boss freezes while casting
			# (the Sim casting block holds position) so the LOS spare-set is stable. The arena-wide AoE +
			# cover-spare + power-core gate all resolve in Sim's cast-finish branch. Zero rng here.
			if not _enemy_within(state, f, 1400.0):
				return false
			f["casting"] = {"key": ab["key"], "t": 0.0, "total": ab["cast"], "ab": ab}
			_fire(f, ab, cd_mult)
			return true
		"spread":
			# P5 — fire a FAN of direction-mode projectiles (count over arc radians). `bounces` makes them
			# RICOCHET off cover walls. Fixed angles → zero rng. Aims at the target's current position.
			if Geom.dist(f, target) > ab["range"]:
				return false
			if not Geom.has_los(state, f, target):
				return false
			var aim := atan2(target["y"] - f["y"], target["x"] - f["x"])
			var n := int(ab.get("count", 3))
			var arc := float(ab.get("arc", 0.5))
			for i in n:
				var frac := (float(i) / float(maxi(1, n - 1)) - 0.5) if n > 1 else 0.0
				var ang := aim + frac * arc
				state["projectiles"].append({
					"x": f["x"], "y": f["y"], "dx": cos(ang), "dy": sin(ang), "speed": ab["speed"], "dmg": ab["dmg"],
					"team": f["team"], "owner": f["id"], "key": ab["key"], "basic": false,
					"stun": ab.get("stun", null), "wobble": ab.get("wobble", null), "bounces": int(ab.get("bounces", 0)),
					"born": state["t"], "delay": 0.0,
				})
			_fire(f, ab, cd_mult)
			return true
	return false

static func exec_dash_attack(state, f, target, ab) -> void:
	# BAIT-INTO-WALL (P5): a charge with `wallStun` whose target juked behind cover during the telegraph
	# (a wall now blocks LOS) CRASHES — the mob lunges partway toward the wall, eats a self-stun, no hit.
	# (the lunge only clamps to the arena; AI.separation shoves it back outside the wall on the next tick.)
	if ab.has("wallStun") and not Geom.has_los(state, f, target):
		var bd0 = Vector2(target["x"] - f["x"], target["y"] - f["y"]).length()
		if bd0 == 0: bd0 = 1.0
		f["x"] += ((target["x"] - f["x"]) / bd0) * (float(ab["dist"]) * 0.5)
		f["y"] += ((target["y"] - f["y"]) / bd0) * (float(ab["dist"]) * 0.5)
		Geom.clamp_arena(f)
		f["stun"] = max(f["stun"], float(ab["wallStun"]))
		return
	var dx = target["x"] - f["x"]
	var dy = target["y"] - f["y"]
	var d = Vector2(dx, dy).length()
	if d == 0: d = 1.0
	var step = min(d - 30, ab["dist"])
	if step > 0:
		f["x"] += (dx / d) * step
		f["y"] += (dy / d) * step
		Geom.clamp_arena(f)
	if Geom.dist(f, target) < 70:
		Combat.deal_damage(state, f, target, ab["dmg"], {"melee": true, "key": ab["key"]})
		apply_hit_riders(state, f, target, ab)
		var fc = GameData.CLASSES[f["classId"]]
		if fc.has("momentumGain"):
			f["momentum"] = min(fc["momentumMax"], f["momentum"] + 1)
			f["momentumT"] = 4.0

# homing-projectile dict for `ab` fired by `f` at `target` — ONE construction site shared by the
# immediate path above and Sim's cast-finish spawn (casted projectiles), so both carry identical riders.
static func make_projectile(state, f, target, ab) -> Dictionary:
	return {
		"x": f["x"], "y": f["y"], "tx": target["id"], "speed": ab["speed"], "dmg": ab["dmg"],
		"team": f["team"], "owner": f["id"], "key": ab["key"], "basic": ab.get("basic", false),
		"stun": ab.get("stun", null), "slow": ab.get("slow", null), "wobble": ab.get("wobble", null), "born": state["t"],
		"teamShieldPct": ab.get("teamShieldPct", null), "delay": 0.0,
	}
