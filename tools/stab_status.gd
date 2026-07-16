extends "res://tools/stab/stab_base.gd"
## UI-consistency §3b — status ("st") emission suite. Pins the server-side status_st helper +
## its wiring into _snapshot_for and _party_roster:
##   • a clean fighter emits NO st key (idle fighters pay zero bytes);
##   • every status field encodes exactly (timers → tenths-ceil ints, magnitudes → percent ints,
##     shield absorb → flat int, dots → [count, longest-remaining]);
##   • bypass/reflect read the DURATION-bearing buffs.bypass/buffs.reflect (no *T twins exist);
##     nextdmg gates on > 0.0 (idle 0.0, no timer — active until consumed);
##   • snapshot building NEVER mutates the world (byte-hash before/after);
##   • the party roster mirrors st for members and tolerates a missing (cross-zone) fighter.
## Run: godot --headless --path . --script res://tools/stab_status.gd

const Combat := preload("res://shared/Combat.gd")

func _init() -> void:
	_run()

func _run() -> void:
	await boot()
	var a: Dictionary = await login("Alice", 1)
	var b: Dictionary = await login("Bob", 2)
	var fa = srv._find(a["fid"])
	ok(fa != null, "Alice's fighter exists")

	# ---- 1. clean fighter → empty st, and NO st key in the real snapshot ----
	ok(srv.status_st(fa).is_empty(), "clean fighter → empty st")
	var amap := str(srv._session[1]["map"])
	var w: Dictionary = srv._worlds[amap]
	var snap: Dictionary = srv._snapshot_for(w, amap, Vector2(float(fa["x"]), float(fa["y"])), {})
	var entry := {}
	for d in snap["fighters"]:
		if str(d["id"]) == str(a["fid"]):
			entry = d
	ok(not entry.is_empty(), "snapshot carries Alice")
	ok(not entry.has("st"), "clean fighter → snapshot has NO st key")

	# ---- 2. buff-dict statuses (the single writer) encode exactly ----
	Combat.apply_buff_dict(fa, {"dr": 0.25, "dur": 2.0})
	Combat.apply_buff_dict(fa, {"ms": 1.20, "dur": 2.5})
	Combat.apply_buff_dict(fa, {"atkspd": 1.32})                    # no dur → apply_buff_dict's 2.2 default
	Combat.apply_buff_dict(fa, {"crit": 0.30, "dur": 2.4})
	Combat.apply_buff_dict(fa, {"nextdmg": 1.70})
	Combat.apply_buff_dict(fa, {"bypass": true, "dur": 3.0})
	Combat.apply_buff_dict(fa, {"reflect": true, "dur": 1.2})
	Combat.apply_buff_dict(fa, {"guard": {"charges": 1, "kb": 45.0}, "dur": 2.0})
	var st: Dictionary = srv.status_st(fa)
	ok(st.get("dr") == [25, 20], "dr → [pct, tenths] got %s" % [st.get("dr")])
	ok(st.get("ms") == [120, 25], "ms → [pct, tenths] got %s" % [st.get("ms")])
	ok(st.get("as") == [132, 22], "atkspd → [pct, tenths(2.2 default)] got %s" % [st.get("as")])
	ok(st.get("cr") == [30, 24], "crit → [pct, tenths] got %s" % [st.get("cr")])
	ok(st.get("nx") == 170, "nextdmg → pct (no timer) got %s" % [st.get("nx")])
	ok(st.get("by") == 30, "bypass: buffs.bypass IS the timer → tenths got %s" % [st.get("by")])
	ok(st.get("rf") == 12, "reflect: buffs.reflect IS the timer → tenths got %s" % [st.get("rf")])
	ok(st.get("gd") == [1, 20], "guard → [charges, tenths] got %s" % [st.get("gd")])

	# ---- 3. non-buff statuses ----
	fa["shield"] = 57.4
	fa["shieldT"] = 3.0
	fa["stun"] = 0.45
	fa["slowT"] = 1.01
	fa["slowAmt"] = 0.35
	fa["evade"] = 0.25
	fa["untarget"] = 0.9
	fa["barrier"] = 0.70
	fa["barrierT"] = 2.95
	fa["dots"].append({"src": str(b["fid"]), "dps": 6.0, "remaining": 2.3, "proc": "burn1"})
	fa["dots"].append({"src": str(b["fid"]), "dps": 4.0, "remaining": 1.0, "proc": "burn2"})
	st = srv.status_st(fa)
	ok(st.get("sh") == [57, 30], "shield → [absorb int, tenths] got %s" % [st.get("sh")])
	ok(st.get("stn") == 5, "stun → tenths-ceil got %s" % [st.get("stn")])
	ok(st.get("slw") == [11, 35], "slow → [tenths-ceil, pct] got %s" % [st.get("slw")])
	ok(st.get("ev") == 3, "evade → tenths-ceil got %s" % [st.get("ev")])
	ok(st.get("ut") == 9, "untarget → tenths got %s" % [st.get("ut")])
	ok(st.get("ba") == [70, 30], "barrier → [DR pct (not absorb), tenths-ceil] got %s" % [st.get("ba")])
	ok(st.get("dot") == [2, 23], "dots → [count, longest remaining tenths] got %s" % [st.get("dot")])

	# ---- 4. one-shot consumption edges: reflect eaten / nextdmg spent → keys vanish ----
	fa["buffs"]["reflect"] = 0.0
	fa["buffs"]["nextdmg"] = 0.0
	st = srv.status_st(fa)
	ok(not st.has("rf"), "consumed reflect → no rf key")
	ok(not st.has("nx"), "consumed nextdmg → no nx key")

	# ---- 4b. corpses ship NO st: Sim freezes a dead fighter's timers, so emission is alive-gated ----
	fa["alive"] = false
	ok(srv.status_st(fa).is_empty(), "dead fighter → empty st (frozen death-time statuses not shipped)")
	fa["alive"] = true

	# ---- 5. snapshot wiring + STRICT no-mutation (byte-hash the whole world around it) ----
	var pre := var_to_bytes(w)
	snap = srv._snapshot_for(w, amap, Vector2(float(fa["x"]), float(fa["y"])), {})
	ok(var_to_bytes(w) == pre, "snapshot building does NOT mutate the world (byte-identical)")
	entry = {}
	for d in snap["fighters"]:
		if str(d["id"]) == str(a["fid"]):
			entry = d
	ok(entry.has("st") and entry["st"] == st, "snapshot st matches the helper output")
	var bob_entry := {}
	for d in snap["fighters"]:
		if str(d["id"]) == str(b["fid"]):
			bob_entry = d
	ok(not bob_entry.is_empty() and not bob_entry.has("st"), "clean OTHER fighter still has no st key")

	# ---- 6. party roster mirror (members + cross-zone tolerance) ----
	srv._session[1]["party"] = [1, 2]
	srv._session[2]["party"] = [1, 2]
	var roster: Array = srv._party_roster(2)          # Bob's roster includes buffed Alice
	var arow := {}
	for r in roster:
		if str(r["fid"]) == str(a["fid"]):
			arow = r
	ok(not arow.is_empty() and arow.get("st") == st, "party roster mirrors Alice's st")
	var brow := {}
	for r in roster:
		if str(r["fid"]) == str(b["fid"]):
			brow = r
	ok(not brow.is_empty() and not brow.has("st"), "clean party member → no st in roster")
	var real_fid: String = str(srv._session[2]["fid"])
	srv._session[2]["fid"] = "gone-elsewhere"          # cross-zone/missing fighter → placeholder row, no crash
	roster = srv._party_roster(1)
	var gone := {}
	for r in roster:
		if str(r["fid"]) == "gone-elsewhere":
			gone = r
	ok(not gone.is_empty() and not gone.has("st") and int(gone["hp"]) == 0, "missing member fighter → placeholder, no st, no crash")
	srv._session[2]["fid"] = real_fid

	finish("stab_status")
