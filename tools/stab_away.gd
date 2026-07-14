extends "res://tools/stab/stab_base.gd"
## Phase 8 S1 — THE AWAY CIRCUIT (away_1/away_2) invariants, against the REAL server (headless, no net):
##   • both zones auto-boot as static worlds with exactly the planned camps (classes/tiers/levels);
##   • the HOME "▶ Away Games" pad is VISIBLE-but-locked below level 8 (not hidden), refuses the teleport,
##     and explains itself via the generalized gate prompt; a level-8 character walks straight through;
##   • portal round-trips: HOME → away_1 → away_2 → back → back → HOME (real _check_portals walk);
##   • NO dangling pads: every away portal's destination world exists (S2's away_3 pad is withheld);
##   • quests: away1_roadgame accepts at level 8 with NO prereq (the desert un-gating fix), progresses on
##     an away_1 kill through the REAL award path, which also pays Practice Tokens (the Phase-8 extension);
##   • bounty pool: the away rows exist and match away-zone kills;
##   • XP-band numeric pass (plan §hardening 3): the S1 directed path (quest XP + required-kill XP with the
##     real curve/con/tier formulas) covers the 8→13 band without starving or wildly overshooting, and
##     away_1's sub-chain hands off INTO away_2's con-grace band.
## Run: godot --headless --path . --script res://tools/stab_away.gd

const Quests := preload("res://shared/Quests.gd")

func _init() -> void:
	_run()

func _mobs_in(map: String) -> Array:
	var out := []
	for f in srv._worlds[map]["fighters"]:
		if int(f["team"]) == 1:
			out.append(f)
	return out

func _walk(pid: int, pad_x: float, pad_y: float) -> void:   # stand on a pad and let the REAL portal check fire
	var f = srv._find(srv._session[pid]["fid"])
	f["x"] = pad_x
	f["y"] = pad_y
	srv._tp_next.erase(f["id"])                               # clear the teleport grace between hops
	srv._check_portals()

func _run() -> void:
	await boot()

	# ---- 1. zone boot: worlds + camps exactly as planned ----
	ok(srv._worlds.has("away_1") and srv._worlds.has("away_2"), "boot: away_1 + away_2 auto-boot as static worlds")
	var m1 := _mobs_in("away_1")
	var m2 := _mobs_in("away_2")
	ok(m1.size() == 5, "away_1: 5 spawns (got %d)" % m1.size())
	ok(m2.size() == 6, "away_2: 6 spawns (got %d)" % m2.size())
	var c1 := {}
	for f in m1: c1[str(f["classId"])] = c1.get(str(f["classId"]), 0) + 1
	ok(int(c1.get("rally_cone", 0)) == 2 and int(c1.get("foam_dummy", 0)) == 1 and int(c1.get("tire_dummy", 0)) == 1
		and int(c1.get("tackle_brute", 0)) == 1, "away_1 roster: 2×rally_cone + foam + tire + tackle_brute")
	var elites2 := 0
	for f in m2:
		if str(f.get("mobTier", "")) == "elite": elites2 += 1
	ok(elites2 == 2, "away_2: exactly 2 elites (medic + sled)")
	for f in m1 + m2:
		ok(GameData.CLASSES.has(str(f["classId"])), "def exists: %s" % f["classId"])
		if not GameData.CLASSES.has(str(f["classId"])): break

	# ---- 2. the gate: visible-but-locked under 8, explained, then open at 8 ----
	var lowbie: Dictionary = await login("Rook", 1)                       # level 1
	var pads: Array = srv._portals_for_player("home", 1)
	var seen_away := false
	for p in pads:
		if str(p["label"]) == "▶ Away Games": seen_away = true
	ok(seen_away, "gate: the Away Games pad is VISIBLE while locked (not a hidden gate)")
	ok(not srv._portal_unlocked(1, "away_gate"), "gate: level 1 is locked out")
	_walk(1, 300.0, 200.0)                                                # stand on the pad
	ok(str(srv._session[1]["map"]) == "home", "gate: locked walk-on does NOT teleport")
	var prompts: Array = fnet.calls("recv_chat", 1)
	var explained := false
	for c in prompts:
		if str(c["args"][1]).contains("Away Games") and str(c["args"][1]).contains("level 8"): explained = true
	ok(explained, "gate: the sealed pad explains itself (generalized prompt)")

	var vet: Dictionary = await login("Traveler", 2, {"level": 9})
	ok(srv._portal_unlocked(2, "away_gate"), "gate: level 9 unlocks away_gate")

	# ---- 3. real portal walk: HOME → away_1 → away_2 → away_1 → HOME ----
	_walk(2, 300.0, 200.0)
	ok(str(srv._session[2]["map"]) == "away_1", "walk: HOME pad → away_1")
	_walk(2, 1620.0, 475.0)
	ok(str(srv._session[2]["map"]) == "away_2", "walk: away_1 forward pad → away_2")
	_walk(2, 120.0, 500.0)
	ok(str(srv._session[2]["map"]) == "away_1", "walk: away_2 back pad → away_1")
	var f2 = srv._find(vet["fid"])
	ok(Vector2(f2["x"] - 1500.0, f2["y"] - 475.0).length() > 320.0, "walk: the back-drop lands > AGGRO 320 from away_1's elite")
	_walk(2, 120.0, 475.0)
	ok(str(srv._session[2]["map"]) == "home", "walk: away_1 back pad → HOME")

	# ---- 4. no dangling pads: every away destination world exists ----
	var dangling := 0
	for mp in ["away_1", "away_2"]:
		for p in World.PORTALS.get(mp, []):
			if p.has("to") and not srv._worlds.has(str(p["to"])): dangling += 1
	ok(dangling == 0, "pads: no away portal targets a missing world (away_3 pad correctly withheld)")

	# ---- 5. quests: prereq-free accept at 8+, progress + tokens through the REAL kill-award path ----
	var q = Quests.get_quest("away1_roadgame")
	ok(q != null and str(q["prereq"]) == "" and int(q["min_level"]) == 8, "quest: away1_roadgame is prereq-FREE at min_level 8 (the desert fix)")
	ok(Quests.AWAY_ORDER.size() == 4 and Quests.display_order().size() == Quests.ORDER.size() + 4 + Quests.MIDGAME_ORDER.size(),
		"quest: AWAY_ORDER wired into display_order (and NOT into the secret-gate ORDER)")
	ok(Quests.ORDER.size() == 9, "quest: the secret-boss gate list is untouched (9)")
	await srv._do_quest_accept(2, "away1_roadgame")
	await settle()
	ok((srv._session[2]["quests"] as Dictionary).has("away1_roadgame"), "quest: accepted at level 9")
	# kill a rally_cone in away_1 via the REAL award path (event → _award_kills)
	_walk(2, 300.0, 200.0)                                    # back into away_1 (fighter must be in-zone for credit)
	var target = null
	for f in _mobs_in("away_1"):
		if str(f["classId"]) == "rally_cone": target = f; break
	var tokens0 := int(srv._session[2].get("tokens", 0))
	var xp0 := int(srv._session[2].get("xp", 0))
	srv._worlds["away_1"]["events"].append({"type": "kill", "victim": target["id"], "killer": vet["fid"]})
	srv._award_kills()
	srv._worlds["away_1"]["events"].clear()
	await settle()
	ok(int((srv._session[2]["quests"]["away1_roadgame"] as Dictionary).get("progress", 0)) == 1, "quest: an away_1 kill advances the objective")
	ok(int(srv._session[2].get("tokens", 0)) > tokens0, "tokens: the away kill pays Practice Tokens (Phase-8 extension)")
	ok(int(srv._session[2].get("xp", 0)) > xp0, "xp: the away kill pays con-scaled XP")

	# ---- 6. bounty pool: the away rows exist + match ----
	ok(srv.BOUNTY_DAILY.has("d_roadgame") and srv.BOUNTY_DAILY.has("d_gauntlet"), "bounty: away daily rows exist")
	ok(Quests.kill_matches({"objective": {"type": "kill", "match": srv.BOUNTY_DAILY["d_roadgame"]["match"], "count": 1}},
		{"tier": "minion", "map": "away_1", "class": "rally_cone", "level": 9}), "bounty: d_roadgame matches an away_1 kill")

	# ---- 7. XP-band numeric pass (plan §hardening 3) — real formulas, computed not asserted ----
	var band := 0                                             # XP needed for 8→13
	for L in range(8, 13):
		band += srv._xp_to_next(L)
	var quest_xp := 0
	for qid in Quests.AWAY_ORDER:
		quest_xp += int(Quests.get_quest(qid)["rewards"].get("xp", 0))
	# required-kill XP along the chain (killer stays inside con grace throughout — verified below)
	var kill_xp := 0
	kill_xp += 12 * srv.MOB_XP_BASE * 9                       # away1_roadgame: 12 minion kills @ ~lvl 9
	kill_xp += srv.MOB_XP_BASE * 10 * srv.MOB_ELITE_XP        # away1_blocker: the lvl-10 elite
	kill_xp += 15 * srv.MOB_XP_BASE * 12                      # away2_gauntlet: 15 minion kills @ ~lvl 12
	kill_xp += srv.MOB_XP_BASE * 12 * srv.MOB_ELITE_XP + srv.MOB_XP_BASE * 13 * srv.MOB_ELITE_XP   # away2_medics: both elites
	var directed := quest_xp + kill_xp
	var ratio := float(directed) / float(band)
	ok(ratio >= 0.9 and ratio <= 1.6,
		"xp: the directed S1 path covers the 8→13 band sanely (%.0f%% of %d XP — no starvation, no wild overshoot)" % [ratio * 100.0, band])
	# away_1's sub-chain (quests 1-2: 420+520 quest XP + 12 lvl-9 minions + the lvl-10 elite) must hand the
	# player off INSIDE away_2's 12-13 con-grace band
	var a1: int = 420 + 520 + 12 * srv.MOB_XP_BASE * 9 + srv.MOB_XP_BASE * 10 * srv.MOB_ELITE_XP
	var lvl := 8
	var pool: int = a1
	while pool >= srv._xp_to_next(lvl):
		pool -= srv._xp_to_next(lvl)
		lvl += 1
	ok(lvl >= 9 and lvl <= 12, "xp: away_1's sub-chain exits at L%d — inside away_2's 12-13 grace band (8..17)" % lvl)
	# con sanity: a level-9 killer takes FULL xp from lvl-9 away_1 mobs; a 30 takes the floor (still farmable)
	ok(is_equal_approx(srv._con_mult(9, 9), 1.0) and is_equal_approx(srv._con_mult(30, 9), srv.XP_CON_FLOOR),
		"xp: con grace full at-level, floor when trivial")

	# ---- 8. away_gate never gates on AWAY_ORDER completion (the governance rule, executable form) ----
	ok(srv._portal_unlocked(2, "away_gate"), "governance: away_gate is level-only — no quest-list coupling")

	# ---- 9. LOGIN RESTORE re-validation (adversarial-review find): a tampered client-writable last_map
	# into EITHER away zone must relocate a sub-8 character HOME — this is the surface the walk-on gate
	# never touches. gate_for_map derives it from inbound pads, so the interior pad must carry the gate too.
	ok(World.gate_for_map("away_1") == "away_gate", "restore: away_1 derives its login gate from the HOME pad")
	ok(World.gate_for_map("away_2") == "away_gate", "restore: away_2 derives its login gate from the interior pad (the bypass fix)")
	var t1: Dictionary = await login("Tamper8a", 7, {"level": 1, "last_map": "away_1"})
	ok(str(srv._session[7]["map"]) == "home", "restore: sub-8 tampered last_map=away_1 lands at HOME")
	srv.drop_peer(7)
	await settle()
	var t2: Dictionary = await login("Tamper8b", 8, {"level": 1, "last_map": "away_2"})
	ok(str(srv._session[8]["map"]) == "home", "restore: sub-8 tampered last_map=away_2 lands at HOME (no interior bypass)")
	srv.drop_peer(8)
	await settle()
	var legit: Dictionary = await login("Legit", 11, {"level": 9, "last_map": "away_2"})
	ok(str(srv._session[11]["map"]) == "away_2", "restore: a LEGIT level-9 character still resumes inside away_2")
	srv.drop_peer(11)
	await settle()

	# ---- 10. camp-geometry pins (adversarial-review find): the healer-camp lesson is a JOINT pull —
	# the medic must sit strictly inside its lane camp's aggro circle, not on the ==320 boundary.
	var medic = null
	var lane = null
	for row in World.MOBS["away_2"]:
		if str(row["class"]) == "field_medic": medic = row
		if str(row["class"]) == "away_blocker" and float(row["y"]) > 500.0: lane = row
	var md := Vector2(float(medic["x"]) - float(lane["x"]), float(medic["y"]) - float(lane["y"])).length()
	ok(md < 300.0, "geometry: the medic is INSIDE its lane's joint-pull radius (%.0f < 300)" % md)
	# the away_1 elite guard keeps the shipped grammar: ≥200 from the forward pad, >320 from the back-drop
	var brute = null
	for row in World.MOBS["away_1"]:
		if str(row["tier"]) == "elite": brute = row
	var pad_d := Vector2(float(brute["x"]) - 1620.0, float(brute["y"]) - 475.0).length()
	var drop_d := Vector2(float(brute["x"]) - 1080.0, float(brute["y"]) - 475.0).length()
	ok(pad_d >= 200.0, "geometry: the elite guard is jukeable (%.0f ≥ 200 from the forward pad)" % pad_d)
	ok(drop_d > 320.0, "geometry: the away_2 back-drop is outside the elite's aggro (%.0f > 320)" % drop_d)

	finish("stab_away")
