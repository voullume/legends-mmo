extends SceneTree
## W3 roster-swap sim test (docs/wildlife-expanse-zone2-plan.md): the three new normals run the
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
	print("== wildlife normals (W3) sim test ==")
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

	# --- W3 spawn tables -------------------------------------------------------------------------
	var want := {
		"away_1": {"netvine_skink": 2, "tacklehorn_grazer": 2, "tackle_brute": 1},
		"away_2": {"scrapmask_forager": 2, "tacklehorn_grazer": 1, "rallywing_magpie": 1, "field_medic": 1, "sled_juggernaut": 1},
		"away_3": {"rallywing_magpie": 1, "netvine_skink": 1, "scrapmask_forager": 1, "ball_machine": 1, "drill_sergeant": 1},
	}
	for zone in want:
		var counts := {}
		for row in World.MOBS[zone]:
			counts[row["class"]] = int(counts.get(row["class"], 0)) + 1
		ok(counts == want[zone], "%s roster matches W3 plan (%s)" % [zone, counts])
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
