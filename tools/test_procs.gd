extends SceneTree
## Proc-chance + tick-coalescing tests (the Embermaw/searing fix).
## Run: godot --headless --path . --script res://tools/test_procs.gd
## Asserts:
##  1. chance-gated procs fire at ~their chance (searing 0.18), and a failed roll doesn't consume ICD
##  2. procs draw NOTHING from state.rng — a fighter WITH a proc leaves the main stream byte-identical
##  3. DOT tick damage emits NO per-tick events, no flash strobe; coalesced "burn" events ~1/sec, proc-tagged
##  4. the DOT still deals its damage (hp drops) and expires on schedule

const Sim = preload("res://shared/Sim.gd")
const Combat = preload("res://shared/Combat.gd")
const GameData = preload("res://shared/GameData.gd")

var fails := 0

func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  — " + detail))
	if not ok:
		fails += 1

func _init() -> void:
	_test_chance_rate()
	_test_rng_stream_identity()
	_test_tick_coalescing()
	print("RESULT: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)

# --- 1. the deterministic roll fires at ~chance across many distinct ticks -----------------------
func _test_chance_rate() -> void:
	var state = Sim.create_match(["batter"], ["setter"], 42, "stadium")
	var a = state["fighters"][0]
	var b = state["fighters"][1]
	a["procs"] = [{"id": "searing", "effect": "DOT", "trigger": "on_hit", "amt": 5.0,
		"icd": 0.0, "dur": 3.0, "chance": 0.18}]
	var fired := 0
	var trials := 4000
	for i in trials:
		state["t"] = float(i) / 30.0                 # a distinct sim tick per trial
		b["dots"] = []
		Combat._resolve_procs(state, a, b, false, false, 10.0)
		if (b["dots"] as Array).size() > 0:
			fired += 1
	var rate := float(fired) / float(trials)
	check("chance rate ~0.18 (got %.3f)" % rate, rate > 0.14 and rate < 0.22, "outside [0.14, 0.22]")
	# same-tick hits on DIFFERENT targets must roll independently (an AoE procs per hit, not per swing)
	var st2 = Sim.create_match(["batter"], ["setter", "spiker"], 43, "stadium")
	var a2 = st2["fighters"][0]
	var b2 = st2["fighters"][1]
	var c2 = st2["fighters"][2]
	a2["procs"] = [{"id": "searing", "effect": "DOT", "trigger": "on_hit", "amt": 5.0,
		"icd": 0.0, "dur": 3.0, "chance": 0.18}]
	var only_one := 0
	for i in 2000:
		st2["t"] = float(i) / 30.0
		b2["dots"] = []
		c2["dots"] = []
		Combat._resolve_procs(st2, a2, b2, false, false, 10.0)
		Combat._resolve_procs(st2, a2, c2, false, false, 10.0)
		if ((b2["dots"] as Array).size() > 0) != ((c2["dots"] as Array).size() > 0):
			only_one += 1
	check("same-tick rolls independent per target (%d/2000 split)" % only_one, only_one > 100, "targets fully correlated")
	# failed roll must not consume the ICD: with icd huge, the FIRST successful roll sets it —
	# rolls that failed before it must not have blocked that success (fired > 0 with icd 0 shown above);
	# now verify a failed roll leaves _procT untouched.
	a["procs"][0]["icd"] = 99.0
	a["_procT"] = {}
	state["t"] = 0.0
	var t := 0.0
	while (a["_procT"] as Dictionary).get("searing", 0.0) == 0.0 and t < 200.0:
		t += 1.0 / 30.0
		state["t"] = t
		b["dots"] = []
		Combat._resolve_procs(state, a, b, false, false, 10.0)
		if (b["dots"] as Array).size() == 0:
			check("failed roll leaves ICD unset", float((a["_procT"] as Dictionary).get("searing", 0.0)) == 0.0, "ICD set without a proc")
			if fails > 0: break
	check("proc eventually fires and sets ICD", float((a["_procT"] as Dictionary).get("searing", 0.0)) > 0.0, "never fired in 200s of ticks")

# --- 2. equipping a proc must not perturb the main rng stream ------------------------------------
func _test_rng_stream_identity() -> void:
	var s1 = Sim.run_headless_match(["batter", "batter"], ["setter", "setter"], 7, "stadium")
	# same duel, but team-A fighters carry the searing proc (fires + applies DOTs along the way)
	var state = Sim.create_match(["batter", "batter"], ["setter", "setter"], 7, "stadium")
	for f in state["fighters"]:
		if f["team"] == 0:
			f["procs"] = [{"id": "searing", "effect": "DOT", "trigger": "on_hit", "amt": 5.0,
				"icd": 4.0, "dur": 3.0, "chance": 0.18}]
	var dt := 1.0 / 30.0
	var guard := 0
	while state["winner"] == null and guard < 30 * 240:
		Sim.sim_tick(state, dt)
		guard += 1
	var s2_rng: int = state["rng"]._a
	# replay the no-proc match manually to read its rng state at ITS end (run_headless_match doesn't return it)
	var state0 = Sim.create_match(["batter", "batter"], ["setter", "setter"], 7, "stadium")
	guard = 0
	while state0["winner"] == null and guard < 30 * 240:
		Sim.sim_tick(state0, dt)
		guard += 1
	# The proc run deals extra DOT damage → the fight can end EARLIER, so end-state rng positions can
	# differ by fight length. The real invariant: tick-for-tick, both draw the same rng. Compare at the
	# EARLIER of the two fight ends.
	var stateA = Sim.create_match(["batter", "batter"], ["setter", "setter"], 7, "stadium")
	var stateB = Sim.create_match(["batter", "batter"], ["setter", "setter"], 7, "stadium")
	for f in stateB["fighters"]:
		if f["team"] == 0:
			f["procs"] = [{"id": "searing", "effect": "DOT", "trigger": "on_hit", "amt": 5.0,
				"icd": 4.0, "dur": 3.0, "chance": 0.18}]
	var same := true
	var ticks := 0
	while stateA["winner"] == null and stateB["winner"] == null and ticks < 30 * 240:
		Sim.sim_tick(stateA, dt)
		Sim.sim_tick(stateB, dt)
		ticks += 1
		if stateA["rng"]._a != stateB["rng"]._a:
			same = false
			break
	check("rng stream identical with vs without procs (%d ticks)" % ticks, same, "streams diverged at tick %d" % ticks)
	check("proc duel actually ran (winner or 240s)", ticks > 30, "duel ended immediately")
	# silence unused warnings-by-eye (s1/s2_rng retained for debugging)
	if s1 == null and s2_rng == 0: pass

# --- 3. DOT ticks coalesce: no per-tick events, no flash strobe, ~1 burn event/sec ---------------
func _test_tick_coalescing() -> void:
	var state = Sim.create_match(["batter"], ["setter"], 99, "stadium")
	state["botsFrozen"] = true                        # nobody attacks — only the DOT acts
	var a = state["fighters"][0]
	var b = state["fighters"][1]
	b["dots"] = [{"src": a["id"], "dps": 6.0, "remaining": 3.0, "proc": "searing"}]
	var dt := 1.0 / 30.0
	var hp0: float = b["hp"]
	var burn_events := 0
	var untagged_dmg := 0
	var flash_seen := false
	var t := 0.0
	while t < 4.0:
		Sim.sim_tick(state, dt)
		t += dt
		for ev in state["events"]:
			if str(ev.get("type", "")) == "dmg" and str(ev.get("tgt", "")) == str(b["id"]):
				if bool(ev.get("proc", false)):
					burn_events += 1
				else:
					untagged_dmg += 1
		state["events"].clear()
		if float(b["flash"]) > 0.0:
			flash_seen = true
	check("no per-tick dmg events (untagged=0)", untagged_dmg == 0, "%d untagged events" % untagged_dmg)
	check("burn events coalesced ~1/sec (got %d in a 3s DOT)" % burn_events, burn_events >= 2 and burn_events <= 4, "expected 2-4")
	check("no flash strobe from DOT ticks", not flash_seen, "flash was set by a tick")
	check("DOT dealt damage (hp %d -> %d)" % [int(hp0), int(b["hp"])], b["hp"] < hp0, "hp unchanged")
	check("DOT expired", (b["dots"] as Array).is_empty(), "dots not cleared")
