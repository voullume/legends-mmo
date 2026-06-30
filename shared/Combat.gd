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

# --- hostility (PvP) ---------------------------------------------------------------------------
# PvE: cross-team = enemy, same-team = ally. In a PvP zone (state.pvp), players (team 0) are hostile
# to each other UNLESS they share a party (party-based PvP: party-mates can't hit each other and CAN
# support each other; everyone else is an enemy). Mobs (team 1) are unaffected, and safe zones (no
# pvp flag) are unchanged. The balance harness (create_match, no "pvp" key) keeps pure team-vs-team,
# so PvE balance/determinism are byte-identical. The party key is stamped on each player fighter by
# the server (Server._party_key); absent/"" means solo (hostile to everyone).
static func is_hostile(state, a, b) -> bool:
	if a["id"] == b["id"]:
		return false                                 # never hostile to yourself
	if a["team"] != b["team"]:
		return true                                  # players↔mobs (and any cross-team) always fight
	if a["team"] == 0 and bool(state.get("pvp", false)):
		return not _same_party(a, b)                 # two players in a PvP zone: hostile unless same party
	return false

static func is_ally(state, a, b) -> bool:
	if a["id"] == b["id"]:
		return true                                  # you are your own ally (self-heal / self-buff)
	if a["team"] != b["team"]:
		return false
	if a["team"] == 0 and bool(state.get("pvp", false)):
		return _same_party(a, b)                      # in a PvP zone, allies only within the same party
	return true

static func _same_party(a, b) -> bool:
	var pa := str(a.get("party", ""))
	return pa != "" and pa == str(b.get("party", ""))

# P5: a heavy mob (the boss + big elites) can be flagged knockback-immune — forced displacement (melee /
# dash knockback) is skipped on it, so players can't kb-lock it. Players never carry the flag (no-op for them).
static func kb_immune(f: Dictionary) -> bool:
	return GameData.CLASSES.get(str(f["classId"]), {}).get("kbImmune", false)

# P5 frontal DR — a mob with a `frontalDR` def value takes that fraction LESS from an attacker standing in
# its facing arc (it blocks the front; flank/back it for full damage). Geometric (uses the mob's hx/hy
# heading), zero rng; returns 1.0 for anything without frontalDR (so players are unaffected → byte-identical).
static func frontal_mult(src: Dictionary, tgt: Dictionary) -> float:
	var fdr := float(GameData.CLASSES.get(str(tgt["classId"]), {}).get("frontalDR", 0.0))
	if fdr <= 0.0:
		return 1.0
	var hx := float(tgt.get("hx", 0.0))
	var hy := float(tgt.get("hy", 0.0))
	if hx == 0.0 and hy == 0.0:
		return 1.0
	var dx := float(src["x"]) - float(tgt["x"])
	var dy := float(src["y"]) - float(tgt["y"])
	var d := Vector2(dx, dy).length()
	if d < 0.001:
		return 1.0
	return (1.0 - fdr) if ((hx * dx + hy * dy) / d) > 0.5 else 1.0   # attacker within ~60° of the front → reduced

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
	# 4b. frontal DR (P5) — a mob that blocks from the front takes less; flank/back it for full (no-op for players)
	dmg *= frontal_mult(src, tgt)
	# 5. sudden-death overtime (skipped in a persistent zone — t grows unbounded there)
	if state["t"] > OT_START and not state.get("zone", false):
		dmg *= 1.0 + (state["t"] - OT_START) * 0.035
	# 6. strike zone (own + ally projectile boost) — only BUFF zones whose owner class carries the boost
	# fields (the Pitcher); a mob HAZARD zone owner (e.g. the Drill Sergeant) has neither, so .get() → 1.0
	# (no boost). Guarded access — a missing key here used to crash the sim when a mob shot near a mob zone.
	if opts.get("projectile", false):
		for z in state["zones"]:
			if Vector2(z["x"] - tgt["x"], z["y"] - tgt["y"]).length() >= z["radius"] + 30:
				continue
			var p = _find(state["fighters"], z["owner"])
			if p != null and (p["id"] == src["id"] or is_ally(state, p, src)):   # own/ally zone boosts the shot
				var pc: Dictionary = GameData.CLASSES[p["classId"]]
				dmg *= float(pc.get("zoneSelfBoost", 1.0)) if p["id"] == src["id"] else float(pc.get("zoneAllyBoost", 1.0))
				break
	# 7. hat trick (Striker) — NOT for proc/DOT damage (it would advance the chain + refresh hatChainT remotely)
	if sc.has("hatTrickEvery") and not opts.get("proc", false) and not opts.get("dot", false):
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
	# 8. set buff (next damage ability, non-basic) — a proc/DOT tick must not CONSUME the buff
	if src["buffs"]["nextdmg"] > 0 and not opts.get("basic", false) and not opts.get("proc", false) and not opts.get("dot", false):
		dmg *= src["buffs"]["nextdmg"]
		src["buffs"]["nextdmg"] = 0.0
	# 9. crit — proc/DOT damage (opts.proc) AND hazard-zone damage (opts.dot) skip the roll so they DRAW NO
	# rng (the sim stays byte-identical whether or not procs/hazards are present — determinism preserved).
	# (opts.dot = a zero-rng DOT-style tick like proc, but NOT bounded by PROC_DPS_CAP — see step 13.)
	var crit_ch: float = src["crit"] + (src["buffs"]["crit"] if src["buffs"]["critT"] > 0 else 0.0)
	var is_crit: bool = false
	if not opts.get("proc", false) and not opts.get("dot", false):
		is_crit = state["rng"].next() < crit_ch
	if is_crit:
		dmg *= src["critMult"]
	# 10. shield crusher (Batter, vs shielded/DR targets)
	if sc.has("shieldCrusher") and (tgt["shield"] > 0 or effective_dr(tgt) > 0.05):
		dmg *= sc["shieldCrusher"]

	# ---- mitigation ----
	var tc: Dictionary = GameData.CLASSES[tgt["classId"]]
	# 11. reflect stance (Goalkeeper) — proc/DOT damage is NOT reflected: reflecting it would draw a crit rng
	# (breaking the procs-draw-no-rng rule), bounce 1.6× UNCAPPED past PROC_DPS_CAP, and re-resolve procs.
	if tgt["buffs"]["reflect"] > 0 and not opts.get("proc", false) and not opts.get("dot", false):
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
	# proc/DOT damage is bounded per source per second (PROC_DPS_CAP) so procs can't break class balance
	if opts.get("proc", false):
		var pbudget: float = GameData.PROC_DPS_CAP - float(src.get("_procDmg", 0.0))
		dmg = clampf(dmg, 0.0, max(0.0, pbudget))
		src["_procDmg"] = float(src.get("_procDmg", 0.0)) + dmg
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
	# procs (P6): a REAL hit (not proc/DOT-sourced) resolves the source's equipped procs — deterministically.
	if not opts.get("proc", false) and not opts.get("dot", false):
		_resolve_procs(state, src, tgt, is_crit, not tgt["alive"], dmg)
	return dmg

# resolve the source's equipped procs after a hit. Pure-data effects (DOT/FLAT/LIFESTEAL) with per-proc
# internal cooldowns; draws NO rng. Damage procs route back through deal_damage (opts.proc=true) so they
# inherit dmgMult × FORMAT_MODS and the per-source PROC_DPS_CAP, and never recursively re-proc.
static func _resolve_procs(state: Dictionary, src: Dictionary, tgt: Dictionary, is_crit: bool, killed: bool, dmg: float) -> void:
	var procs = src.get("procs", [])
	if not (procs is Array) or procs.is_empty():
		return
	var pt: Dictionary = src.get("_procT", {})
	for p in procs:
		var fire := false
		match str(p.get("trigger", "on_hit")):
			"on_hit": fire = true
			"on_crit": fire = is_crit
			"on_kill": fire = killed
			"on_lowhp": fire = src["hp"] / src["maxHP"] < 0.35
		if not fire:
			continue
		var pid := str(p.get("id", ""))
		var icd := float(p.get("icd", 0.0))
		if icd > 0.0:
			if float(pt.get(pid, 0.0)) > 0.0:
				continue                                  # still on internal cooldown
			pt[pid] = icd
		match str(p.get("effect", "")):
			"DOT":
				if tgt.has("dots"):
					tgt["dots"].append({"src": src["id"], "dps": float(p.get("amt", 0.0)), "remaining": float(p.get("dur", 3.0)), "proc": pid})
			"FLAT":
				deal_damage(state, src, tgt, float(p.get("amt", 0.0)), {"proc": true})
			"LIFESTEAL":
				var heal: float = dmg * float(p.get("amt", 0.0))
				src["hp"] = min(src["maxHP"], src["hp"] + heal)
				src["healing"] += heal
	src["_procT"] = pt

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
