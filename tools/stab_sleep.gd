extends "res://tools/stab/stab_base.gd"
## P6§1 — the empty-zone sleep invariants, against the REAL server loop (headless, no net):
##   • with zero real players every static zone sleeps (instances are excluded by construction);
##   • a login wakes exactly the player's zone; a portal hop wakes the destination within one step;
##   • a vacated zone drains (ZONE_DRAIN_MS wall-clock) then sleeps; its sim clock freezes while asleep;
##   • the GLOBAL respawn queue keeps counting through sleep — a mob killed pre-sleep revives inside
##     the sleeping zone with no wake-time catch-up code anywhere;
##   • a bonded resident's zone never sleeps (party frames are the one cross-zone player surface);
##   • RP4 stall accrual is gated for residents in sleeping zones (no fabricated no_progress reports).
## Run: godot --headless --path . --script res://tools/stab_sleep.gd

func _init() -> void:
	_run()

func _steps(n: int) -> void:            # drive REAL server sim steps (physics is test-driven here)
	for i in n:
		srv._physics_process(1.0 / 30.0)

func _run() -> void:
	await boot()

	# ---- 1. boot state: nobody online → every static zone asleep from the first step ----
	_steps(2)
	ok(srv._zone_asleep.size() == srv._worlds.size(),
		"sleep: all %d static zones asleep with 0 players (got %d)" % [srv._worlds.size(), srv._zone_asleep.size()])
	var t_frozen := float(srv._worlds["finals_1"]["t"])
	_steps(10)
	ok(is_equal_approx(float(srv._worlds["finals_1"]["t"]), t_frozen), "sleep: a sleeping zone's sim clock is frozen")

	# ---- 2. login wakes exactly the player's zone ----
	var p: Dictionary = await login("Sleeper", 3, {"level": 9})
	_steps(2)
	ok(not srv._zone_asleep.has("home"), "wake: login wakes HOME")
	ok(srv._zone_asleep.has("finals_1"), "wake: unrelated zones stay asleep")
	var t0 := float(srv._worlds["home"]["t"])
	_steps(6)
	ok(float(srv._worlds["home"]["t"]) > t0, "wake: an awake zone's sim clock advances")

	# ---- 3. a portal hop wakes the destination; the vacated zone drains, then sleeps ----
	srv._session[3]["quests"]["gy5_command"] = {"completed": true, "progress": 2, "rewarded": true}
	var f = srv._find(p["fid"])
	f["x"] = 300.0
	f["y"] = 200.0
	srv._tp_next.erase(f["id"])
	srv._check_portals()
	_steps(2)
	ok(str(srv._session[3]["map"]) == "away_1" and not srv._zone_asleep.has("away_1"),
		"wake: the HOME→away_1 hop wakes away_1 within one step")
	ok(not srv._zone_asleep.has("home"), "drain: the vacated zone keeps ticking through the drain window")
	srv._zone_awake_until["home"] = 0             # force-expire the drain (it's wall-clock, not test time)
	_steps(2)
	ok(srv._zone_asleep.has("home"), "drain: after the window the vacated zone sleeps")

	# ---- 4. respawns count through sleep (the global queue needs no catch-up) ----
	var vic = null
	for m in srv._worlds["away_1"]["fighters"]:
		if int(m["team"]) == 1 and bool(m["alive"]):
			vic = m
			break
	vic["alive"] = false
	vic["hp"] = 0.0
	_steps(2)                                     # the awake zone's dead-scan queues the respawn
	ok(srv._respawn.has(vic["id"]), "respawn: the kill queued a timer while the zone was awake")
	f = srv._find(p["fid"])
	f["x"] = 120.0
	f["y"] = 475.0
	srv._tp_next.erase(f["id"])
	srv._check_portals()                          # back to HOME — away_1 starts draining
	srv._zone_awake_until["away_1"] = 0
	_steps(2)
	ok(srv._zone_asleep.has("away_1"), "respawn: away_1 sleeps with the corpse's timer queued")
	srv._respawn[vic["id"]] = 0.05                # fast-forward the 6s clock (data, not behavior)
	_steps(4)
	ok(bool(vic["alive"]) and float(vic["hp"]) > 0.0,
		"respawn: the mob revived INSIDE the sleeping zone (global queue — no wake-time catch-up)")

	# ---- 5. a bonded resident's zone never sleeps ----
	var rfid := ""
	for fid in srv._residents.keys():
		if srv._find(fid) != null:
			rfid = str(fid)
			break
	var rzone := str(srv._find(rfid)["map"])
	srv._res_party[rfid] = 3
	_steps(2)
	ok(not srv._zone_asleep.has(rzone), "party: a bonded resident's zone stays awake (%s)" % rzone)
	srv._res_party.erase(rfid)
	srv._zone_awake_until[rzone] = 0
	_steps(2)
	if rzone != str(srv._session[3]["map"]):
		ok(srv._zone_asleep.has(rzone), "party: unbonding lets the zone sleep again")
	else:
		ok(true, "party: the resident shares the player's zone — skip")

	# ---- 6. RP4 gate: a frozen resident in a sleeping zone accrues NO stall ----
	var gated := ""
	for fid in srv._residents.keys():
		var rf = srv._find(fid)
		if rf != null and bool(rf["alive"]) and srv._zone_asleep.has(str(rf["map"])):
			gated = str(fid)
			break
	if gated != "":
		srv._res_prog[gated] = {"last_dmg": 0.0, "stall_t": 55.0, "zone": str(srv._find(gated)["map"])}
		srv._tick_reports(REPORT_TICK_S_PROBE)
		ok(float((srv._res_prog[gated] as Dictionary).get("stall_t", -1.0)) == 0.0,
			"RP4: the stall clock resets for a sleeping-zone resident (no fabricated no_progress)")
	else:
		ok(true, "RP4: no resident in a sleeping zone this run — skip")

	finish("stab_sleep")

const REPORT_TICK_S_PROBE := 6.0                  # > the server's REPORT_TICK_S so one call runs the scan
