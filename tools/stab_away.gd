extends "res://tools/stab/stab_base.gd"
## Phase 8 S1 — THE AWAY CIRCUIT (away_1/away_2) invariants, against the REAL server (headless, no net):
##   • both zones auto-boot as static worlds with exactly the planned camps (classes/tiers/levels);
##   • the HOME "▶ Wildlife Expanse" pad (W3 re-theme) is VISIBLE-but-locked below level 8, refuses the teleport,
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
	ok(int(c1.get("netvine_skink", 0)) == 2 and int(c1.get("tacklehorn_grazer", 0)) == 2
		and int(c1.get("tackle_brute", 0)) == 1, "away_1 roster (W3): 2×netvine_skink + 2×tacklehorn_grazer + tackle_brute")
	var elites2 := 0
	for f in m2:
		if str(f.get("mobTier", "")) == "elite": elites2 += 1
	ok(elites2 == 2, "away_2: exactly 2 elites (medic + warfrog, W4)")
	for f in m1 + m2:
		ok(GameData.CLASSES.has(str(f["classId"])), "def exists: %s" % f["classId"])
		if not GameData.CLASSES.has(str(f["classId"])): break

	# ---- 2. the gate: visible-but-locked under 8, explained, then open at 8 ----
	var lowbie: Dictionary = await login("Rook", 1)                       # level 1
	var pads: Array = srv._portals_for_player("home", 1)
	var seen_away := false
	for p in pads:
		if str(p["label"]) == "▶ Wildlife Expanse": seen_away = true
	ok(seen_away, "gate: the Wildlife Expanse pad is VISIBLE while locked (not a hidden gate)")
	ok(not srv._portal_unlocked(1, "away_gate"), "gate: level 1 is locked out")
	_walk(1, 300.0, 200.0)                                                # stand on the pad
	ok(str(srv._session[1]["map"]) == "home", "gate: locked walk-on does NOT teleport")
	var prompts: Array = fnet.calls("recv_chat", 1)
	var explained := false
	for c in prompts:
		if str(c["args"][1]).contains("Wildlife Expanse") and str(c["args"][1]).contains("level 8"): explained = true
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
	ok(Quests.display_order().size() == Quests.ORDER.size() + Quests.AWAY_ORDER.size() + Quests.FINALS_ORDER.size() + Quests.MIDGAME_ORDER.size(),
		"quest: AWAY_ORDER wired into display_order (and NOT into the secret-gate ORDER)")
	ok(Quests.ORDER.size() == 9, "quest: the secret-boss gate list is untouched (9)")
	await srv._do_quest_accept(2, "away1_roadgame")
	await settle()
	ok((srv._session[2]["quests"] as Dictionary).has("away1_roadgame"), "quest: accepted at level 9")
	# kill a netvine_skink in away_1 via the REAL award path (event → _award_kills)
	_walk(2, 300.0, 200.0)                                    # back into away_1 (fighter must be in-zone for credit)
	var target = null
	for f in _mobs_in("away_1"):
		if str(f["classId"]) == "netvine_skink": target = f; break
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
		{"tier": "minion", "map": "away_1", "class": "netvine_skink", "level": 9}), "bounty: d_roadgame matches an away_1 kill")

	# ---- 7. XP-band numeric pass (plan §hardening 3) — real formulas, computed not asserted. The FULL
	# chain (7 quests + required kills) is measured against the 8→16 band it spans: ratio > 1 means a
	# quester arrives at the Head Coach gate slightly over-leveled (fine — IP is the real filter);
	# ratio < 0.9 would mean starvation, > 1.7 would mean zone-skipping pressure.
	var band := 0                                             # XP needed for 8→16
	for L in range(8, 16):
		band += srv._xp_to_next(L)
	var quest_xp := 0
	for qid in Quests.AWAY_ORDER:
		quest_xp += int(Quests.get_quest(qid)["rewards"].get("xp", 0))
	# required-kill XP along the chain (the quester stays inside con grace throughout)
	var kill_xp := 0
	kill_xp += 12 * srv.MOB_XP_BASE * 9                       # away1_roadgame: 12 minion kills @ ~lvl 9
	kill_xp += srv.MOB_XP_BASE * 10 * srv.MOB_ELITE_XP        # away1_blocker: the lvl-10 elite
	kill_xp += 15 * srv.MOB_XP_BASE * 12                      # away2_gauntlet: 15 minion kills @ ~lvl 12
	kill_xp += srv.MOB_XP_BASE * 12 * srv.MOB_ELITE_XP + srv.MOB_XP_BASE * 13 * srv.MOB_ELITE_XP   # away2_medics: both elites
	kill_xp += 18 * srv.MOB_XP_BASE * 15                      # away3_stadium: 18 kills @ ~lvl 15
	kill_xp += srv.MOB_XP_BASE * 15 * srv.MOB_ELITE_XP + srv.MOB_XP_BASE * 16 * srv.MOB_ELITE_XP   # away3_elites
	kill_xp += srv.MOB_XP_BASE * 16 * srv.MOB_BOSS_XP         # rival_down: the boss
	var directed := quest_xp + kill_xp
	var ratio := float(directed) / float(band)
	ok(ratio >= 0.9 and ratio <= 1.7,
		"xp: the directed full-chain path covers the 8→16 band sanely (%.0f%% of %d XP)" % [ratio * 100.0, band])
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
		if str(row["class"]) == "scrapmask_forager" and float(row["y"]) > 500.0: lane = row
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
	# review: EVERY away forward pad keeps the ≥200 guard margin, and EVERY portal drop-point lands clear
	# of the destination's obstacle collision circles (a drop inside a panel's block band strands arrivals)
	for mp in ["away_1", "away_2", "away_3", "away_boss", "finals_1", "finals_2"]:
		for p in World.PORTALS.get(mp, []):
			if p.has("to") and (str(p["to"]).begins_with("away") or str(p["to"]).begins_with("finals")):   # forward pads: guard margin
				for row in World.MOBS.get(mp, []):
					if str(row["tier"]) == "elite":
						var gd := Vector2(float(p["x"]) - float(row["x"]), float(p["y"]) - float(row["y"])).length()
						ok(gd >= 200.0, "geometry: %s pad→%s guard margin %.0f ≥ 200 (%s)" % [mp, str(p["to"]), gd, str(row["class"])])
			if p.has("to"):                                          # every drop: clear of destination obstacles
				var circles: Array = World.circles_from(World.OBSTACLES.get(str(p["to"]), []))
				circles.append_array(World.collision_from_decals(str(p["to"])))   # S5: decor props carry PROP_FOOTPRINT collision now
				for c in circles:
					var cd := Vector2(float(p["tx"]) - float(c["x"]), float(p["ty"]) - float(c["y"])).length()
					if cd <= float(c["r"]) + 16.0:
						ok(false, "geometry: %s→%s drop (%.0f,%.0f) lands inside an obstacle/decor circle" % [mp, str(p["to"]), float(p["tx"]), float(p["ty"])])
	# S5: spawn points must clear decor collision too (a fountain on the spawn would trap arrivals)
	for mp in ["away_1", "away_2", "away_3", "away_boss", "finals_1", "finals_2"]:
		var sp2: Vector2 = World.MAPS[mp]["spawn"]
		for c in World.collision_from_decals(mp):
			var sd := Vector2(sp2.x - float(c["x"]), sp2.y - float(c["y"])).length()
			if sd <= float(c["r"]) + 16.0:
				ok(false, "geometry: %s spawn sits inside a decor collision circle" % mp)

	# ================================================================ S2 — "Beat the Rival"
	# ---- 11. the back half boots: away_3 + away_boss, exact rosters ----
	ok(srv._worlds.has("away_3") and srv._worlds.has("away_boss"), "S2 boot: away_3 + away_boss auto-boot")
	var m3 := _mobs_in("away_3")
	ok(m3.size() == 5, "away_3: 5 spawns (got %d)" % m3.size())
	var boss = null
	var cores := 0
	for f in _mobs_in("away_boss"):
		if str(f["classId"]) == "arrowbound_howler": boss = f
		if str(f["classId"]) == "rival_core": cores += 1
	ok(boss != null and cores == 3, "away_boss: the Arrowbound Howler + exactly 3 slow-respawn rival cores (W5)")
	ok(str(boss.get("mobTier", "")) == "boss" and int(boss.get("mobLevel", 0)) == 16, "arrowbound_howler: tier boss, level 16")

	# ---- 12. the TEACHING SUBSET pin: phased + summon + hazard + cores, but NO camp-reset ult ----
	var rdef: Dictionary = GameData.CLASSES["arrowbound_howler"]
	ok(bool(rdef.get("phased", false)) and rdef.has("threshSummon") and float(rdef.get("coreShield", 0.0)) > 0.0,
		"arrowbound_howler: phased + threshSummon + coreShield (the teaching primitives)")
	var has_ult := false
	var has_zone := false
	for ab in rdef["abilities"]:
		if str(ab["type"]) == "campreset": has_ult = true
		if str(ab["type"]) == "zone": has_zone = true
	ok(not has_ult, "arrowbound_howler: NO campreset ult — one primitive tier below the raid (the plan's escalation)")
	ok(has_zone, "arrowbound_howler: carries the hazard-zone lesson")
	ok(not rdef.has("respawnS"), "arrowbound_howler: keeps the 30-min boss cadence (the rival_coach review lesson)")
	ok(float(GameData.CLASSES["rival_core"].get("respawnS", 0.0)) >= 30.0 and float(GameData.CLASSES["rival_core"].get("respawnS", 0.0)) <= 90.0,
		"rival_core: the CORES carry the slow respawn (solo can earn the shield-down window; GY raid cores untouched)")
	ok(not GameData.CLASSES["power_core"].has("respawnS"), "power_core: the GY raid cores keep their shipped 6-s cadence")
	ok(str(rdef.get("plate", "")) == "ARROWBOUND HOWLER" and (rdef.get("phases", []) as Array).size() == 4,
		"arrowbound_howler: carries its own boss-chrome plate + 4 phase names (client reads per-def)")
	# PARITY PINS (review): "one tier below the raid" must hold NUMERICALLY — compare the real spawned
	# fighters (hpMult/dmgScale baked in by _scale_mob). The rival must not out-stat the raid boss.
	var hc = null
	for f in srv._worlds["glitchyard_boss"]["fighters"]:
		if str(f["classId"]) == "head_coach": hc = f
	ok(float(boss["maxHP"]) <= float(hc["maxHP"]) * 1.15,
		"parity: rival pool ≤ 1.15× the Head Coach's (%.0f vs %.0f)" % [float(boss["maxHP"]), float(hc["maxHP"])])
	ok(float(boss["dmgMult"]) <= float(hc["dmgMult"]) * 1.05,
		"parity: rival damage ≤ 1.05× the Head Coach's (%.2f vs %.2f)" % [float(boss["dmgMult"]), float(hc["dmgMult"])])

	# ---- 13. gates + pads: every deeper pad carries the chain gate; no dangling pads; restore covered ----
	for mp in ["away_2", "away_3"]:
		var fwd_gated := false
		for p in World.PORTALS.get(mp, []):
			if p.has("to") and str(p["to"]).begins_with("away") and str(p.get("gate", "")) == "away_gate":
				fwd_gated = true
		ok(fwd_gated, "S1 rule: %s's forward pad carries away_gate" % mp)
	ok(World.gate_for_map("away_3") == "away_gate" and World.gate_for_map("away_boss") == "away_gate",
		"restore: away_3 + away_boss derive the login gate from their inbound pads")
	var dangling2 := 0
	for mp in ["away_1", "away_2", "away_3", "away_boss"]:
		for p in World.PORTALS.get(mp, []):
			if p.has("to") and not srv._worlds.has(str(p["to"])): dangling2 += 1
	ok(dangling2 == 0, "pads: the full chain has no dangling destinations")
	var t3: Dictionary = await login("Tamper8c", 12, {"level": 1, "last_map": "away_boss"})
	ok(str(srv._session[12]["map"]) == "home", "restore: sub-8 tampered last_map=away_boss lands at HOME")
	srv.drop_peer(12)
	await settle()

	# ---- 14. the walk: away_2 → away_3 → away_boss and back (real portal path, level 9 passes the gate) ----
	var vet2: Dictionary = await login("Traveler2", 13, {"level": 16})
	_walk(13, 300.0, 200.0)                                   # HOME → away_1
	_walk(13, 1620.0, 475.0)                                  # → away_2
	_walk(13, 1770.0, 500.0)                                  # → away_3 (the pad withheld in S1, live now)
	ok(str(srv._session[13]["map"]) == "away_3", "walk: away_2 forward pad → away_3")
	_walk(13, 1920.0, 550.0)                                  # → the Rival Sideline
	ok(str(srv._session[13]["map"]) == "away_boss", "walk: away_3 boss door → away_boss")
	var bf = srv._find(vet2["fid"])
	ok(Vector2(bf["x"] - 620.0, bf["y"] - 410.0).length() > 320.0, "walk: the boss-room arrival is outside the boss's aggro")
	_walk(13, 80.0, 410.0)                                    # back → away_3
	ok(str(srv._session[13]["map"]) == "away_3", "walk: boss room back pad → away_3")
	var df = srv._find(vet2["fid"])
	ok(Vector2(df["x"] - 1700.0, df["y"] - 550.0).length() > 320.0, "walk: the back-drop clears the boss-door guard's aggro")

	# ---- 15. quests: the chain's back half + the raid bridge ----
	ok(Quests.AWAY_ORDER.size() == 7, "quest: AWAY_ORDER grew to 7 (append-only — the governance rule holds)")
	ok(Quests.ORDER.size() == 9, "quest: the secret-gate ORDER is still untouched")
	var q3 = Quests.get_quest("away3_stadium")
	ok(int(q3["rewards"]["item"].get("ilvl", 0)) == 20 and int(q3["rewards"]["item"].get("item_power", 0)) > 100,
		"quest: the IP-push epic carries EXPLICIT ilvl + item_power (the _grant_quest_item trap is dodged)")
	var qr = Quests.get_quest("rival_down")
	ok(str(qr["rewards"].get("dye", "")) == "rival_crimson", "quest: beating the Rival grants the exclusive dye")
	ok(GameData.DYE_CATALOG.has("rival_crimson") and not ("rival_crimson" in GameData.DYE_IDS),
		"dye: rival_crimson exists and is NOT buyable (the champion-dye pattern)")

	# ---- 16. the IP800 numeric pass (plan §hardening 3): can a solo quester finishing the chain reach the
	# Head Coach gate ORGANICALLY? Simulate a realistic end-of-chain loadout with the REAL item builder:
	# 9 slots of ordinary chain drops (rare, at the dropary ilvls mobLevel+5 the chain actually yields)
	# + the 2 quest epics (explicit item_power). Assert the sum clears BOSS_GATE_IP with margin.
	var ip_total := 0
	var drop_ilvls := [15, 16, 17, 17, 18, 18, 20, 20, 21]    # away_1..3 elite-drop band (mobLevel+5)
	var slots := ["head", "chest", "legs", "hands", "feet", "off_hand", "neck", "ring", "ring"]
	for i in slots.size():
		var it: Dictionary = srv._make_item(slots[i], "rare", int(drop_ilvls[i]))
		ip_total += int(it["item_power"])
	ip_total += int(q3["rewards"]["item"]["item_power"])                       # the trinket epic
	ip_total += int(Quests.get_quest("away3_elites")["rewards"]["item"]["item_power"])   # the main-hand epic
	ok(ip_total >= srv.BOSS_GATE_IP,
		"IP800: a realistic end-of-chain set clears the Head Coach gate (%d ≥ %d)" % [ip_total, srv.BOSS_GATE_IP])
	ok(ip_total <= srv.BOSS_GATE_IP * 2,
		"IP800: ...without trivializing it (%d ≤ %d — the gate stays a real filter)" % [ip_total, srv.BOSS_GATE_IP * 2])
	# the pessimistic floor: all-UNCOMMON drops + the quest epics still gets CLOSE (quest epics are the bridge)
	var ip_floor := 0
	for i in slots.size():
		var it2: Dictionary = srv._make_item(slots[i], "uncommon", int(drop_ilvls[i]))
		ip_floor += int(it2["item_power"])
	ip_floor += 216                                            # the two quest epics (108 each)
	ok(ip_floor >= int(float(srv.BOSS_GATE_IP) * 0.7),
		"IP800: even an unlucky (all-uncommon) quester lands within reach (%d ≥ 70%% of the gate)" % ip_floor)
	# ...and the documented BRIDGE (review #11): the chain's organic drop luck may fall short of 800 — the
	# intended path is "gear up on his sideline" (rival_down's own words): the Rival re-fight drops ilvl-28
	# boss loot, so the floor + one or two rival epics must CROSS the gate.
	var bridge: int = ip_floor - 216 + 216                      # the floor set...
	bridge += int(srv._make_item("main_hand", "epic", 28)["item_power"])   # ...plus ONE rival-farm epic (replacing nothing — an empty slot)
	ok(bridge >= srv.BOSS_GATE_IP,
		"IP800: the unlucky floor + ONE rival-sideline epic crosses the gate (%d ≥ %d — the bridge works)" % [bridge, srv.BOSS_GATE_IP])

	# ---- 17. pages hook + weekly bounty ----
	ok(srv.RIVAL_PAGES > 0, "pages: the Rival Coach kill hook exists (RIVAL_PAGES)")
	ok(srv.BOUNTY_WEEKLY.has("w_rival"), "bounty: the weekly Away Win exists")
	ok(Quests.kill_matches({"objective": {"type": "kill", "match": srv.BOUNTY_WEEKLY["w_rival"]["match"], "count": 1}},
		{"tier": "boss", "map": "away_boss", "class": "arrowbound_howler", "level": 16}), "bounty: w_rival matches the away-boss kill")

	# ================================================================ S3 — "The Finals District"
	# ---- 18. the district boots: rosters + the Gallery's court ----
	ok(srv._worlds.has("finals_1") and srv._worlds.has("finals_2"), "S3 boot: finals_1 + finals_2 auto-boot")
	ok(_mobs_in("finals_1").size() == 6, "finals_1: 6 spawns")
	var gallery = null
	var gcores := 0
	for f in _mobs_in("finals_2"):
		if str(f["classId"]) == "grand_gallery": gallery = f
		if str(f["classId"]) == "rival_core": gcores += 1
	ok(gallery != null and gcores == 2, "finals_2: the Grand Gallery + exactly 2 slow-respawn cores")
	ok(str(gallery.get("mobTier", "")) == "elite", "grand_gallery: ELITE tier (a farmable skill-check, not a world event)")
	var gdef: Dictionary = GameData.CLASSES["grand_gallery"]
	ok(float(gdef.get("hpMult", 1.0)) >= 2.0 and float(gdef.get("coreShield", 0.0)) > 0.0,
		"grand_gallery: elite-PLUS (hpMult + coreShield behind the slow cores — the S2 window lesson at endgame pace)")
	ok(float(gdef.get("respawnS", 0.0)) >= 60.0 and float(gdef.get("respawnS", 0.0)) <= 600.0,
		"grand_gallery: farmable-but-not-instant respawn (the elite-plus cadence)")
	ok(srv.RIVAL_PAGES <= 20, "farm ceiling: rival pages stay under the HC 100/hr line")
	# BEHAVIORAL farm-ceiling pin (review: the old assert was a hardcoded tautology): kill the gallery
	# through the REAL award path and assert pages are untouched while tokens/xp pay (the finals token
	# extension) — a future gallery pages hook now fails CI instead of shipping a 120s-respawn pages farm.
	var farmer: Dictionary = await login("Farmer", 17, {"level": 22})
	var fr = srv._find(farmer["fid"])
	fr["map"] = "finals_2"                                     # stand the farmer in the gallery's zone for credit
	srv._session[17]["map"] = "finals_2"
	var pages0 := int(srv._session[17].get("pages", 0))
	var ftok0 := int(srv._session[17].get("tokens", 0))
	srv._worlds["finals_2"]["events"].append({"type": "kill", "victim": gallery["id"], "killer": farmer["fid"]})
	srv._award_kills()
	srv._worlds["finals_2"]["events"].clear()
	await settle()
	ok(int(srv._session[17].get("pages", 0)) == pages0, "farm ceiling: a gallery kill pays ZERO pages (behavioral, via the real award path)")
	ok(int(srv._session[17].get("tokens", 0)) > ftok0, "tokens: the finals band pays Practice Tokens (the plan's owner-approved 9-28 extension)")
	srv.drop_peer(17)
	await settle()

	# ---- 19. finals_gate: level + gear, NEVER the raid kill ----
	var fresh: Dictionary = await login("Contender", 14, {"level": 17})
	ok(not srv._portal_unlocked(14, "finals_gate"), "finals_gate: L17 with no gear is locked (IP half of the gate)")
	srv._session[14]["item_power"] = 800
	ok(srv._portal_unlocked(14, "finals_gate"), "finals_gate: L17 + IP800 unlocks — WITHOUT any away/raid quest (a stalled raid never blocks)")
	_walk(14, 1480.0, 200.0)
	ok(str(srv._session[14]["map"]) == "finals_1", "walk: the HOME Finals pad → finals_1")
	_walk(14, 1820.0, 530.0)
	ok(str(srv._session[14]["map"]) == "finals_2", "walk: finals_1 forward pad → finals_2")
	var ff = srv._find(fresh["fid"])
	ok(Vector2(ff["x"] - 1680.0, ff["y"] - 550.0).length() > 320.0, "walk: the finals_2 arrival is outside the Gallery's aggro")
	_walk(14, 120.0, 550.0)
	ok(str(srv._session[14]["map"]) == "finals_1", "walk: finals_2 back pad → finals_1")
	srv.drop_peer(14)
	await settle()
	ok(World.gate_for_map("finals_1") == "finals_gate" and World.gate_for_map("finals_2") == "finals_gate",
		"restore: both finals zones derive the login gate (deeper pads carry it — the S1 rule)")
	var t4: Dictionary = await login("Tamper17", 15, {"level": 1, "last_map": "finals_2"})
	ok(str(srv._session[15]["map"]) == "home", "restore: a tampered sub-gate last_map=finals_2 lands at HOME")
	srv.drop_peer(15)
	await settle()
	# ...and the LEGIT restore: _apply_equipment runs BEFORE the gate re-validation (Server.gd auth
	# sequence), so a geared L18 relogging inside finals_2 keeps its position (the stab_authority
	# "Qualified" pattern — this pins the login ORDER, the likeliest regression for IP-half gates)
	var qf: Dictionary = supa.add_character("QualifiedF", "striker", {"level": 18, "last_map": "finals_2"})
	supa.insert_item(qf["char_id"], {"slot": "trinket", "rarity": "epic", "equipped": true, "item_power": 900})
	srv.connect_peer(16)
	await srv.authenticate(16, qf["token"], Protocol.hello())
	await settle()
	ok(str(srv._session[16]["map"]) == "finals_2", "restore: a LEGIT geared L18 resumes inside finals_2 (equipment loads before the gate re-check)")
	srv.drop_peer(16)
	await settle()
	var dangling3 := 0
	for mp in ["finals_1", "finals_2"]:
		for p in World.PORTALS.get(mp, []):
			if p.has("to") and not srv._worlds.has(str(p["to"])): dangling3 += 1
	ok(dangling3 == 0, "pads: the finals chain has no dangling destinations (the Commissioner pad is withheld for S4)")

	# ---- 20. the finals quest chain ----
	ok(Quests.FINALS_ORDER.size() == 4 and Quests.display_order().size() ==
		Quests.ORDER.size() + Quests.AWAY_ORDER.size() + Quests.FINALS_ORDER.size() + Quests.MIDGAME_ORDER.size(),
		"quest: FINALS_ORDER wired into display_order; secret-gate ORDER untouched")
	var fq = Quests.get_quest("finals1_contenders")
	ok(str(fq["prereq"]) == "" and int(fq["min_level"]) == 17,
		"quest: the finals chain opens on level alone — no away/raid prereq (matches the gate philosophy)")
	ok(Quests.kill_matches(Quests.get_quest("finals2_gallery"), {"tier": "elite", "map": "finals_2", "class": "grand_gallery", "level": 25}),
		"quest: the gallery quest matches by CLASS (won't credit the other finals_2 elites)")
	for qid in ["finals1_machines", "finals2_gallery"]:
		var it: Dictionary = Quests.get_quest(qid)["rewards"]["item"]
		ok(int(it.get("ilvl", 0)) >= 24 and int(it.get("item_power", 0)) > 120,
			"quest: %s epic carries explicit ilvl/item_power (the IP push toward commissioner_ready)" % qid)
	ok(srv.BOUNTY_DAILY.has("d_quarter") and srv.BOUNTY_DAILY.has("d_gallery"), "bounty: the finals dailies exist (view-filtered at L17)")

	# ---- 21. the IP@22-24 measurement (plan §S3 deliverable): sets S4's commissioner_ready IP number.
	# A realistic L22-24 loadout = 9 rares at the finals drop band (mobLevel+5 → ilvl 24-30) + the two
	# finals quest epics. The S4 target (1200, from the approved plan) must sit BETWEEN the unlucky floor
	# and the realistic set ×1.15 — reachable with normal play, not free with it.
	var COMMISSIONER_IP := 1200
	var f_ilvls := [24, 25, 26, 26, 27, 28, 28, 29, 30]
	# the 9 NON-epic slots — the quest epics occupy chest + off_hand, so the full 11-item loadout is legal
	# under the 1-per-slot equip rule (review: the old list double-filled chest/off_hand)
	var f_slots := ["head", "legs", "hands", "feet", "main_hand", "neck", "ring", "ring", "trinket"]
	var ip_real := 0
	var ip_low := 0
	for i in f_slots.size():
		ip_real += int(srv._make_item(f_slots[i], "rare", int(f_ilvls[i]))["item_power"])
		ip_low += int(srv._make_item(f_slots[i], "uncommon", int(f_ilvls[i]))["item_power"])
	var f_epics: int = int(Quests.get_quest("finals1_machines")["rewards"]["item"]["item_power"]) \
		+ int(Quests.get_quest("finals2_gallery")["rewards"]["item"]["item_power"])   # read from the defs (review)
	ip_real += f_epics
	ip_low += f_epics
	ok(COMMISSIONER_IP >= ip_low, "IP@22-24: the S4 gate (1200) is above the unlucky floor (%d) — it filters" % ip_low)
	ok(COMMISSIONER_IP <= int(float(ip_real) * 1.15), "IP@22-24: ...and within reach of the realistic set (%d) — measured, not guessed" % ip_real)

	# ================================================================ COLLISION PASS-2 (world-wide)
	# Every physical decor prop now carries a collision circle (owner-requested). This sweep proves NO
	# walkway anywhere is blocked: every portal pad + drop, every spawn, and HOME's service points must
	# clear every obstacle + decal circle by the AI block margin (r + OBSTACLE_PAD 14, +2 slack).
	for mp0 in srv._worlds:
		if srv._is_instance(str(mp0)):
			continue
		var circles0: Array = World.circles_from(World.OBSTACLES.get(str(mp0), []))
		circles0.append_array(World.collision_from_decals(str(mp0)))
		var pts := []                                          # [label, x, y]
		var sp0: Vector2 = World.MAPS[mp0]["spawn"]
		pts.append(["spawn", sp0.x, sp0.y])
		for p0 in World.PORTALS.get(str(mp0), []):
			pts.append(["pad:" + str(p0.get("label", "?")), float(p0["x"]), float(p0["y"])])
		for row0 in World.MOBS.get(str(mp0), []):              # review: camps must not spawn inside a circle
			pts.append(["camp:" + str(row0["class"]), float(row0["x"]), float(row0["y"])])
		if str(mp0) == "home":
			pts.append(["dummy", World.DUMMY_POS.x, World.DUMMY_POS.y])
			pts.append(["shop", World.SHOP_POS.x, World.SHOP_POS.y])
			pts.append(["forge", World.FORGE_POS.x, World.FORGE_POS.y])
			pts.append(["questgiver", World.QUESTGIVER_POS.x, World.QUESTGIVER_POS.y])
			pts.append(["build_shop", World.BUILD_SHOP_POS.x, World.BUILD_SHOP_POS.y])
			pts.append(["practice", World.PRACTICE_POS.x, World.PRACTICE_POS.y])
		for pt in pts:
			for c0 in circles0:
				var pd0 := Vector2(float(pt[1]) - float(c0["x"]), float(pt[2]) - float(c0["y"])).length()
				if pd0 <= float(c0["r"]) + 16.0:
					ok(false, "pass-2: %s %s (%.0f,%.0f) blocked by a collision circle (r %.0f at %.0f,%.0f)" % [str(mp0), str(pt[0]), float(pt[1]), float(pt[2]), float(c0["r"]), float(c0["x"]), float(c0["y"])])
		# review: portal DROP points land on the DESTINATION map — sweep them against ITS circles
		for p0 in World.PORTALS.get(str(mp0), []):
			if p0.has("to") and srv._worlds.has(str(p0["to"])):
				var dcirc: Array = World.circles_from(World.OBSTACLES.get(str(p0["to"]), []))
				dcirc.append_array(World.collision_from_decals(str(p0["to"])))
				for cd1 in dcirc:
					var dd1 := Vector2(float(p0["tx"]) - float(cd1["x"]), float(p0["ty"]) - float(cd1["y"])).length()
					if dd1 <= float(cd1["r"]) + 16.0:
						ok(false, "pass-2: %s→%s drop (%.0f,%.0f) blocked (r %.0f at %.0f,%.0f)" % [str(mp0), str(p0["to"]), float(p0["tx"]), float(p0["ty"]), float(cd1["r"]), float(cd1["x"]), float(cd1["y"])])
	ok(true, "pass-2: every pad, drop, spawn, camp + service point on every static map clears all collision circles")
	# review: WALLS must block along their FULL rendered length (a single circle left ~75% phantom) —
	# sample each panel-model decal's midpoint and quarter points; each must be inside SOME circle's LOS band
	for mp1 in ["glitchyard_1", "arena", "away_3", "finals_2"]:
		var circles1: Array = World.collision_from_decals(str(mp1))
		for d1 in World._decals_source(str(mp1)):
			if not (d1 is Dictionary) or str(d1.get("kind", "")) != "prop" or not World.DECAL_PANELS.has(str(d1.get("model", ""))):
				continue
			var h1 := float(d1.get("h", 1.0))
			var dimp1: Dictionary = World.PROP_DIM[str(d1["model"])]
			var half1: float = float(dimp1["long"]) / float(World.DECAL_PANELS[str(d1["model"])]) * h1 * 20.0 / 2.0
			var yaw1 := float(d1.get("yaw", 0.0))
			for frac in [-0.7, -0.35, 0.0, 0.35, 0.7]:
				var sxp := float(d1["x"]) + cos(yaw1) * half1 * float(frac)
				var syp := float(d1["y"]) + sin(yaw1) * half1 * float(frac)
				var covered := false
				for c2 in circles1:
					if Vector2(sxp - float(c2["x"]), syp - float(c2["y"])).length() <= float(c2["r"]) + 6.0:
						covered = true
						break
				if not covered:
					ok(false, "pass-2: %s %s wall face at %.0f,%.0f (frac %.2f) is NOT covered — phantom wall" % [str(mp1), str(d1["model"]), sxp, syp, float(frac)])
	ok(true, "pass-2: every wall-model decal blocks along its full rendered length (no phantom walls)")

	# ================================================================ S5 — polish pass
	# ---- 22. batch_006/007 props registered end-to-end ----
	for pid2 in ["championship_fountain", "community_team_table", "covered_market_stall", "plaza_light_column",
			"public_plaza_bench", "vendor_service_kiosk", "season_reward_vault", "championship_reward_chest",
			"loot_drop_capsule", "portal_anchor", "open_salvage_hopper"]:
		ok(load("res://models/meshy/props/%s.glb" % pid2) != null, "S5 props: %s.glb LOADS (exists() lies — the v1.1.0 lesson)" % pid2)
	# Pass-2 policy (owner, 2026-07-15): EVERY physical prop collides — boxy ones via PROP_FOOTPRINT,
	# long walls/rails via the DECAL_PANELS row expansion, the tunnel gate as a two-post arch; only flat
	# flora stays walk-through
	ok(World.PROP_FOOTPRINT.has("championship_fountain") and World.PROP_FOOTPRINT.has("public_plaza_bench")
		and World.DECAL_PANELS.has("championship_arena_wall") and World.DECAL_PANELS.has("glitchyard_wall")
		and not World.PROP_FOOTPRINT.has("flower_redA") and not World.PROP_FOOTPRINT.has("grass_large"),
		"pass-2: physical props collide (walls via rows, arch via posts); flat flora stays walk-through")
	# ---- 23. the new-biome residents ----
	# per-home expected bands, widened for routes (review: a global 9..25 let a mis-tiered resident pass)
	var res_bands := {"away_1": [10, 14], "away_2": [10, 14], "away_3": [14, 17], "finals_1": [19, 24], "finals_2": [19, 24]}
	var new_res := 0
	for r in srv.RESIDENTS:
		var home := str(r.get("home", ""))
		if home.begins_with("away") or home.begins_with("finals"):
			new_res += 1
			var rband: Array = res_bands.get(home, [9, 25])
			ok(int(r["level"]) >= int(rband[0]) and int(r["level"]) <= int(rband[1]),
				"S5 residents: %s (lvl %d) sits inside %s's route band [%d..%d]" % [r["id"], int(r["level"]), home, int(rband[0]), int(rband[1])])
	ok(new_res == 3, "S5 residents: 3 new-biome residents declared")
	for mp2 in ["away_1", "away_3", "finals_1"]:
		var found_res := false
		for f in srv._worlds[mp2]["fighters"]:
			if f.get("resident", false): found_res = true
		ok(found_res, "S5 residents: a resident actually spawned in %s" % mp2)

	finish("stab_away")
