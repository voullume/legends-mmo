extends "res://tools/stab/stab_base.gd"
## Official Maps Phase 2 — the Locale 1 GREYBOX slice invariants, against the REAL server (headless):
##   • the four loc1 zones boot as static worlds with exactly the planned camps (classes/tiers/levels);
##   • loc1_gate is the DEV-LOCK: the GY5 pad is HIDDEN from non-admin snapshots, refuses the walk-on,
##     and opens for an admin (the greybox is admin-only until the Locale 1 release);
##   • login-restore: gate_for_map derives loc1_gate for ALL FOUR zones (the S1 every-pad rule) and a
##     tampered last_map bounces a non-admin HOME while an admin resumes inside;
##   • the full portal walk graph (admin): GY5 → fields → pitch (main seam), fields → lane → pitch
##     (the alternate), pitch → culvert → fields (the return shortcut), the fields intra-map checkpoint,
##     back out to GY5 — and no dangling pads;
##   • geometry sweeps, self-contained for the loc1 maps (do NOT grow stab_away's lists): every arrival
##     >320 from every camp row, spawns/drops/camps clear collision r+16, every loc1 pad ≥200 from its
##     map's elites, and camp engageability (24-point LOS ring at the 250 ranged band, ≥50% hold LOS);
##   • the §9.1 CACHE ARENA: exactly 5 guards in two separable sub-clusters 280-380 apart, ≥2
##     DECAL_PANELS walls in the arena, the chest LOS-visible from OUTSIDE every guard's 320 aggro
##     (the informed-commit rule), and the whole pack close enough to the chest to fight inside leash;
##   • the cache CHANNEL (server-side, non-sim): completes undamaged → exactly one "done" + the greybox
##     world-relock; breaks on a mid-channel hit (noDmgT track) and on moving; refuses while locked.
## Run: godot --headless --path . --script res://tools/stab_locale1.gd

const GeomLib := preload("res://shared/Geom.gd")
const L1MAPS := ["loc1_fields", "loc1_pitch", "loc1_lane", "loc1_culvert"]
const CACHE_XY := Vector2(1700.0, 260.0)

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
	srv._tp_next.erase(f["id"])
	srv._check_portals()

# spin on the REAL clock (create_timer undershoots in the headless loop — a rate-limit window or the
# channel duration must be measured against Time.get_ticks_msec, the same clock the server uses)
func wait_until(ms_target: int) -> void:
	var t_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() < ms_target:
		if Time.get_ticks_msec() - t_start > 15000:
			ok(false, "wait_until: 15 s cap hit (target %d) — a corrupted target, fail loud not exit-124" % ms_target)
			return
		await process_frame

func _collision_for(map: String) -> Array:
	var c: Array = World.circles_from(World.OBSTACLES.get(map, []))
	c.append_array(World.collision_from_decals(map))
	return c

# kill every pitch mob and reset THEIR respawn clocks (scoped — not a global clear) — the channel
# tests need a quiet arena, and the 6 s respawn cadence would otherwise put the pack back mid-test
# (a dead, unqueued mob re-queues at a fresh 6 s on the next driven tick, which outlives every sub-test)
func _quiet_pitch() -> void:
	for m in _mobs_in("loc1_pitch"):
		m["alive"] = false
		m["hp"] = 0.0
		srv._respawn.erase(m["id"])

func _clears_collision(p: Vector2, circles: Array) -> bool:
	for c in circles:
		if p.distance_to(Vector2(float(c["x"]), float(c["y"]))) < float(c["r"]) + 16.0:
			return false
	return true

func _run() -> void:
	await boot()

	# ---- 1. zone boot: worlds + camps exactly as planned ----
	for mp in L1MAPS:
		ok(srv._worlds.has(mp), "boot: %s auto-boots as a static world" % mp)
	ok(_mobs_in("loc1_fields").size() == 11, "fields: 11 spawns (got %d)" % _mobs_in("loc1_fields").size())
	ok(_mobs_in("loc1_pitch").size() == 15, "pitch: 15 spawns incl. the 5-guard cache pack (got %d)" % _mobs_in("loc1_pitch").size())
	ok(_mobs_in("loc1_lane").size() == 6, "lane: 6 spawns (got %d)" % _mobs_in("loc1_lane").size())
	ok(_mobs_in("loc1_culvert").size() == 2, "culvert: 2 spawns — the telegraphed tube guard pair (got %d)" % _mobs_in("loc1_culvert").size())
	var pe := 0
	for f in _mobs_in("loc1_pitch"):
		if str(f.get("mobTier", "")) == "elite":
			pe += 1
	ok(pe == 2, "pitch: exactly 2 elites (the tower warden + the cache-pack anchor)")
	for mp in L1MAPS:
		for f in _mobs_in(mp):
			ok(GameData.CLASSES.has(str(f["classId"])), "def exists: %s (%s)" % [f["classId"], mp])
			if not GameData.CLASSES.has(str(f["classId"])):
				break

	# ---- 2. the DEV-LOCK: hidden + refused for non-admins, open for admins ----
	var rook: Dictionary = await login("Rook", 1)
	var rf = srv._find(srv._session[1]["fid"])
	srv._relocate(rf, srv._session[1], World.GY5, World.GY5_SPAWN)
	var seen_l1 := false
	for p in srv._portals_for_player("glitchyard_5", 1):
		if str(p.get("label", "")).contains("Practice Fields"):
			seen_l1 = true
	ok(not seen_l1, "dev-lock: the GY5 loc1 pad is HIDDEN from a non-admin snapshot")
	_walk(1, 700.0, 1000.0)
	ok(str(srv._session[1]["map"]) == "glitchyard_5", "dev-lock: a non-admin walk-on does NOT teleport")
	var adm: Dictionary = await login("Marshal", 2, {"admin": true})
	var af = srv._find(srv._session[2]["fid"])
	srv._relocate(af, srv._session[2], World.GY5, World.GY5_SPAWN)
	var seen_adm := false
	for p in srv._portals_for_player("glitchyard_5", 2):
		if str(p.get("label", "")).contains("Practice Fields"):
			seen_adm = true
	ok(seen_adm, "dev-lock: an admin sees the pad")
	_walk(2, 700.0, 1000.0)
	ok(str(srv._session[2]["map"]) == "loc1_fields", "dev-lock: the admin walk-on enters loc1_fields")
	af = srv._find(srv._session[2]["fid"])
	ok(Vector2(af["x"], af["y"]).distance_to(Vector2(300.0, 1400.0)) < 2.0, "arrival: the entry plaza (300,1400)")

	# ---- 3. the walk graph (admin): main seam, alternate, shortcut, checkpoint, back out ----
	_walk(2, 3480.0, 700.0)
	ok(str(srv._session[2]["map"]) == "loc1_pitch", "walk: fields → pitch via the treeline break (main seam)")
	_walk(2, 300.0, 1900.0)
	ok(str(srv._session[2]["map"]) == "loc1_culvert", "walk: pitch → culvert (the tube's pitch mouth)")
	_walk(2, 120.0, 550.0)
	ok(str(srv._session[2]["map"]) == "loc1_fields", "walk: culvert → fields (the return shortcut lands at the outfall)")
	_walk(2, 3480.0, 2100.0)
	ok(str(srv._session[2]["map"]) == "loc1_lane", "walk: fields → lane (the alternate route)")
	_walk(2, 2480.0, 350.0)
	ok(str(srv._session[2]["map"]) == "loc1_pitch", "walk: lane → pitch via the collapsed gate")
	_walk(2, 120.0, 700.0)
	ok(str(srv._session[2]["map"]) == "loc1_fields", "walk: pitch → fields back across the seam")
	_walk(2, 3350.0, 2600.0)
	af = srv._find(srv._session[2]["fid"])
	ok(str(srv._session[2]["map"]) == "loc1_fields" and Vector2(af["x"], af["y"]).distance_to(Vector2(400.0, 1500.0)) < 2.0,
		"walk: the intra-map checkpoint collapses the return walk (far side → entry)")
	_walk(2, 120.0, 1400.0)
	ok(str(srv._session[2]["map"]) == "glitchyard_5", "walk: fields → GY5 back out of the locale")

	# ---- 4. no dangling pads ----
	for mp in L1MAPS:
		for p in World.PORTALS.get(mp, []):
			if p.has("to"):
				ok(srv._worlds.has(str(p["to"])), "no dangling pad: %s → %s" % [mp, p["to"]])

	# ---- 5. login-restore re-validation (the S1 rule end to end) ----
	for mp in L1MAPS:
		ok(World.gate_for_map(mp) == "loc1_gate", "restore: %s derives loc1_gate from its inbound pads" % mp)
	var tamper: Dictionary = await login("Tamper", 7, {"level": 30, "last_map": "loc1_pitch"})
	ok(str(srv._session[7]["map"]) == "home", "restore: a non-admin tampered last_map=loc1_pitch lands at HOME (even at L30)")
	srv.drop_peer(7)
	await settle()
	var admr: Dictionary = await login("MarshalBack", 8, {"admin": true, "last_map": "loc1_pitch", "level": 9})
	ok(str(srv._session[8]["map"]) == "loc1_pitch", "restore: an admin resumes inside the greybox")
	srv.drop_peer(8)
	await settle()
	# the S1 rule, asserted directly (review find: gate_for_map only reads the FIRST inbound pad, and
	# the walks use an admin — so an interior pad could silently lose its gate key without this loop)
	for src in World.PORTALS:
		for p in World.PORTALS[src]:
			if L1MAPS.has(str(p.get("to", ""))):
				ok(str(p.get("gate", "")) == "loc1_gate", "S1: pad %s → %s carries loc1_gate" % [src, p["to"]])

	# ---- 6. geometry sweeps (self-contained; the stab_away style, scoped to the loc1 maps) ----
	for mp in L1MAPS:
		var circles := _collision_for(mp)
		var dims: Dictionary = World.MAPS[mp]
		# arrivals: the map's spawn + every drop landing here, >320 from every camp row + clear of collision
		var arrivals: Array = [Vector2(dims["spawn"].x, dims["spawn"].y)]
		for src in World.PORTALS:
			for p in World.PORTALS[src]:
				if p.has("to") and str(p["to"]) == mp:
					arrivals.append(Vector2(float(p["tx"]), float(p["ty"])))
		for a in arrivals:
			ok(a.x >= 20.0 and a.y >= 20.0 and a.x <= float(dims["w"]) - 20.0 and a.y <= float(dims["h"]) - 20.0,
				"%s: arrival (%.0f,%.0f) is in-bounds" % [mp, a.x, a.y])
			ok(_clears_collision(a, circles), "%s: arrival (%.0f,%.0f) clears collision r+16" % [mp, a.x, a.y])
			for row in World.MOBS.get(mp, []):
				var d: float = a.distance_to(Vector2(float(row["x"]), float(row["y"])))
				ok(d > 320.0, "%s: arrival (%.0f,%.0f) is %d su from the %s camp (>320)" % [mp, a.x, a.y, int(d), row["class"]])
		# camps + pads clear collision; every pad in this map ≥200 from this map's elites
		for row in World.MOBS.get(mp, []):
			ok(_clears_collision(Vector2(float(row["x"]), float(row["y"])), circles),
				"%s: camp %s clears collision r+16" % [mp, row["class"]])
		for p in World.PORTALS.get(mp, []):
			var pp := Vector2(float(p["x"]), float(p["y"]))
			ok(_clears_collision(pp, circles), "%s: pad '%s' clears collision r+16" % [mp, p.get("label", "?")])
			for row in World.MOBS.get(mp, []):
				if str(row.get("tier", "")) == "elite":
					ok(pp.distance_to(Vector2(float(row["x"]), float(row["y"]))) >= 200.0,
						"%s: pad '%s' is ≥200 from the elite (jukeable, not a mandatory hit)" % [mp, p.get("label", "?")])
	# the GY5 return drop (fields → GY5) + the new pad obey GY5's own grammar too (incl. its shipped
	# decal collision from data/decals/glitchyard_5.json)
	var g5c := _collision_for("glitchyard_5")
	ok(_clears_collision(Vector2(300.0, 1000.0), g5c), "gy5: the fields return drop clears collision r+16")
	ok(_clears_collision(Vector2(700.0, 1000.0), g5c), "gy5: the loc1 pad clears collision r+16")
	for row in World.MOBS.get(World.GY5, []):
		var d5 := Vector2(300.0, 1000.0).distance_to(Vector2(float(row["x"]), float(row["y"])))
		ok(d5 > 320.0, "gy5: the fields return drop is %d su from the %s camp (>320)" % [int(d5), row["class"]])
		ok(Vector2(700.0, 1000.0).distance_to(Vector2(float(row["x"]), float(row["y"]))) > 320.0,
			"gy5: the loc1 pad is out of aggro of the %s camp" % row["class"])
	# backdrop data integrity (client-only files — nothing else headless touches them)
	for mp in L1MAPS:
		var btxt := FileAccess.get_file_as_string("res://data/backdrops/%s.json" % mp)
		var barr = JSON.parse_string(btxt)
		ok(barr is Array and (barr as Array).size() > 0, "backdrops: %s.json parses as a non-empty array" % mp)
	# camp engageability: 24 firing positions on the 250 ranged ring, ≥50% must hold LOS
	for mp in L1MAPS:
		var ocirc := _collision_for(mp)
		var fake := {"map": {"obstacles": ocirc}}
		var dims2: Dictionary = World.MAPS[mp]
		for camp in World.MOBS.get(mp, []):
			var cx := float(camp["x"])
			var cy := float(camp["y"])
			var seen := 0
			var tried := 0
			for step in 24:
				var ang := TAU * float(step) / 24.0
				var px := cx + cos(ang) * 250.0
				var py := cy + sin(ang) * 250.0
				if px < 20.0 or py < 20.0 or px > float(dims2["w"]) - 20.0 or py > float(dims2["h"]) - 20.0:
					continue
				tried += 1
				if GeomLib.has_los(fake, {"x": px, "y": py}, {"x": cx, "y": cy}):
					seen += 1
			ok(tried > 0 and seen * 2 >= tried,
				"engageable: %s camp %s (%.0f,%.0f) holds LOS from %d/%d positions" % [mp, camp["class"], cx, cy, seen, tried])

	# ---- 7. the §9.1 CACHE ARENA (the load-bearing content rule, mechanized) ----
	# the interaction point, the visible chest, and this test's origin must all agree (review find:
	# these were three independent literals that could drift apart with everything green)
	var cc0: Dictionary = World.caches_for("loc1_pitch")[0]
	ok(Vector2(float(cc0["x"]), float(cc0["y"])) == CACHE_XY, "cache: World.CACHES matches the arena origin under test")
	ok(float(cc0["channel_s"]) == 2.5, "cache: the 2.5 s anti-kite channel is pinned in data")
	var chest_found := false
	for d in World.decals_for("loc1_pitch"):
		if str(d.get("kind", "")) == "prop" and str(d.get("model", "")) == "championship_reward_chest" \
				and CACHE_XY.distance_to(Vector2(float(d["x"]), float(d["y"]))) <= float(cc0["r"]):
			chest_found = true
	ok(chest_found, "cache: the visible chest decal sits at the CACHES point")
	var guards := []                               # [{p, level, tier}] — levels matter (the prize stays defended)
	for row in World.MOBS["loc1_pitch"]:
		var gp := Vector2(float(row["x"]), float(row["y"]))
		if CACHE_XY.distance_to(gp) <= 450.0:
			guards.append({"p": gp, "level": int(row["level"]), "tier": str(row["tier"])})
	ok(guards.size() == 5, "cache: exactly 5 guards within 450 of the chest (got %d)" % guards.size())
	var pack_elites := 0
	var min_lvl := 99
	for g in guards:
		if str(g["tier"]) == "elite":
			pack_elites += 1
		min_lvl = mini(min_lvl, int(g["level"]))
	ok(pack_elites == 1, "cache: exactly one elite anchors the pack")
	ok(min_lvl >= 9, "cache: no guard below L9 (a re-level to trivial fails here)")
	for row in World.MOBS["loc1_pitch"]:
		if CACHE_XY.distance_to(Vector2(float(row["x"]), float(row["y"]))) <= 450.0:
			ok(float(row.get("respawnS", 0.0)) >= 30.0,
				"cache: the guard row carries a slow respawn (pull-3-then-3 stays possible — owner 2026-08-05)")
	# clustering at 150 su linkage, made order-proof with a merge-until-stable pass (review find)
	var clusters := []
	for g in guards:
		var placed := false
		for cl in clusters:
			for m in cl:
				if (g["p"] as Vector2).distance_to(m) < 150.0:
					cl.append(g["p"])
					placed = true
					break
			if placed:
				break
		if not placed:
			clusters.append([g["p"]])
	var merged := true
	while merged:
		merged = false
		for i in range(clusters.size()):
			for j in range(i + 1, clusters.size()):
				var close := false
				for a2 in clusters[i]:
					for b2 in clusters[j]:
						if (a2 as Vector2).distance_to(b2) < 150.0:
							close = true
				if close:
					clusters[i].append_array(clusters[j])
					clusters.remove_at(j)
					merged = true
					break
			if merged:
				break
	ok(clusters.size() == 2, "cache: the pack forms exactly 2 sub-clusters (got %d)" % clusters.size())
	if clusters.size() == 2:
		var cen := []
		for cl in clusters:
			var s := Vector2.ZERO
			for m in cl:
				s += m
			cen.append(s / float(cl.size()))
		var cd: float = cen[0].distance_to(cen[1])
		ok(cd >= 280.0 and cd <= 380.0, "cache: sub-cluster centroids %d su apart (280-380 — separable, not a blob)" % int(cd))
	var walls := 0
	for d in World.decals_for("loc1_pitch"):
		if str(d.get("kind", "")) == "prop" and World.DECAL_PANELS.has(str(d.get("model", ""))) \
				and CACHE_XY.distance_to(Vector2(float(d["x"]), float(d["y"]))) <= 560.0:
			walls += 1
	ok(walls == 3, "cache: all three authored LOS walls are load-bearing (got %d)" % walls)
	# the informed-commit rule: ≥1 point outside EVERY guard's 320 aggro that still SEES the chest
	var pcirc := _collision_for("loc1_pitch")
	var pfake := {"map": {"obstacles": pcirc}}
	var pdims: Dictionary = World.MAPS["loc1_pitch"]
	var vis := 0
	for step in 24:
		var ang := TAU * float(step) / 24.0
		var px := CACHE_XY.x + cos(ang) * 640.0
		var py := CACHE_XY.y + sin(ang) * 640.0
		if px < 20.0 or py < 20.0 or px > float(pdims["w"]) - 20.0 or py > float(pdims["h"]) - 20.0:
			continue
		var safe := true
		for g in guards:
			if Vector2(px, py).distance_to(g["p"]) <= 320.0:
				safe = false
				break
		# aim at the chest's visible FACE, not its center — the chest prop carries its own (min-clamped r4)
		# collision circle, so a ray ending at the exact center reads as blocked by the chest itself
		var tgt: Vector2 = CACHE_XY + (Vector2(px, py) - CACHE_XY).normalized() * 30.0
		if safe and GeomLib.has_los(pfake, {"x": px, "y": py}, {"x": tgt.x, "y": tgt.y}):
			vis += 1
	ok(vis >= 1, "cache: the chest is LOS-visible from %d safe ring points (see the prize BEFORE you commit)" % vis)
	for g in guards:
		ok(CACHE_XY.distance_to(g["p"]) <= 600.0, "cache: guard at (%.0f,%.0f) anchors within 600 of the chest (fight stays in leash room)" % [g["p"].x, g["p"].y])

	# ---- 8. the cache CHANNEL mechanic (server-side, non-sim — bal_identity untouched) ----
	# park the admin at the chest and clear the pitch mobs so the tests are deterministic (the guards
	# would legitimately hit the channeler — that is the design; here we simulate hits via noDmgT).
	af = srv._find(srv._session[2]["fid"])
	srv._relocate(af, srv._session[2], "loc1_pitch", Vector2(1700.0, 300.0))
	af = srv._find(srv._session[2]["fid"])
	_quiet_pitch()
	for i in 40:                                   # pre-run sim so noDmgT has a real baseline
		srv._physics_process(1.0 / 30.0)
	fnet.clear()
	# a) break on a mid-channel hit
	_quiet_pitch()
	srv.cache_open(2)
	ok(srv._cache_channel.has(2), "channel: opens at the chest")
	var s0: Array = fnet.calls("recv_cache_state", 2)
	ok(s0.size() == 1 and str(s0[0]["args"][0]) == "start" and int(s0[0]["args"][1]) == 2500,
		"channel: announces the 2.5 s duration (a near-zero channel_s regression fails here)")
	for i in 10:
		srv._physics_process(1.0 / 30.0)
	ok(srv._cache_channel.has(2), "channel: survives undamaged sim ticks")
	af["noDmgT"] = 0.0                             # the hit: engine resets noDmgT on ANY damage
	srv._tick_cache_channels()
	ok(not srv._cache_channel.has(2), "channel: a hit BREAKS it (the anti-kite rule)")
	var st: Array = fnet.calls("recv_cache_state", 2)
	ok(st.size() >= 2 and str(st[st.size() - 1]["args"][0]) == "break", "channel: the client heard 'break'")
	await wait_until(int(srv._cache_next.get(2, 0)) + 30)
	# b) break on moving
	_quiet_pitch()
	srv.cache_open(2)
	ok(srv._cache_channel.has(2), "channel: reopens after a break")
	af["x"] = float(af["x"]) + 30.0
	srv._tick_cache_channels()
	ok(not srv._cache_channel.has(2), "channel: moving >12 su BREAKS it")
	srv.cache_open(2)                              # immediately inside the 500 ms window
	ok(not srv._cache_channel.has(2), "rate limit: an immediate re-open is dropped (the house rule, asserted)")
	af["x"] = 1700.0
	af["y"] = 300.0
	await wait_until(int(srv._cache_next.get(2, 0)) + 30)
	# c) completes undamaged → loot once + the greybox relock. NOTE the server also live-ticks during
	# test awaits, so the pack RESPAWNS on its 6 s cadence and (by §9.1 design) beats on the channeler —
	# _quiet_pitch() re-kills + resets the respawn clock so the clean run stays clean.
	fnet.clear()
	_quiet_pitch()
	srv.cache_open(2)
	ok(srv._cache_channel.has(2), "channel: opens for the clean run")
	# drive the sim at REAL frame deltas (exactly like production) until the channel deadline — the
	# noDmgT track then follows the wall clock with zero margin math, so this cannot flake on a slow
	# CI machine (review find: the old fixed-82-call approach had a ~250 ms cliff)
	var tp := Time.get_ticks_msec()
	while srv._cache_channel.has(2) and Time.get_ticks_msec() < int(srv._cache_channel[2]["t0"]) + 2550:
		await process_frame
		var tn := Time.get_ticks_msec()
		srv._physics_process(float(tn - tp) / 1000.0)
		tp = tn
	srv._tick_cache_channels()
	ok(not srv._cache_channel.has(2), "channel: completes after channel_s undamaged")
	var done_n := 0
	for c in fnet.calls("recv_cache_state", 2):
		if str(c["args"][0]) == "done":
			done_n += 1
	ok(done_n == 1, "channel: exactly ONE 'done' (loot granted once)")
	ok(srv._cache_down.has("loc1_pitch_islet"), "channel: the greybox world-relock is set")
	await settle()                                 # _grant_item awaits the DB write before recv_loot
	var lc: Array = fnet.calls("recv_loot", 2)
	ok(lc.size() == 1 and str(lc[0]["args"][1]) == "epic", "cache loot: exactly one grant, EPIC rarity (the §9.1 reward rule)")
	ok(int(srv.CACHE_ILVL) == 15, "cache loot: the ilvl-15 'beats the route' pin")
	# d) locked: a second open refuses with the remaining time
	await wait_until(int(srv._cache_next.get(2, 0)) + 30)
	fnet.clear()
	_quiet_pitch()
	srv.cache_open(2)
	ok(not srv._cache_channel.has(2), "locked: no new channel while relocked")
	var lk: Array = fnet.calls("recv_cache_state", 2)
	ok(lk.size() == 1 and str(lk[0]["args"][0]) == "locked" and int(lk[0]["args"][1]) > 100000 and int(lk[0]["args"][1]) <= 120000,
		"locked: the remaining ms is the actual lockout remainder (not a timestamp)")

	finish("stab_locale1")
