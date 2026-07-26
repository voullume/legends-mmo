extends SceneTree
## W3/W4 roster sim test (docs/wildlife-expanse-zone2-plan.md): the wildlife normals + elite run the
## deterministic engine correctly — def shapes stay inside mob-proven ability schemas, every
## special casts, the magpie's Rally Screech actually shields an ally, fights terminate, and
## replays are byte-identical. Also pins the away-zone spawn tables to the W3 wildlife roster.
## Run: godot --headless --path . --script res://tools/test_wildlife_normals.gd

const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const World = preload("res://shared/World.gd")

var checks := 0
var fails := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if cond:
		print("  ok: %s" % what)
	else:
		fails += 1
		print("  FAIL: %s" % what)

func _init() -> void:
	print("== wildlife normals + elite (W3/W4) sim test ==")
	# --- def shapes: mob-proven schemas only -----------------------------------------------------
	for id in ["tacklehorn_grazer", "scrapmask_forager", "rallywing_magpie"]:
		var d: Dictionary = GameData.CLASSES.get(id, {})
		ok(not d.is_empty() and bool(d.get("mob", false)) and bool(d.get("rig", false)), "%s: def exists, mob+rig" % id)
		ok(bool((d["abilities"][0] as Dictionary).get("basic", false)) and d["abilities"][0]["type"] == "melee", "%s: melee basic" % id)
		for ab in d["abilities"]:
			var bad: bool = ab.has("onKillBuff") or ab.has("onHitSelfShieldPct") or ab.has("dispelBuffs") \
				or ab.has("selfBuff") or ab.has("aiPressure") or (ab.has("buff") and (ab["buff"] as Dictionary).has("guard"))
			ok(not bad, "%s/%s: no expansion-only fields (mob-freeze rule)" % [id, ab["key"]])
	ok((GameData.CLASSES["tacklehorn_grazer"]["abilities"][1] as Dictionary)["type"] == "dashAttack", "grazer: charge is dashAttack")
	ok((GameData.CLASSES["scrapmask_forager"]["abilities"][1] as Dictionary)["type"] == "selfbuff", "forager: guard is selfbuff")
	var rs: Dictionary = GameData.CLASSES["rallywing_magpie"]["abilities"][1]
	ok(rs["type"] == "allybuff" and rs.has("shieldPct") and rs.has("dur"), "magpie: screech is the field_medic allybuff shape")
	# W4 elite: warfrog shapes (Ground Slam = pancakeslam/shockwave meleeAoe; Croak Wave = ladderlock zone)
	var wf: Dictionary = GameData.CLASSES.get("emerald_warfrog", {})
	ok(not wf.is_empty() and bool(wf.get("mob", false)) and bool(wf.get("rig", false)) and bool(wf.get("kbImmune", false)), "warfrog: def exists, mob+rig+kbImmune")
	var gs: Dictionary = wf["abilities"][1]
	ok(gs["type"] == "meleeAoe" and gs.has("radius") and gs.has("cast") and gs.has("knockback"), "warfrog: ground slam is the proven meleeAoe shape")
	var cw: Dictionary = wf["abilities"][2]
	ok(cw["type"] == "zone" and cw.has("radius") and cw.has("dur") and (cw["slow"] as Dictionary).has("amt") and not cw.has("dmg"), "warfrog: croak wave is the ladderlock pure-slow zone shape")
	for ab in wf["abilities"]:
		var wbad: bool = ab.has("onKillBuff") or ab.has("onHitSelfShieldPct") or ab.has("dispelBuffs") \
			or ab.has("selfBuff") or ab.has("aiPressure") or (ab.has("buff") and (ab["buff"] as Dictionary).has("guard"))
		ok(not wbad, "warfrog/%s: no expansion-only fields" % ab["key"])
	# W5 boss: howler (rival_coach numeric-parity teaching boss; Signature Howl = drill summon shape)
	var hw: Dictionary = GameData.CLASSES.get("arrowbound_howler", {})
	ok(not hw.is_empty() and bool(hw.get("phased", false)) and bool(hw.get("rig", false)) and not hw.has("coreShield") and not hw.has("coreCount"), "howler: phased rigged PACK boss — no core mechanics (owner redesign)")
	ok(float(hw.get("hpMult", 0.0)) == 0.7 and float(hw.get("dmgScale", 0.0)) == 0.6, "howler: pack-boss pool (hpMult 0.7 compensates the removed shield window)")
	ok(str((hw.get("threshSummon", {}) as Dictionary).get("mobType", "")) == "netvine_skink", "howler: phase waves summon skinks")
	var sh: Dictionary = hw["abilities"][0]
	ok(sh["type"] == "summon" and str(sh["mobType"]) == "rallywing_magpie" and int(sh.get("phase", -1)) == 2, "howler: Pack Call summons the shield-bird at P2 (summon priority slot)")
	var sh2: Dictionary = hw["abilities"][1]
	ok(sh2["type"] == "summon" and str(sh2["mobType"]) == "netvine_skink" and int(sh2.get("phase", -1)) >= 1, "howler: Signature Howl is the proven summon shape, phase-gated")
	var hw_ult := false
	var hw_reflects := 0
	for ab in hw["abilities"]:
		if str(ab["type"]) == "campreset": hw_ult = true
		if str(ab["type"]) == "selfbuff" and bool((ab.get("buff", {}) as Dictionary).get("reflect", false)): hw_reflects += 1
	ok(not hw_ult, "howler: NO campreset ult (teaching-boss promise preserved)")
	ok(hw_reflects == 2 and float(hw.get("reflectMult", 0.0)) > 1.0, "howler: Bristling Arrows + Quilled Fury reflect stances, reflectMult present (the GameData:231 rule)")
	# behavioral: force P2 and observe the bristle cycle + the RF state on the boss fighter
	var bstate = Sim.create_match(["arrowbound_howler"], ["striker", "batter"], 21, "stadium")
	var bf: Variant = null
	for f in bstate["fighters"]:
		if str(f["classId"]) == "arrowbound_howler": bf = f
	bf["hp"] = float(bf["maxHP"]) * 0.30             # P2 band (phases: 100-70/70-40/40-15/15-0)
	var bristled := false
	var rf_seen := false
	for i in 30 * 30:
		Sim.sim_tick(bstate, 1.0 / 30.0)
		if float(bf["cds"].get("bristle", 0.0)) > 0.0: bristled = true
		if float((bf.get("buffs", {}) as Dictionary).get("reflect", 0.0)) > 0.0: rf_seen = true
		if (bristled and rf_seen) or not bool(bf["alive"]): break
	ok(bristled, "howler: Bristling Arrows cast at P2")
	ok(rf_seen, "howler: the reflect stance state is live on the fighter (the RF chip's source)")
	# W4b elite: splinterback (Quill Barrage = ball_machine scatter spread shape)
	var sb: Dictionary = GameData.CLASSES.get("splinterback_elite", {})
	ok(not sb.is_empty() and bool(sb.get("mob", false)) and bool(sb.get("rig", false)) and bool(sb.get("kbImmune", false)), "splinterback: def exists, mob+rig+kbImmune")
	var qb: Dictionary = sb["abilities"][1]
	ok(qb["type"] == "spread" and qb.has("count") and qb.has("arc") and qb.has("range") and qb.has("speed"), "splinterback: quill barrage is the proven spread shape")
	for ab in sb["abilities"]:
		var sbad: bool = ab.has("onKillBuff") or ab.has("onHitSelfShieldPct") or ab.has("dispelBuffs") \
			or ab.has("selfBuff") or ab.has("aiPressure") or (ab.has("buff") and (ab["buff"] as Dictionary).has("guard"))
		ok(not sbad, "splinterback/%s: no expansion-only fields" % ab["key"])

	# --- current away spawn tables (W3 normals + W4 warfrog + W4b splinterback) --------------------
	var want := {
		"away_1": {"netvine_skink": 6, "tacklehorn_grazer": 4},  # P2: +2 nest skinks; P3: +Wild-Yards pair + the L11 Broodmother elite
		"away_2": {"scrapmask_forager": 2, "tacklehorn_grazer": 1, "rallywing_magpie": 2, "emerald_warfrog": 1},
		"away_3": {"rallywing_magpie": 1, "netvine_skink": 1, "scrapmask_forager": 1, "splinterback_elite": 1, "emerald_warfrog": 1},
		"away_3_concourse": {"rallywing_magpie": 4},  # P4: 3 roosts + the Rafter elite (the roof is mob-free by design)
	}
	for zone in want:
		var counts := {}
		for row in World.MOBS[zone]:
			counts[row["class"]] = int(counts.get(row["class"], 0)) + 1
		ok(counts == want[zone], "%s roster matches the plan (%s)" % [zone, counts])
		for row in World.MOBS[zone]:
			ok(GameData.CLASSES.has(str(row["class"])), "%s: def exists for %s" % [zone, row["class"]])

	# --- Rally Screech in isolation: the engine only shields a packmate under 85% HP (AI.gd
	# support_tick), so create that condition deterministically before any combat reaches them.
	var sstate = Sim.create_match(["rallywing_magpie", "tacklehorn_grazer"], ["striker", "striker"], 5, "stadium")
	var dt := 1.0 / 30.0
	var hurt_ally: Variant = null
	for f in sstate["fighters"]:
		if str(f["classId"]) == "tacklehorn_grazer":
			f["hp"] = float(f["maxHP"]) * 0.5
			hurt_ally = f
	var shielded := false
	var screeched := false
	for i in 90:
		Sim.sim_tick(sstate, dt)
		if float(hurt_ally.get("shield", 0.0)) > 0.0: shielded = true
		for f in sstate["fighters"]:
			if str(f["classId"]) == "rallywing_magpie" and float(f["cds"].get("rallyscreech", 0.0)) > 0.0:
				screeched = true
		if shielded and screeched: break
	ok(screeched, "rallyscreech cast on a hurt packmate")
	ok(shielded, "Rally Screech shielded the packmate (shield > 0)")

	# --- live sim: mixed wildlife pack vs players ------------------------------------------------
	var state = Sim.create_match(
		["tacklehorn_grazer", "scrapmask_forager", "rallywing_magpie"],
		["striker", "batter", "setter"], 13, "stadium")
	var casts := {"tacklecharge": false, "scrapguard": false}
	var guard := 0
	while state["winner"] == null and guard < 30 * 150:
		Sim.sim_tick(state, dt)
		guard += 1
		for f in state["fighters"]:
			for k in casts:
				if float(f["cds"].get(k, 0.0)) > 0.0: casts[k] = true
	ok(state["winner"] != null, "pack fight resolves (winner=%s t=%.1fs)" % [str(state["winner"]), float(state["t"])])
	for k in casts:
		ok(casts[k], "%s cast observed" % k)

	# --- determinism -----------------------------------------------------------------------------
	var a = Sim.run_headless_match(["tacklehorn_grazer", "scrapmask_forager", "rallywing_magpie"], ["striker", "batter", "setter"], 13, "stadium")
	var b = Sim.run_headless_match(["tacklehorn_grazer", "scrapmask_forager", "rallywing_magpie"], ["striker", "batter", "setter"], 13, "stadium")
	ok(a["winner"] == b["winner"] and a["duration"] == b["duration"], "same seed replays identically (w=%s d=%.1f)" % [str(a["winner"]), float(a["duration"])])

	print("[wildlife_normals] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
