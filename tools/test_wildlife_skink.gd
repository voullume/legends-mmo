extends SceneTree
## W2 vertical-slice sim test (docs/wildlife-expanse-zone2-plan.md): the Netvine Skink def runs
## the deterministic engine correctly — def shape, melee basic damages, Net Snare casts and lands
## its slow, death terminates, and the same seed replays byte-identically. Pure shared/-layer test
## (no server, no rendering): headless via  godot --headless --path . --script res://tools/test_wildlife_skink.gd

const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")

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
	print("== netvine_skink vertical-slice sim test ==")
	# --- def shape ------------------------------------------------------------------------------
	ok(GameData.CLASSES.has("netvine_skink"), "def exists")
	var d: Dictionary = GameData.CLASSES["netvine_skink"]
	ok(bool(d.get("mob", false)) and bool(d.get("rig", false)), "flagged mob + rig")
	ok(str(d.get("model", "")) == "netvine_skink", "model id matches staged GLB")
	var abs_: Array = d["abilities"]
	ok(abs_.size() == 2, "exactly 2 abilities")
	ok(abs_[0]["type"] == "melee" and bool(abs_[0].get("basic", false)), "basic is melee (AI desired_range = melee)")
	ok(abs_[1]["type"] == "projectile" and abs_[1].has("range") and abs_[1].has("speed"), "netsnare projectile carries range+speed")
	ok((abs_[1]["slow"] as Dictionary).has("amt") and (abs_[1]["slow"] as Dictionary).has("dur"), "netsnare slow rider well-formed")
	ok(not GameData.playable_ids().has("netvine_skink"), "not in the playable roster")

	# --- live sim: 2 skinks vs 2 strikers (seed pinned; deterministic) ---------------------------
	var state = Sim.create_match(["netvine_skink", "netvine_skink"], ["striker", "striker"], 7, "stadium")
	var dt := 1.0 / 30.0
	var saw_vinelash := false
	var saw_netsnare := false
	var saw_slow := false
	var striker_hurt := false
	var guard := 0
	while state["winner"] == null and guard < 30 * 120:
		Sim.sim_tick(state, dt)
		guard += 1
		for f in state["fighters"]:
			if str(f["classId"]) == "netvine_skink":
				if float(f["cds"].get("vinelash", 0.0)) > 0.0: saw_vinelash = true
				if float(f["cds"].get("netsnare", 0.0)) > 0.0: saw_netsnare = true
			else:
				if float(f["slowT"]) > 0.0: saw_slow = true
				if float(f["hp"]) < float(f["maxHP"]) - 0.5: striker_hurt = true
	ok(state["winner"] != null, "fight resolves (winner=%s t=%.1fs)" % [str(state["winner"]), float(state["t"])])
	ok(saw_vinelash, "vine lash cast (basic cooldown observed)")
	ok(saw_netsnare, "net snare cast (special cooldown observed)")
	ok(saw_slow, "net snare slow landed on a striker (slowT > 0)")
	ok(striker_hurt, "skinks dealt real damage")
	var deaths := 0
	for f in state["fighters"]:
		if not f["alive"]: deaths += 1
	ok(deaths > 0, "losing side died terminally (%d dead)" % deaths)

	# --- determinism: identical seeds → identical outcome ----------------------------------------
	var a = Sim.run_headless_match(["netvine_skink", "netvine_skink"], ["striker", "striker"], 7, "stadium")
	var b = Sim.run_headless_match(["netvine_skink", "netvine_skink"], ["striker", "striker"], 7, "stadium")
	ok(a["winner"] == b["winner"] and a["duration"] == b["duration"], "same seed replays identically (w=%s d=%.1f)" % [str(a["winner"]), float(a["duration"])])
	var c = Sim.run_headless_match(["striker", "striker"], ["batter", "batter"], 11, "stadium")
	var e = Sim.run_headless_match(["striker", "striker"], ["batter", "batter"], 11, "stadium")
	ok(c["winner"] == e["winner"] and c["duration"] == e["duration"], "player-only sim still deterministic beside the new def")

	print("[wildlife_skink] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
