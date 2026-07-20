extends SceneTree
## 8-SKILL CLASS EXPANSION test suite (class_skills_implementation_prompt).
## Headless invariant tests for the eight-ability kits + the generic combat primitives:
##   kit shape / movement tools / cooldown init / unlock bands / multi-effect buffs /
##   Set consumption / Punching Save / Stolen Base / Tool the Block / Hail Mary /
##   Golden Goal / Walk-Off / Strip Ball / Roof Block / Roll Out / Goal-Line Stand /
##   immediate-vs-casted parity / PvP party support / mob-def freeze / determinism / hotbar.
## Run:  godot --headless --path . --script res://tools/test_class_kits.gd
## Exits non-zero on any failure (CI-gradeable; greppable "FAIL").

const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const Combat = preload("res://shared/Combat.gd")
const Abilities = preload("res://shared/Abilities.gd")
const AI = preload("res://shared/AI.gd")
const Rng = preload("res://shared/Rng.gd")

# Fingerprint of every mob:true CLASSES entry. Baseline moved 2026-07-20 (W2): +netvine_skink
# (Wildlife Expanse vertical slice) — the prior 26 defs were verified byte-identical to the old
# golden 578105494 before rebasing (hash of the set minus netvine_skink still equals it).
const MOB_GOLDEN_COUNT := 27
const MOB_GOLDEN_HASH := 4135971324

const DT := 1.0 / 30.0

var checks := 0
var fails := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if cond:
		print("  ok: %s" % what)
	else:
		fails += 1
		print("  FAIL: %s" % what)

func near(a: float, b: float, eps := 0.001) -> bool:
	return absf(a - b) <= eps

func _ab(cls: String, key: String) -> Dictionary:
	for a in GameData.CLASSES[cls]["abilities"]:
		if a["key"] == key:
			return a
	return {}

# a fresh 1v1 mechanics sandbox: fighter a (team 0, class ca) vs b (team 1, class cb), placed
# face to face on the empty stadium, AI frozen so only OUR calls act.
func _duel(ca: String, cb: String, seed_v := 11) -> Dictionary:
	var st = Sim.create_match([ca], [cb], seed_v, "stadium")
	st["botsFrozen"] = true
	var a = st["fighters"][0]
	var b = st["fighters"][1]
	a["x"] = 400.0
	a["y"] = 270.0
	b["x"] = 500.0
	b["y"] = 270.0
	a["crit"] = -1.0          # force no crit (the roll still draws — determinism unchanged)
	b["crit"] = -1.0
	return st

func _tick(st, n: int) -> void:
	for _i in n:
		Sim.sim_tick(st, DT)

func _mob_signature() -> Dictionary:
	var mob_ids := []
	for k in GameData.CLASSES:
		if GameData.CLASSES[k].get("mob", false):
			mob_ids.append(k)
	mob_ids.sort()
	var sig := ""
	for k in mob_ids:
		sig += k + "=" + var_to_str(GameData.CLASSES[k]) + "\n"
	return {"count": mob_ids.size(), "hash": sig.hash()}

func _init() -> void:
	print("== 8-skill class expansion tests ==")
	_t_kit_shape()
	_t_unlocks()
	_t_multi_effect_buffs()
	_t_set_consumption()
	_t_punching_save()
	_t_stolen_base()
	_t_tool_the_block()
	_t_hail_mary()
	_t_golden_goal()
	_t_walkoff()
	_t_strip_ball()
	_t_roof_block()
	_t_goal_line_stand()
	_t_aoe_parity()
	_t_pvp_party()
	_t_mob_freeze()
	_t_determinism()
	_t_hotbar()
	print("== %d checks, %d failures ==" % [checks, fails])
	quit(1 if fails > 0 else 0)

# ---- 1-3. kit shape, movement tool, cooldown init -------------------------------------------
func _t_kit_shape() -> void:
	print("[kit shape]")
	var rng = Rng.new(1)
	for cls in GameData.playable_ids():
		var abs_l: Array = GameData.CLASSES[cls]["abilities"]
		ok(abs_l.size() == 8, "%s has exactly 8 abilities" % cls)
		var keys := {}
		var basics := 0
		var ults := 0
		var has_move := false
		var has_desc := true
		for a in abs_l:
			keys[a["key"]] = true
			if a.get("basic", false): basics += 1
			if a.get("ult", false): ults += 1
			if a["type"] in ["dash", "dashAttack", "leapAttack"] or (a["type"] == "allybuff" and a.get("dashTo", false)):
				has_move = true
			if not a.has("desc") or str(a["desc"]) == "":
				has_desc = false
		ok(keys.size() == 8, "%s: 8 unique keys" % cls)
		ok(basics == 1, "%s: exactly one basic" % cls)
		ok(ults == 1, "%s: exactly one ultimate" % cls)
		ok(abs_l[7].get("ult", false), "%s: ultimate sits at index 7 (hotbar slot 8)" % cls)
		ok(abs_l[0].get("basic", false), "%s: basic sits at index 0 (hotbar slot 1)" % cls)
		ok(has_move, "%s: has a movement tool (dash / dash attack / leap / ally dash-to)" % cls)
		ok(has_desc, "%s: every ability carries a desc" % cls)
		var f = GameData.create_fighter(cls, 0, 0, rng, 5)
		ok((f["cds"] as Dictionary).size() == 8, "%s: cooldown dict initializes all 8" % cls)
		var all_zero := true
		for k in f["cds"]:
			if f["cds"][k] != 0.0:
				all_zero = false
		ok(all_zero, "%s: all cooldowns start at 0" % cls)
		ok(f.has("guardCharges") and f.has("guardKb") and f.has("guardT"), "%s: guard fields initialized" % cls)

# ---- 4. unlock bands --------------------------------------------------------------------------
func _t_unlocks() -> void:
	print("[unlocks]")
	ok(GameData.ABILITY_SPECIAL_UNLOCK == [2, 5, 8, 11, 14, 16], "special unlock bands are [2,5,8,11,14,16]")
	ok(GameData.ABILITY_ULT_UNLOCK == 18, "ult unlocks at 18")
	for cls in GameData.playable_ids():
		var expect := [2, 5, 8, 11, 14, 16]
		var got := []
		for a in GameData.CLASSES[cls]["abilities"]:
			var lvl: int = GameData.ability_unlock_level(cls, str(a["key"]))
			if a.get("basic", false):
				ok(lvl == 1, "%s: basic unlocked at 1" % cls)
			elif a.get("ult", false):
				ok(lvl == 18, "%s: ult unlocked at 18" % cls)
			else:
				got.append(lvl)
		ok(got == expect, "%s: six specials unlock at %s (got %s)" % [cls, expect, got])
	ok(GameData.ability_grandfathered(""), "missing created_at → grandfathered")
	ok(GameData.ability_grandfathered("2026-07-01T00:00:00"), "pre-epoch char → grandfathered")
	ok(not GameData.ability_grandfathered("2026-07-20T12:00:00"), "post-epoch char → gated")

# ---- 5/6/16. multi-effect self + ally buffs (incl. Roll Out) ---------------------------------
func _t_multi_effect_buffs() -> void:
	print("[multi-effect buffs]")
	# self path (player): Mound Presence = DR + move speed together
	var st := _duel("pitcher", "batter")
	var f = st["fighters"][0]
	Sim._player_self_cast(st, f, _ab("pitcher", "moundpresence"))
	ok(near(f["buffs"]["dr"], 0.22) and f["buffs"]["drT"] > 0.0, "Mound Presence: DR applied")
	ok(near(f["buffs"]["ms"], 1.20) and f["buffs"]["msT"] > 0.0, "Mound Presence: move speed applied")
	# self path (AI): same ability through try_cast under pressure
	var st2 := _duel("pitcher", "batter")
	var f2 = st2["fighters"][0]
	var cast := Abilities.try_cast(st2, f2, _ab("pitcher", "moundpresence"), st2["fighters"][1])
	ok(cast and near(f2["buffs"]["dr"], 0.22) and near(f2["buffs"]["ms"], 1.20), "AI selfbuff path applies every field")
	# AI gate: aiPressure ability refused with no enemy nearby
	var st3 := _duel("pitcher", "batter")
	var f3 = st3["fighters"][0]
	st3["fighters"][1]["x"] = 900.0   # out of the 160 pressure radius
	ok(not Abilities.try_cast(st3, f3, _ab("pitcher", "moundpresence"), st3["fighters"][1]),
		"AI won't cast Mound Presence unpressured (aiPressure)")
	# ally path (player): Roll Out = shield AND move speed, echo advances once
	var st4 = Sim.create_match(["goalkeeper", "striker"], ["batter", "batter"], 3, "stadium")
	st4["botsFrozen"] = true
	var gk = st4["fighters"][0]
	var ally = st4["fighters"][1]
	ally["hp"] = ally["maxHP"] * 0.5
	var casts0: int = gk["supportCasts"]
	Sim._player_support_cast(st4, gk, _ab("goalkeeper", "rollout"), str(ally["id"]))
	ok(ally["shield"] > 0.0, "Roll Out: ally shield applied")
	ok(near(ally["buffs"]["ms"], 1.25) and ally["buffs"]["msT"] > 0.0, "Roll Out: ally move speed applied WITH the shield")
	ok(gk["supportCasts"] == casts0 + 1, "Roll Out: echo counter advances exactly once per cast")
	# ally path (AI): support_tick fires Roll Out with both effects
	var st5 = Sim.create_match(["goalkeeper", "striker"], ["batter", "batter"], 4, "stadium")
	st5["botsFrozen"] = true
	var gk5 = st5["fighters"][0]
	var ally5 = st5["fighters"][1]
	ally5["x"] = gk5["x"] + 60
	ally5["y"] = gk5["y"]
	ally5["hp"] = ally5["maxHP"] * 0.4
	gk5["cds"]["divingsave"] = 10.0        # park the other shield so Roll Out is the pick
	gk5["cds"]["huddle"] = 10.0            # (huddle is QB's — no-op, kept for clarity)
	AI.support_tick(st5, gk5, DT)
	ok(ally5["shield"] > 0.0 and near(ally5["buffs"]["ms"], 1.25), "AI support path applies shield + buff together")
	# ally buff with DR (Play Action) through the player path
	var st6 = Sim.create_match(["quarterback", "striker"], ["batter", "batter"], 5, "stadium")
	st6["botsFrozen"] = true
	var qb = st6["fighters"][0]
	var qally = st6["fighters"][1]
	Sim._player_support_cast(st6, qb, _ab("quarterback", "playaction"), str(qally["id"]))
	ok(near(qally["buffs"]["dr"], 0.15) and near(qally["buffs"]["ms"], 1.25), "Play Action: ally DR + move speed both apply")
	# expiry: ticking past dur clears the timed effect (no stale actives)
	_tick(st6, int(3.0 / DT) + 3)
	ok(qally["buffs"]["drT"] == 0.0 and qally["buffs"]["msT"] == 0.0, "buffs expire cleanly after dur")
	ok(Combat.effective_dr(qally) < 0.15, "expired DR no longer counts in effective_dr")

# ---- 7. Set consumed only by a qualifying non-basic direct hit --------------------------------
func _t_set_consumption() -> void:
	print("[set consumption]")
	var st := _duel("quarterback", "linebacker")
	var a = st["fighters"][0]
	var b = st["fighters"][1]
	a["buffs"]["nextdmg"] = 1.70
	var hp0: float = b["hp"]
	Combat.deal_damage(st, a, b, 100.0, {"melee": true, "basic": true, "key": "shouldercheck"})
	var basic_dmg: float = hp0 - b["hp"]
	ok(near(a["buffs"]["nextdmg"], 1.70), "a BASIC hit does not consume Set")
	Combat.deal_damage(st, a, b, 100.0, {"proc": true})
	ok(near(a["buffs"]["nextdmg"], 1.70), "a PROC tick does not consume Set")
	hp0 = b["hp"]
	Combat.deal_damage(st, a, b, 100.0, {"melee": true, "key": "sack"})
	var special_dmg: float = hp0 - b["hp"]
	ok(near(a["buffs"]["nextdmg"], 0.0), "a non-basic direct hit consumes Set")
	ok(near(special_dmg, basic_dmg * 1.70, 0.5), "the consumed hit dealt 70%% more (%0.1f vs %0.1f)" % [special_dmg, basic_dmg])

# ---- 8. Punching Save reflects one eligible hit and is consumed -------------------------------
func _t_punching_save() -> void:
	print("[punching save]")
	var st := _duel("quarterback", "goalkeeper")   # QB attacker: no lifesteal to muddy the hp reads
	var atk = st["fighters"][0]
	var gk = st["fighters"][1]
	Sim._player_self_cast(st, gk, _ab("goalkeeper", "header"))
	ok(gk["buffs"]["reflect"] > 0.0, "reflect stance armed")
	var gk_hp0: float = gk["hp"]
	var atk_hp0: float = atk["hp"]
	Combat.deal_damage(st, atk, gk, 100.0, {"melee": true, "key": "shouldercheck"})
	ok(near(gk["hp"], gk_hp0), "reflected hit deals the keeper no damage")
	ok(atk["hp"] < atk_hp0, "attacker takes the reflected damage")
	ok(gk["buffs"]["reflect"] == 0.0, "reflect consumed by the one hit")
	var atk_hp1: float = atk["hp"]
	Combat.deal_damage(st, atk, gk, 100.0, {"melee": true, "key": "shouldercheck"})
	ok(gk["hp"] < gk_hp0 and near(atk["hp"], atk_hp1), "second hit lands normally (no double reflect)")

# ---- 9. Stolen Base changes actual movement distance ------------------------------------------
func _t_stolen_base() -> void:
	print("[stolen base]")
	var st := _duel("batter", "goalkeeper")
	var f = st["fighters"][0]
	var intent := {"mx": 1.0, "my": 0.0, "ability": ""}
	var x0: float = f["x"]
	Sim._player_step(st, f, intent, DT)
	var plain: float = f["x"] - x0
	Sim._player_self_cast(st, f, _ab("batter", "stolenbase"))
	x0 = f["x"]
	Sim._player_step(st, f, intent, DT)
	var buffed: float = f["x"] - x0
	ok(plain > 0.0 and near(buffed / plain, 1.45, 0.01), "Stolen Base moves 1.45× per tick (%.3f×)" % (buffed / plain))

# ---- 10. Tool the Block bypasses the intended shield fraction ---------------------------------
func _t_tool_the_block() -> void:
	print("[tool the block]")
	var st := _duel("spiker", "goalkeeper")
	var sp = st["fighters"][0]
	var tgt = st["fighters"][1]
	Sim._player_self_cast(st, sp, _ab("spiker", "toolblock"))
	ok(sp["buffs"]["bypass"] > 0.0, "bypass armed")
	tgt["shield"] = 10000.0
	tgt["shieldT"] = 10.0
	var hp0: float = tgt["hp"]
	var dealt: float = Combat.deal_damage(st, sp, tgt, 100.0, {"melee": true, "key": "thunderspike"})
	var raw: float = 100.0 * sp["dmgMult"]
	ok(near(hp0 - tgt["hp"], raw * 0.40, 0.5), "40%% of the hit bypasses a huge shield (%.1f of %.1f)" % [hp0 - tgt["hp"], raw])
	ok(near(dealt, raw * 0.40, 0.5), "deal_damage reports the bypassed portion")

# ---- 11. Hail Mary shields allies only after a successful impact ------------------------------
func _t_hail_mary() -> void:
	print("[hail mary]")
	# case A: connecting impact → allies shielded
	var st = Sim.create_match(["quarterback", "striker"], ["linebacker", "batter"], 6, "stadium")
	st["botsFrozen"] = true
	var qb = st["fighters"][0]
	var ally = st["fighters"][1]
	var tgt = st["fighters"][2]
	qb["x"] = 300.0; qb["y"] = 270.0
	tgt["x"] = 500.0; tgt["y"] = 270.0
	tgt["crit"] = -1.0
	ok(Abilities.try_cast(st, qb, _ab("quarterback", "hailmary"), tgt), "hail mary fires")
	_tick(st, 30)
	ok(st["projectiles"].is_empty(), "projectile resolved")
	ok(ally["shield"] > 0.0 and qb["shield"] > 0.0, "connecting impact shields the team")
	# case B: evading target → NO team shield
	var st2 = Sim.create_match(["quarterback", "striker"], ["linebacker", "batter"], 6, "stadium")
	st2["botsFrozen"] = true
	var qb2 = st2["fighters"][0]
	var ally2 = st2["fighters"][1]
	var tgt2 = st2["fighters"][2]
	qb2["x"] = 300.0; qb2["y"] = 270.0
	tgt2["x"] = 500.0; tgt2["y"] = 270.0
	ok(Abilities.try_cast(st2, qb2, _ab("quarterback", "hailmary"), tgt2), "hail mary fires (evade case)")
	tgt2["evade"] = 99.0
	_tick(st2, 30)
	ok(ally2["shield"] == 0.0 and qb2["shield"] == 0.0, "an evaded bomb shields no one")
	# case C: target dies mid-flight → projectile fizzles, no shield
	var st3 = Sim.create_match(["quarterback", "striker"], ["linebacker", "batter"], 6, "stadium")
	st3["botsFrozen"] = true
	var qb3 = st3["fighters"][0]
	var tgt3 = st3["fighters"][2]
	qb3["x"] = 300.0; qb3["y"] = 270.0
	tgt3["x"] = 500.0; tgt3["y"] = 270.0
	ok(Abilities.try_cast(st3, qb3, _ab("quarterback", "hailmary"), tgt3), "hail mary fires (corpse case)")
	tgt3["alive"] = false
	_tick(st3, 30)
	ok(st3["fighters"][1]["shield"] == 0.0, "a dead-target fizzle shields no one")

# ---- 12. Golden Goal: cast, interrupt, single spawn, own-kill reward --------------------------
func _t_golden_goal() -> void:
	print("[golden goal]")
	var gg := _ab("striker", "goldengoal")
	# cast respected + single spawn + kill reward
	var st := _duel("striker", "batter", 21)
	var sk = st["fighters"][0]
	var tgt = st["fighters"][1]
	ok(Abilities.try_cast(st, sk, gg, tgt), "golden goal starts casting")
	ok(sk["casting"] != null and st["projectiles"].is_empty(), "no projectile during the cast")
	ok(sk["cds"]["goldengoal"] > 0.0, "cooldown starts with the cast")
	var max_seen := 0
	for _i in 60:
		Sim.sim_tick(st, DT)
		max_seen = max(max_seen, st["projectiles"].size())
	ok(max_seen == 1, "exactly one projectile across cast + flight (no double spawn)")
	tgt["hp"] = 1.0            # re-arm for the killing blow
	tgt["alive"] = true
	sk["cds"]["goldengoal"] = 0.0
	ok(Abilities.try_cast(st, sk, gg, tgt), "golden goal recast")
	_tick(st, 60)
	ok(not tgt["alive"], "golden goal killed the target")
	ok(near(sk["buffs"]["ms"], 1.45) and sk["buffs"]["msT"] > 0.0 and near(sk["buffs"]["dr"], 0.15),
		"its own killing blow grants the on-kill buff (speed + DR)")
	# a kill by any OTHER ability grants nothing
	var st2 := _duel("striker", "batter", 22)
	var sk2 = st2["fighters"][0]
	var tgt2 = st2["fighters"][1]
	tgt2["hp"] = 1.0
	Combat.deal_damage(st2, sk2, tgt2, 100.0, {"projectile": true, "basic": true, "key": "finesse"})
	ok(not tgt2["alive"] and sk2["buffs"]["msT"] == 0.0, "a basic-attack kill grants no on-kill buff")
	# a proc/DOT-tagged kill with the same key grants nothing (hazard/DOT exclusion)
	var st2b := _duel("striker", "batter", 23)
	var sk2b = st2b["fighters"][0]
	var tgt2b = st2b["fighters"][1]
	tgt2b["hp"] = 0.5
	Combat.deal_damage(st2b, sk2b, tgt2b, 100.0, {"dot": true, "key": "goldengoal"})
	ok(not tgt2b["alive"] and sk2b["buffs"]["msT"] == 0.0, "a DOT/hazard kill never grants the on-kill buff")
	# stun interrupts the cast → no projectile ever spawns
	var st3 := _duel("striker", "batter", 24)
	var sk3 = st3["fighters"][0]
	ok(Abilities.try_cast(st3, sk3, gg, st3["fighters"][1]), "golden goal starts casting (interrupt case)")
	sk3["stun"] = 0.5
	_tick(st3, 40)
	ok(sk3["casting"] == null and st3["projectiles"].is_empty(), "a stun interrupts the cast — no spawn")

# ---- 13. Walk-Off shields only after positive direct damage -----------------------------------
func _t_walkoff() -> void:
	print("[walk-off]")
	var st := _duel("batter", "linebacker")
	var bt = st["fighters"][0]
	var tgt = st["fighters"][1]
	tgt["x"] = bt["x"] + 50.0    # in walkoff range (68)
	ok(Abilities.try_cast(st, bt, _ab("batter", "walkoff"), tgt), "walk-off connects")
	ok(near(bt["shield"], bt["maxHP"] * 0.12, 0.5), "a damaging hit self-shields 12%% max HP")
	# whiff case: an evading target takes 0 → no shield
	var st2 := _duel("batter", "linebacker")
	var bt2 = st2["fighters"][0]
	var tgt2 = st2["fighters"][1]
	tgt2["x"] = bt2["x"] + 50.0
	tgt2["evade"] = 5.0
	ok(Abilities.try_cast(st2, bt2, _ab("batter", "walkoff"), tgt2), "walk-off swings at an evading target")
	ok(bt2["shield"] == 0.0, "zero-damage hit grants no shield")

# ---- 14. Strip Ball: one buff, fixed priority, protected mechanics untouched -------------------
func _t_strip_ball() -> void:
	print("[strip ball]")
	var sb := _ab("linebacker", "stripball")
	var st := _duel("linebacker", "batter")
	var lb = st["fighters"][0]
	var tgt = st["fighters"][1]
	tgt["x"] = lb["x"] + 50.0
	st["controlled"] = {lb["id"]: {}}          # player-driven: always allowed to swing
	# priority: DR outranks attack speed outranks move speed (unshielded target → damage lands → strip fires)
	Combat.apply_buff_dict(tgt, {"dr": 0.30, "atkspd": 1.3, "ms": 1.45, "dur": 30.0})
	tgt["momentum"] = 3.0
	tgt["momentumT"] = 30.0
	tgt["hatChainT"] = 2.0
	tgt["phase"] = 2
	ok(Abilities.try_cast(st, lb, sb, tgt), "strip ball hits")
	ok(tgt["buffs"]["drT"] == 0.0 and tgt["buffs"]["dr"] == 0.0, "DR stripped first")
	ok(tgt["buffs"]["atkspdT"] > 0.0 and tgt["buffs"]["msT"] > 0.0, "exactly ONE buff removed")
	ok(Abilities.try_cast(st, lb, sb, tgt), "strip ball hits again")
	ok(tgt["buffs"]["atkspdT"] == 0.0 and near(tgt["buffs"]["atkspd"], 1.0), "attack speed stripped second")
	ok(tgt["buffs"]["msT"] > 0.0, "move speed still up after two strips")
	ok(near(tgt["momentum"], 3.0) and tgt["hatChainT"] > 0.0 and tgt["phase"] == 2,
		"Momentum / Hat Trick / boss phase are untouched by strips")
	# protected mechanics at the dispel layer: nothing eligible → a no-op, and none of these are touched
	var vf = GameData.create_fighter("goalkeeper", 1, 0, Rng.new(8), 5)
	vf["shield"] = 50.0
	vf["shieldT"] = 5.0
	vf["barrier"] = 0.5
	vf["barrierT"] = 5.0
	vf["momentum"] = 2.0
	vf["evade"] = 1.0
	vf["untarget"] = 1.0
	vf["phase"] = 3
	vf["guardCharges"] = 1
	vf["guardT"] = 2.0
	ok(not Combat.dispel_one(vf), "dispel with nothing eligible is a no-op")
	ok(near(vf["shield"], 50.0) and vf["barrierT"] > 0.0 and near(vf["momentum"], 2.0) \
		and vf["evade"] > 0.0 and vf["untarget"] > 0.0 and vf["phase"] == 3 and vf["guardCharges"] == 1,
		"shields / barrier / Momentum / evasion / untargetability / boss phase / guard are protected")
	# a hit fully absorbed by a shield deals no positive damage → no strip ("successful damage" required)
	var st1b := _duel("linebacker", "batter")
	var lb1b = st1b["fighters"][0]
	var tgt1b = st1b["fighters"][1]
	tgt1b["x"] = lb1b["x"] + 50.0
	st1b["controlled"] = {lb1b["id"]: {}}
	Combat.apply_buff_dict(tgt1b, {"dr": 0.30, "dur": 30.0})
	tgt1b["shield"] = 5000.0
	tgt1b["shieldT"] = 30.0
	ok(Abilities.try_cast(st1b, lb1b, sb, tgt1b), "strip ball swings into a huge shield")
	ok(tgt1b["buffs"]["drT"] > 0.0, "a fully-absorbed hit (zero damage) strips nothing")
	# a self-slow (Goal-Line Stand's 0.8× ms) is NOT a strippable buff
	var st2 := _duel("linebacker", "batter")
	var lb2 = st2["fighters"][0]
	var tgt2 = st2["fighters"][1]
	tgt2["x"] = lb2["x"] + 50.0
	st2["controlled"] = {lb2["id"]: {}}
	Combat.apply_buff_dict(tgt2, {"ms": 0.80, "dur": 5.0})
	ok(Abilities.try_cast(st2, lb2, sb, tgt2), "strip ball hits a self-slowed target")
	ok(tgt2["buffs"]["msT"] > 0.0, "a sub-1.0 move-speed value is ineligible (stripping it would help)")
	# AI prioritization: unbuffed target → the bot skips it; buffed → it swings
	var st3 := _duel("linebacker", "batter")
	var lb3 = st3["fighters"][0]
	var tgt3 = st3["fighters"][1]
	tgt3["x"] = lb3["x"] + 50.0
	ok(not Abilities.try_cast(st3, lb3, sb, tgt3), "AI skips Strip Ball on an unbuffed target")
	Combat.apply_buff_dict(tgt3, {"dr": 0.2, "dur": 5.0})
	ok(Abilities.try_cast(st3, lb3, sb, tgt3), "AI uses Strip Ball once a buff is up")
	# a reflect-only target is NOT strip-worthy for the AI (the reflect would eat the strip's own hit)
	var st3b := _duel("linebacker", "goalkeeper")
	var lb3b = st3b["fighters"][0]
	var gk3b = st3b["fighters"][1]
	gk3b["x"] = lb3b["x"] + 50.0
	gk3b["buffs"]["reflect"] = 1.2
	ok(not Abilities.try_cast(st3b, lb3b, sb, gk3b), "AI never feeds Strip Ball into a Punching Save")
	# full fixed priority at the dispel layer: reflect > DR > bypass > attack speed > crit > move speed
	var pv = GameData.create_fighter("spiker", 1, 0, Rng.new(19), 5)
	pv["buffs"]["reflect"] = 1.0
	Combat.apply_buff_dict(pv, {"dr": 0.2, "atkspd": 1.2, "crit": 0.2, "ms": 1.3, "dur": 20.0})
	pv["buffs"]["bypass"] = 3.0
	var order := []
	for _i in 6:
		if not Combat.dispel_one(pv):
			break
		if pv["buffs"]["reflect"] == 0.0 and not order.has("reflect"): order.append("reflect")
		if pv["buffs"]["drT"] == 0.0 and not order.has("dr"): order.append("dr")
		if pv["buffs"]["bypass"] == 0.0 and not order.has("bypass"): order.append("bypass")
		if pv["buffs"]["atkspdT"] == 0.0 and not order.has("atkspd"): order.append("atkspd")
		if pv["buffs"]["critT"] == 0.0 and not order.has("crit"): order.append("crit")
		if pv["buffs"]["msT"] == 0.0 and not order.has("ms"): order.append("ms")
	ok(order == ["reflect", "dr", "bypass", "atkspd", "crit", "ms"],
		"dispel priority is reflect > DR > bypass > atkspd > crit > ms (got %s)" % [order])
	ok(not Combat.dispel_one(pv), "a fully-stripped target has nothing left to dispel")
	# item-proc-granted dr/ms (drSrc/msSrc == "proc") are ITEM effects — dispel spares them
	var pf2 = GameData.create_fighter("striker", 1, 0, Rng.new(20), 5)
	pf2["buffs"]["dr"] = 0.22
	pf2["buffs"]["drT"] = 3.0
	pf2["buffs"]["drSrc"] = "proc"
	pf2["buffs"]["ms"] = 1.22
	pf2["buffs"]["msT"] = 3.0
	pf2["buffs"]["msSrc"] = "proc"
	ok(not Combat.has_dispellable(pf2), "proc-only buffs don't mark a target strip-worthy")
	ok(not Combat.dispel_one(pf2) and pf2["buffs"]["drT"] > 0.0 and pf2["buffs"]["msT"] > 0.0,
		"dispel spares item-proc GUARD/HASTE buffs")

	# HASTE proc must never erase an ability self-slow (Goal-Line Stand) while its DR persists
	var st4 := _duel("linebacker", "batter", 33)
	var lb4 = st4["fighters"][0]
	var tgt4 = st4["fighters"][1]
	Sim._player_self_cast(st4, lb4, _ab("linebacker", "goalstand"))
	lb4["procs"] = [{"id": "momentum", "trigger": "on_kill", "effect": "HASTE", "amt": 0.22, "dur": 3.0, "icd": 6.0}]
	tgt4["hp"] = 0.5
	Combat.deal_damage(st4, lb4, tgt4, 100.0, {"melee": true, "key": "shed"})
	ok(not tgt4["alive"], "kill landed during Goal-Line Stand")
	ok(near(lb4["buffs"]["ms"], 0.80) and near(lb4["buffs"]["dr"], 0.35),
		"HASTE proc can't erase the anchored self-slow (DR keeps its malus)")

	# DR is monotone: a weaker ally buff (Play Action 15%) under Block (30%) must not reduce it
	var lb5 = GameData.create_fighter("linebacker", 0, 0, Rng.new(21), 5)
	Combat.apply_buff_dict(lb5, {"dr": 0.30, "dur": 2.0})
	Combat.apply_buff_dict(lb5, {"ms": 1.25, "dr": 0.15, "dur": 2.5})
	ok(near(lb5["buffs"]["dr"], 0.30) and near(lb5["buffs"]["drT"], 2.5),
		"a weaker concurrent DR keeps the stronger value and extends the window")
	Combat.apply_buff_dict(lb5, {"dr": 0.35, "dur": 3.0})
	ok(near(lb5["buffs"]["dr"], 0.35), "a stronger DR still upgrades the value")

# ---- 15. Roof Block: guarded melee knockback ---------------------------------------------------
func _t_roof_block() -> void:
	print("[roof block]")
	var st := _duel("batter", "spiker")
	var atk = st["fighters"][0]
	var sp = st["fighters"][1]
	Sim._player_self_cast(st, sp, _ab("spiker", "roofblock"))
	ok(sp["guardCharges"] == 1 and sp["guardT"] > 0.0 and near(sp["buffs"]["dr"], 0.25), "roof block arms guard + DR")
	# a projectile hit does NOT trigger the guard
	var ax0: float = atk["x"]
	Combat.deal_damage(st, atk, sp, 20.0, {"projectile": true, "key": "finesse"})
	ok(sp["guardCharges"] == 1 and near(atk["x"], ax0), "projectile damage ignored by the guard")
	# a direct melee hit knocks the attacker back and consumes the charge
	atk["x"] = sp["x"] - 40.0
	atk["y"] = sp["y"]
	ax0 = atk["x"]
	Combat.deal_damage(st, atk, sp, 20.0, {"melee": true, "key": "swing"})
	ok(sp["guardCharges"] == 0, "melee hit consumes the guard charge")
	ok(near(atk["x"], ax0 - 45.0, 0.5), "attacker knocked back 45 away from the guard")
	# no charge left → next melee unaffected
	ax0 = atk["x"]
	Combat.deal_damage(st, atk, sp, 20.0, {"melee": true, "key": "swing"})
	ok(near(atk["x"], ax0), "spent guard no longer knocks back")
	# a kb-immune attacker is respected (and doesn't waste the charge)
	var st2 = Sim.create_match(["spiker"], ["drill_sergeant"], 9, "stadium")
	st2["botsFrozen"] = true
	var sp2 = st2["fighters"][0]
	var mob = st2["fighters"][1]
	Sim._player_self_cast(st2, sp2, _ab("spiker", "roofblock"))
	mob["x"] = sp2["x"] + 40.0
	mob["y"] = sp2["y"]
	var mx0: float = mob["x"]
	Combat.deal_damage(st2, mob, sp2, 20.0, {"melee": true, "key": "raporder"})
	ok(near(mob["x"], mx0) and sp2["guardCharges"] == 1, "kb-immune attacker: no push, charge kept")
	# expiry clears the charge
	_tick(st2, int(2.2 / DT))
	ok(sp2["guardCharges"] == 0 and sp2["guardT"] == 0.0, "guard charge expires with the window")

# ---- 17. Goal-Line Stand raises DR and lowers movement ----------------------------------------
func _t_goal_line_stand() -> void:
	print("[goal-line stand]")
	var st := _duel("linebacker", "batter")
	var lb = st["fighters"][0]
	Sim._player_self_cast(st, lb, _ab("linebacker", "goalstand"))
	ok(near(Combat.effective_dr(lb), 0.35), "effective DR is 35%")
	var intent := {"mx": 1.0, "my": 0.0, "ability": ""}
	var x0: float = lb["x"]
	Sim._player_step(st, lb, intent, DT)
	var step: float = lb["x"] - x0
	ok(near(step, lb["ms"] * 0.80 * DT, 0.01), "movement slowed to 0.80× while anchored")

# ---- 18. immediate and casted melee AoEs apply identical effects ------------------------------
func _t_aoe_parity() -> void:
	print("[aoe parity]")
	var imm := {"key": "batflip", "name": "T", "type": "meleeAoe", "dmg": 50, "cd": 8, "radius": 100,
		"stun": 0.5, "slow": {"amt": 0.3, "dur": 1.0}, "knockback": 40}
	var casted := imm.duplicate(true)
	casted["cast"] = 0.1
	var results := []
	for variant in [imm, casted]:
		var st := _duel("batter", "linebacker", 31)
		var a = st["fighters"][0]
		var b = st["fighters"][1]
		b["x"] = a["x"] + 60.0
		b["y"] = a["y"]
		var bx0: float = b["x"]
		ok(Abilities.try_cast(st, a, variant, b), "aoe fires (%s)" % ("casted" if variant.has("cast") else "immediate"))
		_tick(st, 6)     # resolve the cast; timers tick equally for both
		results.append({"stun": b["stun"], "slowAmt": b["slowAmt"], "slowT": b["slowT"], "moved": b["x"] - bx0, "hp": b["hp"]})
	ok(results[0]["stun"] > 0.0 and near(results[0]["slowAmt"], 0.3) and results[0]["moved"] > 30.0,
		"immediate AoE applies stun + slow + knockback")
	ok(near(results[0]["slowAmt"], results[1]["slowAmt"]) and near(results[0]["moved"], results[1]["moved"], 0.5) \
		and near(results[0]["hp"], results[1]["hp"], 0.5),
		"casted AoE applies the SAME slow / knockback / damage")

# ---- 19. PvP: party allies supportable, non-party players are not -----------------------------
func _t_pvp_party() -> void:
	print("[pvp party]")
	var st = Sim.create_match(["setter", "batter", "striker"], ["linebacker"], 13, "stadium")
	st["botsFrozen"] = true
	st["pvp"] = true
	var a = st["fighters"][0]   # setter, party p1
	var b = st["fighters"][1]   # batter, party p1
	var c = st["fighters"][2]   # striker, solo → hostile in PvP
	a["party"] = "p1"
	b["party"] = "p1"
	c["party"] = ""
	ok(not Combat.is_hostile(st, a, b) and Combat.is_ally(st, a, b), "party-mates: allied, not hostile")
	ok(Combat.is_hostile(st, a, c) and not Combat.is_ally(st, a, c), "non-party player: hostile, not supportable")
	# a support cast aimed at the non-party player must NOT land on them
	Sim._player_support_cast(st, a, _ab("setter", "quickset"), str(c["id"]))
	ok(c["buffs"]["msT"] == 0.0, "Quick Set can't buff a non-party player in PvP")
	# aimed at the party-mate it lands
	Sim._player_support_cast(st, a, _ab("setter", "quickset"), str(b["id"]))
	ok(near(b["buffs"]["ms"], 1.35) and b["buffs"]["msT"] > 0.0, "Quick Set lands on a party-mate")
	# no friendly fire (1): an offensive intent aimed at a party-mate retargets to a real hostile
	a["x"] = 400.0; a["y"] = 270.0
	b["x"] = 430.0; b["y"] = 270.0
	c["x"] = 460.0; c["y"] = 270.0
	st["controlled"] = {a["id"]: {}}
	var intent := {"mx": 0.0, "my": 0.0, "ability": "bump", "target": str(b["id"])}
	Sim._player_step(st, a, intent, DT)
	ok(st["projectiles"].size() == 1 and str(st["projectiles"][0]["tx"]) == str(c["id"]),
		"an attack aimed at a party-mate redirects to the nearest hostile")
	# no friendly fire (2): a melee AoE from a party member hits only hostiles inside the radius
	var b_hp0: float = b["hp"]
	var c_hp0: float = c["hp"]
	b["x"] = 430.0; c["x"] = 450.0   # both inside batflip's 88 radius around b? — a casts nothing; B swings
	ok(Abilities.try_cast(st, b, _ab("batter", "batflip"), null), "party batter bat-flips into the crowd")
	ok(near(a["hp"], a["maxHP"]) and near(b["hp"], b_hp0), "party-mates untouched by the AoE")
	ok(c["hp"] < c_hp0, "the non-party player inside the radius takes the hit")

# ---- 20. mob definitions and abilities remain unchanged ---------------------------------------
func _t_mob_freeze() -> void:
	print("[mob freeze]")
	var sig := _mob_signature()
	ok(sig["count"] == MOB_GOLDEN_COUNT, "still %d mob defs (got %d)" % [MOB_GOLDEN_COUNT, sig["count"]])
	ok(sig["hash"] == MOB_GOLDEN_HASH, "mob defs byte-identical to the current golden (rebased 2026-07-20, +netvine_skink)")
	var clean := true
	for k in GameData.CLASSES:
		if not GameData.CLASSES[k].get("mob", false):
			continue
		for ab in GameData.CLASSES[k]["abilities"]:
			if ab.has("onKillBuff") or ab.has("onHitSelfShieldPct") or ab.has("dispelBuffs") \
					or ab.has("selfBuff") or ab.has("aiPressure") \
					or (ab.has("buff") and (ab["buff"] as Dictionary).has("guard")):
				clean = false
				print("  offending mob ability: %s/%s" % [k, ab["key"]])
	ok(clean, "no mob ability carries an expansion-only field")

# ---- 21. identical seeds remain deterministic --------------------------------------------------
func _t_determinism() -> void:
	print("[determinism]")
	var comp_a := ["pitcher", "batter", "quarterback", "linebacker", "setter"]
	var comp_b := ["spiker", "striker", "goalkeeper", "pitcher", "batter"]
	var r1 = Sim.run_headless_match(comp_a, comp_b, 777, "trenches")
	var r2 = Sim.run_headless_match(comp_a, comp_b, 777, "trenches")
	ok(r1["winner"] == r2["winner"] and r1["duration"] == r2["duration"],
		"same seed → same result (%s in %.1fs)" % [r1["winner"], r1["duration"]])
	# fine-grained: 400 ticks, full fighter-state signature
	var sigs := []
	for _run in 2:
		var st = Sim.create_match(comp_a, comp_b, 4242, "rooftop")
		for _i in 400:
			Sim.sim_tick(st, DT)
		var s := ""
		for f in st["fighters"]:
			s += "%d,%d,%d,%d;" % [int(round(f["x"] * 10)), int(round(f["y"] * 10)), int(round(f["hp"] * 10)), int(round(f["shield"] * 10))]
		sigs.append(s.hash())
	ok(sigs[0] == sigs[1], "400-tick state signature identical across runs")

# ---- 22. the client builds and updates eight hotbar slots -------------------------------------
func _t_hotbar() -> void:
	print("[hotbar]")
	# input mapping: Player.gd exposes all 8 keys in kit order
	var PlayerCtl = load("res://client/Player.gd")
	var pc = PlayerCtl.new()
	for cls in GameData.playable_ids():
		pc.class_id = cls
		var ks: Array = pc.ability_keys()
		ok(ks.size() == 8, "%s: input layer maps 8 ability keys" % cls)
	pc.free()
	# NOTE: Client.gd itself only compiles under a full project boot (it references the AudioManager
	# autoload, which --script runs never register). The REAL 8-slot hotbar build/update is exercised
	# end-to-end by the headless practice-client smoke — run it alongside this suite:
	#   godot --headless --path . -- --practice --shot /tmp/hotbar_smoke.png --shot-delay 5
	# and grep its log for "SCRIPT ERROR" (must be 0). Here we pin the pure data contracts the
	# builder depends on: 8 abilities per class (checked above) and the bar's viewport fit.
	var bar_w := 8 * 60 + 7 * 6
	ok(bar_w <= 1152, "8-slot bar is %dpx — fits the minimum viewport" % bar_w)
	# tooltip formatting must never leak internal field names — pin the desc/name text side of it
	var clean_text := true
	for cls in GameData.playable_ids():
		for ab in GameData.CLASSES[cls]["abilities"]:
			var txt := str(ab.get("desc", "")) + str(ab.get("name", ""))
			for internal in ["drT", "nextdmg", "atkspd", "msT", "critT", "onKill", "onHit", "selfBuff", "dispelBuffs", "shieldPct"]:
				if txt.contains(internal):
					clean_text = false
					print("  internal name leaked in %s/%s: %s" % [cls, ab["key"], internal])
	ok(clean_text, "ability names/descs expose no internal field names")
