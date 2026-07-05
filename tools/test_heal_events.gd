extends SceneTree
## Heal/shield presentation-event tests (combat-feel Tier 2, item A).
## Run: godot --headless --path . --script res://tools/test_heal_events.gd
## Asserts:
##  1. apply_heal emits exactly ONE "heal" event with the POST-CAP amount; 0-amount cases emit none
##  2. apply_shield emits exactly ONE "shield" event with the boosted amount
##  3. the excluded paths stay silent: melee lifesteal + Goalkeeper clean-sheet regen emit NO events
##  4. a real AI duel with support classes emits heal events organically (the wire-up works end-to-end)

const Sim = preload("res://shared/Sim.gd")
const Combat = preload("res://shared/Combat.gd")
const GameData = preload("res://shared/GameData.gd")

var fails := 0

func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "  — " + detail))
	if not ok:
		fails += 1

func _init() -> void:
	_test_heal_events()
	_test_shield_events()
	_test_excluded_paths_silent()
	_test_live_duel_emits()
	print("RESULT: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)

func _events_of(state, type: String) -> Array:
	var out := []
	for ev in state["events"]:
		if str(ev.get("type", "")) == type:
			out.append(ev)
	return out

# --- 1. apply_heal → one post-cap event; zero-amount heals stay silent ---------------------------
func _test_heal_events() -> void:
	var state = Sim.create_match(["setter"], ["batter"], 42, "stadium")
	var s = state["fighters"][0]
	var b = state["fighters"][1]
	var boost: float = float(GameData.CLASSES["setter"]["supportBoost"])
	# uncapped: boosted amount lands in full
	b["hp"] = b["maxHP"] - 100.0
	state["events"].clear()
	Combat.apply_heal(state, s, b, 30.0)
	var evs := _events_of(state, "heal")
	check("uncapped heal emits exactly one event", evs.size() == 1, "%d events" % evs.size())
	if evs.size() == 1:
		var ev = evs[0]
		check("heal amt = boosted (%d)" % int(round(30.0 * boost)), int(ev["amt"]) == int(round(30.0 * boost)), "got %d" % int(ev["amt"]))
		check("heal src/tgt ids correct", str(ev["src"]) == str(s["id"]) and str(ev["tgt"]) == str(b["id"]), "wrong ids")
		check("heal event carries t", ev.has("t"), "missing t")
	# overheal-capped: the event reads the REAL applied amount, not the boosted cast size
	b["hp"] = b["maxHP"] - 10.0
	state["events"].clear()
	Combat.apply_heal(state, s, b, 30.0)
	evs = _events_of(state, "heal")
	check("capped heal events the post-cap amount (10)", evs.size() == 1 and int(evs[0]["amt"]) == 10, "got %s" % str(evs))
	# full HP → real = 0 → silent
	b["hp"] = b["maxHP"]
	state["events"].clear()
	Combat.apply_heal(state, s, b, 30.0)
	check("full-HP heal emits nothing", _events_of(state, "heal").is_empty(), "event on 0 heal")
	# sub-1 rounding → silent (never a \"+0\" floater)
	b["hp"] = b["maxHP"] - 0.3
	state["events"].clear()
	Combat.apply_heal(state, s, b, 30.0)
	check("heal rounding to 0 emits nothing", _events_of(state, "heal").is_empty(), "event on 0-round heal")
	# dead target → silent
	b["hp"] = 0.0
	b["alive"] = false
	state["events"].clear()
	Combat.apply_heal(state, s, b, 30.0)
	check("dead-target heal emits nothing", _events_of(state, "heal").is_empty(), "event on dead target")
	b["alive"] = true
	b["hp"] = b["maxHP"]

# --- 2. apply_shield → one boosted-amount event ---------------------------------------------------
func _test_shield_events() -> void:
	var state = Sim.create_match(["setter"], ["batter"], 43, "stadium")
	var s = state["fighters"][0]
	var b = state["fighters"][1]
	var boost: float = float(GameData.CLASSES["setter"]["supportBoost"])
	state["events"].clear()
	Combat.apply_shield(state, s, b, 30.0, 2.0)
	var evs := _events_of(state, "shield")
	check("shield emits exactly one event", evs.size() == 1, "%d events" % evs.size())
	if evs.size() == 1:
		check("shield amt = boosted (%d)" % int(round(30.0 * boost)), int(evs[0]["amt"]) == int(round(30.0 * boost)), "got %d" % int(evs[0]["amt"]))
		check("shield src/tgt ids correct", str(evs[0]["src"]) == str(s["id"]) and str(evs[0]["tgt"]) == str(b["id"]), "wrong ids")
	check("shield actually applied", float(b["shield"]) > 0.0, "no shield value")

# --- 3. the deliberately-silent paths: lifesteal + clean-sheet regen ------------------------------
func _test_excluded_paths_silent() -> void:
	# Batter melee lifesteal heals the source through direct hp writes — no heal event
	var state = Sim.create_match(["batter"], ["setter"], 44, "stadium")
	var a = state["fighters"][0]
	var b = state["fighters"][1]
	check("batter has meleeLifesteal (test premise)", GameData.CLASSES["batter"].has("meleeLifesteal"), "class data changed")
	a["hp"] = a["maxHP"] - 100.0
	var hp0: float = a["hp"]
	state["events"].clear()
	Combat.deal_damage(state, a, b, 50.0, {"melee": true})
	check("lifesteal healed the attacker", float(a["hp"]) > hp0, "no heal applied")
	check("lifesteal emits NO heal event", _events_of(state, "heal").is_empty(), "lifesteal evented")
	# Goalkeeper clean-sheet shield regen writes shield directly — no shield events over a full regen
	var st2 = Sim.create_match(["goalkeeper"], ["batter"], 45, "stadium")
	st2["botsFrozen"] = true
	var gk = st2["fighters"][0]
	var dt := 1.0 / 30.0
	var shield_events := 0
	var t := 0.0
	while t < 8.0:
		Sim.sim_tick(st2, dt)
		t += dt
		shield_events += _events_of(st2, "shield").size()
		st2["events"].clear()
	check("clean sheet regenerated (shield %d)" % int(gk["shield"]), float(gk["shield"]) > 0.0, "regen never ran — test premise broken")
	check("clean-sheet regen emits NO shield events", shield_events == 0, "%d events" % shield_events)

# --- 4. a real AI duel with supports emits heal events organically --------------------------------
func _test_live_duel_emits() -> void:
	var state = Sim.create_match(["setter", "batter"], ["setter", "batter"], 7, "stadium")
	var dt := 1.0 / 30.0
	var heals := 0
	var shields := 0
	var bad := 0
	var guard := 0
	while state["winner"] == null and guard < 30 * 240:
		Sim.sim_tick(state, dt)
		guard += 1
		for ev in state["events"]:
			var ty := str(ev.get("type", ""))
			if ty == "heal" or ty == "shield":
				if int(ev.get("amt", 0)) <= 0 or not ev.has("src") or not ev.has("tgt"):
					bad += 1
				if ty == "heal": heals += 1
				else: shields += 1
		state["events"].clear()
	check("AI duel emitted heal events (%d heal / %d shield)" % [heals, shields], heals > 0, "no heals in a setter duel")
	check("all gain events well-formed (amt>0, src+tgt)", bad == 0, "%d malformed" % bad)
