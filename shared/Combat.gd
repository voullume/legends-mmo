extends RefCounted
## Legends of the Arena — damage pipeline.
## Direct port of the web sim's effectiveDR / dealDamage / applyHeal / applyShield.
## `state` is a Dictionary: { "rng": Rng, "t": float, "zones": Array, "fighters": Array, "events": Array }
## Fighters/state are passed by reference (Dictionaries are reference types in GDScript),
## so mutations persist — same as the JS objects.

const GameData := preload("res://shared/GameData.gd")

const OT_START := 50.0

static func _find(fighters: Array, id) -> Variant:
	for f in fighters:
		if f["id"] == id:
			return f
	return null

# effectiveDR — sum of all damage-reduction sources, capped at 0.75.
static func effective_dr(t: Dictionary) -> float:
	var dr := 0.0
	if t["buffs"]["drT"] > 0: dr += t["buffs"]["dr"]
	if t["barrierT"] > 0: dr += t["barrier"]
	if t["hp"] / t["maxHP"] < 0.35: dr += t["clutchDR"]
	var tc: Dictionary = GameData.CLASSES[t["classId"]]
	if t["hatChainT"] > 0 and tc.has("chainDR"): dr += tc["chainDR"]
	if t["_pocketDR"] > 0: dr += t["_pocketDR"]
	return min(0.75, dr)

# dealDamage — the ordered multiplier + mitigation pipeline. Returns dmg applied.
static func deal_damage(state: Dictionary, src: Dictionary, tgt: Dictionary, raw: float, opts: Dictionary = {}) -> float:
	if not tgt["alive"] or tgt["evade"] > 0 or tgt["untarget"] > 0:
		return 0.0
	var sc: Dictionary = GameData.CLASSES[src["classId"]]
	var dmg: float = raw * src["dmgMult"]

	# 2. momentum (Linebacker, melee)
	if sc.has("momentumGain") and opts.get("melee", false):
		dmg *= 1.0 + src["momentum"] * sc["momentumGain"]
	# 3. clutch (source < 35% HP)
	if src["hp"] / src["maxHP"] < 0.35:
		dmg *= 1.0 + src["clutchDmg"]
	# 4. airborne (Spiker)
	if opts.get("airborne", false) and sc.has("airborneDmg"):
		dmg *= sc["airborneDmg"]
	# 5. sudden-death overtime
	if state["t"] > OT_START:
		dmg *= 1.0 + (state["t"] - OT_START) * 0.035
	# 6. strike zone (own + ally projectile boost)
	if opts.get("projectile", false):
		for z in state["zones"]:
			if z["team"] == src["team"] and Vector2(z["x"] - tgt["x"], z["y"] - tgt["y"]).length() < z["radius"] + 30:
				var p = _find(state["fighters"], z["owner"])
				if p:
					dmg *= GameData.CLASSES[p["classId"]]["zoneSelfBoost"] if p["id"] == src["id"] else GameData.CLASSES[p["classId"]]["zoneAllyBoost"]
				break
	# 7. hat trick (Striker)
	if sc.has("hatTrickEvery"):
		if src["hatTarget"] == tgt["id"]:
			src["hatCount"] += 1
		else:
			src["hatTarget"] = tgt["id"]
			src["hatCount"] = 1
		src["hatChainT"] = 3.0
		if src["hatCount"] % int(sc["hatTrickEvery"]) == 0:
			dmg *= sc["hatTrickBonus"]
		if tgt["hp"] / tgt["maxHP"] < sc["lowHPThresh"] and opts.get("key", "") == "clinical":
			dmg *= sc["lowHPDmg"]
	# 8. set buff (next damage ability, non-basic)
	if src["buffs"]["nextdmg"] > 0 and not opts.get("basic", false):
		dmg *= src["buffs"]["nextdmg"]
		src["buffs"]["nextdmg"] = 0.0
	# 9. crit
	var crit_ch: float = src["crit"] + (src["buffs"]["crit"] if src["buffs"]["critT"] > 0 else 0.0)
	var is_crit: bool = state["rng"].next() < crit_ch
	if is_crit:
		dmg *= src["critMult"]
	# 10. shield crusher (Batter, vs shielded/DR targets)
	if sc.has("shieldCrusher") and (tgt["shield"] > 0 or effective_dr(tgt) > 0.05):
		dmg *= sc["shieldCrusher"]

	# ---- mitigation ----
	var tc: Dictionary = GameData.CLASSES[tgt["classId"]]
	# 11. reflect stance (Goalkeeper)
	if tgt["buffs"]["reflect"] > 0:
		tgt["buffs"]["reflect"] = 0.0
		tgt["mitigated"] += dmg
		var back: float = dmg * tc["reflectMult"]
		deal_damage(state, tgt, src, back / tgt["dmgMult"], {"reflected": true})
		return 0.0
	# 12. DR
	var dr := effective_dr(tgt)
	var mitigated: float = dmg * dr
	dmg -= mitigated
	if tgt["barrierT"] > 0:
		tgt["barrierStored"] += mitigated
	# 13. shields (with Spiker bypass)
	var bypass: float = sc["shieldBypass"] if (src["buffs"]["bypass"] > 0 and sc.has("shieldBypass")) else 0.0
	if tgt["shield"] > 0:
		var to_shield: float = dmg * (1.0 - bypass)
		var absorbed: float = min(tgt["shield"], to_shield)
		tgt["shield"] -= absorbed
		dmg -= absorbed
		mitigated += absorbed
	dmg = max(0.0, dmg)
	# 14. apply
	tgt["hp"] -= dmg
	tgt["noDmgT"] = 0.0
	tgt["flash"] = 0.1
	tgt["mitigated"] += mitigated
	src["dmgDealt"] += dmg
	tgt["dmgTaken"] += dmg
	if dmg > 0: state["events"].append({"type": "dmg", "src": src["id"], "tgt": tgt["id"], "amt": int(round(dmg)), "crit": is_crit, "t": state["t"]})
	# 15. lifesteal (Batter melee)
	if opts.get("melee", false) and sc.has("meleeLifesteal"):
		var heal: float = dmg * sc["meleeLifesteal"]
		src["hp"] = min(src["maxHP"], src["hp"] + heal)
		src["healing"] += heal
	# 16. death
	if tgt["hp"] <= 0:
		tgt["hp"] = 0.0
		tgt["alive"] = false
		tgt["deathT"] = state["t"]
		src["kills"] += 1
		state["events"].append({"type": "kill", "killer": src["id"], "victim": tgt["id"], "t": state["t"]})
		# (on-kill ability effects — golden goal stealth, thunderspike reset — added with abilities phase)
	return dmg

static func apply_heal(state: Dictionary, src: Dictionary, tgt: Dictionary, amt: float) -> void:
	if not tgt["alive"]:
		return
	var sc: Dictionary = GameData.CLASSES[src["classId"]]
	var boosted: float = amt * (sc["supportBoost"] if sc.has("supportBoost") else 1.0)
	var real: float = min(tgt["maxHP"] - tgt["hp"], boosted)
	tgt["hp"] += real
	src["healing"] += real

static func apply_shield(state: Dictionary, src: Dictionary, tgt: Dictionary, amt: float, dur: float) -> void:
	var sc: Dictionary = GameData.CLASSES[src["classId"]]
	var boosted: float = amt * (sc["supportBoost"] if sc.has("supportBoost") else 1.0)
	tgt["shield"] += boosted
	tgt["shieldT"] = max(tgt["shieldT"], dur)
	src["healing"] += boosted * 0.5
