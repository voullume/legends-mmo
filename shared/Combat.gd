extends RefCounted
## Legends of the Arena — damage pipeline.
## Direct port of the web sim's effectiveDR / dealDamage / applyHeal / applyShield.
## `state` is a Dictionary: { "rng": Rng, "t": float, "zones": Array, "fighters": Array, "events": Array }
## Fighters/state are passed by reference (Dictionaries are reference types in GDScript),
## so mutations persist — same as the JS objects.

const GameData := preload("res://shared/GameData.gd")
const Rng := preload("res://shared/Rng.gd")
const Geom := preload("res://shared/Geom.gd")

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

# --- 8-skill expansion: generic buff-dict application ---------------------------------------------------
# THE one writer for a buff dictionary (self + ally paths, movement follow-ups, on-kill rewards). Every
# supported field applies — a shield on the same ability must not swallow these. Values overwrite (the
# existing semantic); every timed field re-arms its timer, so an expired buff can never linger as a stale
# value (the T-gated reads in effective_dr / step_toward / try_cast stay the single source of truth).
static func apply_buff_dict(t: Dictionary, b: Dictionary) -> void:
	if b.has("nextdmg"):
		t["buffs"]["nextdmg"] = b["nextdmg"]
	if b.has("dr"):
		# DR is monotone protection: a weaker concurrent source (an ally's Play Action landing under
		# your Block) must not REDUCE an active DR — keep the stronger value; either way extend to the
		# longer window. Ability writes stamp drSrc so dispel can spare item-proc (P7b GUARD) DR.
		if not (t["buffs"]["drT"] > 0.0 and float(t["buffs"]["dr"]) > float(b["dr"])):
			t["buffs"]["dr"] = b["dr"]
			t["buffs"]["drSrc"] = "ability"
		t["buffs"]["drT"] = maxf(float(t["buffs"]["drT"]), float(b["dur"]))
	if b.has("ms"):
		# move speed stays last-write-wins: it's directional (haste vs an anchor stance's self-slow),
		# so the newest ability intent governs. Stamped for the same dispel provenance.
		t["buffs"]["ms"] = b["ms"]
		t["buffs"]["msT"] = b["dur"]
		t["buffs"]["msSrc"] = "ability"
	if b.has("crit"):
		t["buffs"]["crit"] = b["crit"]
		t["buffs"]["critT"] = b["dur"]
	if b.has("atkspd"):
		t["buffs"]["atkspd"] = b["atkspd"]
		t["buffs"]["atkspdT"] = b.get("dur", 2.2)
	if b.has("bypass"):
		t["buffs"]["bypass"] = b["dur"]
	if b.has("reflect"):
		t["buffs"]["reflect"] = b["dur"]
	if b.has("guard"):                                # guarded melee knockback (Roof Block) — rides the buff's dur
		t["guardCharges"] = int(b["guard"].get("charges", 1))
		t["guardKb"] = float(b["guard"].get("kb", 45.0))
		t["guardT"] = float(b.get("dur", 2.0))

# --- 8-skill expansion: dispel (Strip Ball) --------------------------------------------------------------
# Eligibility is DELIBERATELY narrow: only the timed buff-dict fields, in fixed priority
# reflect > DR > bypass > attack speed > crit > movement speed. Never shields, barriers, equipped procs /
# DOTs / their granted buffs (dr/ms stamped drSrc/msSrc "proc" are ITEM effects — spared), class passives,
# Momentum, Hat Trick, evasion, untargetability, boss phases, cores, or guard charges. A movement-speed
# value <= 1.0 (a self-slow like Goal-Line Stand) is not a buff — stripping it would help the target, so
# it's ineligible. Zero rng; pure field writes.
static func _dr_dispellable(b: Dictionary) -> bool:
	return b["drT"] > 0.0 and str(b.get("drSrc", "")) != "proc"

static func _ms_dispellable(b: Dictionary) -> bool:
	return b["msT"] > 0.0 and b["ms"] > 1.0 and str(b.get("msSrc", "")) != "proc"

# the AI-prioritization gate ("worth a Strip Ball?"). Deliberately EXCLUDES reflect: an active reflect
# eats the strip's own melee hit (and bounces it back 1.6×) before the dispel can resolve — swinging a
# dispel into a Punching Save is feeding, not stripping. dispel_one still lists reflect first (the spec's
# priority), reachable by any future non-damage dispel carrier.
static func has_dispellable(t: Dictionary) -> bool:
	var b: Dictionary = t["buffs"]
	return _dr_dispellable(b) or b["bypass"] > 0.0 \
		or b["atkspdT"] > 0.0 or b["critT"] > 0.0 or _ms_dispellable(b)

static func dispel_one(t: Dictionary) -> bool:
	var b: Dictionary = t["buffs"]
	if b["reflect"] > 0.0:
		b["reflect"] = 0.0
		return true
	if _dr_dispellable(b):
		b["drT"] = 0.0
		b["dr"] = 0.0
		return true
	if b["bypass"] > 0.0:
		b["bypass"] = 0.0
		return true
	if b["atkspdT"] > 0.0:
		b["atkspdT"] = 0.0
		b["atkspd"] = 1.0
		return true
	if b["critT"] > 0.0:
		b["critT"] = 0.0
		b["crit"] = 0.0
		return true
	if _ms_dispellable(b):
		b["msT"] = 0.0
		b["ms"] = 1.0
		return true
	return false

# the ability def behind a damage packet's opts.key (for the generic on-hit / on-kill / dispel fields).
# {} when keyless (zones) or the key isn't one of the source class's abilities (no-op for every mob).
static func _ability_def(c: Dictionary, key: String) -> Dictionary:
	if key == "":
		return {}
	for ab in c.get("abilities", []):
		if str(ab.get("key", "")) == key:
			return ab
	return {}

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

# P-secret CORE SHIELD — a boss with a `coreShield` def value takes that fraction LESS damage while ANY of
# its own (team-ally) power cores is still alive: the raid must keep the respawning cores down to damage it.
# Geometric/boolean, zero rng; 1.0 (no-op) for anything without coreShield (so players + other mobs unaffected).
static func core_shield_mult(state: Dictionary, tgt: Dictionary) -> float:
	var cs := float(GameData.CLASSES.get(str(tgt["classId"]), {}).get("coreShield", 0.0))
	if cs <= 0.0:
		return 1.0
	for e in state["fighters"]:
		if e["alive"] and e.get("isCore", false) and is_ally(state, tgt, e):
			return 1.0 - cs                  # a core is up → the boss is shielded
	return 1.0

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
	# 4c. core shield (secret boss) — heavy DR while its power cores are up; kill them to damage it (no-op otherwise)
	dmg *= core_shield_mult(state, tgt)
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
	# 14. apply. opts.tick = one sub-frame slice of a DOT/hazard (30/s): it must not strobe the hit
	# flash or emit a per-tick dmg event — the slices coalesce on the target (_dotAcc) and the sim
	# flushes them as ONE "burn" event/sec, so clients render passive accumulation, not 30 impacts/s.
	tgt["hp"] -= dmg
	tgt["noDmgT"] = 0.0
	tgt["mitigated"] += mitigated
	src["dmgDealt"] += dmg
	tgt["dmgTaken"] += dmg
	if opts.get("tick", false):
		if dmg > 0:
			var acc: Dictionary = tgt.get("_dotAcc", {})
			acc[src["id"]] = float(acc.get(src["id"], 0.0)) + dmg
			tgt["_dotAcc"] = acc
	else:
		tgt["flash"] = 0.1
		if dmg > 0:
			var ev := {"type": "dmg", "src": src["id"], "tgt": tgt["id"], "amt": int(round(dmg)), "crit": is_crit, "t": state["t"]}
			if opts.get("proc", false):
				ev["proc"] = true          # passive item-proc damage — clients show a soft tick, not an impact
			state["events"].append(ev)
	# 14b. guarded melee knockback (Roof Block) — a direct melee hit on a guarded target punches the ATTACKER
	# back and consumes one charge. Projectile / proc / DOT / hazard / reflected damage never triggers it; a
	# kb-immune attacker is neither displaced nor consumes the charge. Zero rng; pure geometry.
	if opts.get("melee", false) and not opts.get("proc", false) and not opts.get("dot", false) \
			and not opts.get("reflected", false) \
			and int(tgt.get("guardCharges", 0)) > 0 and float(tgt.get("guardT", 0.0)) > 0.0 \
			and not kb_immune(src):
		tgt["guardCharges"] = int(tgt["guardCharges"]) - 1
		var gkb: float = float(tgt.get("guardKb", 45.0))
		var gd := Vector2(src["x"] - tgt["x"], src["y"] - tgt["y"]).length()
		if gd < 0.001:
			src["x"] += gkb                            # exactly overlapping: deterministic +x push
		else:
			src["x"] += ((src["x"] - tgt["x"]) / gd) * gkb
			src["y"] += ((src["y"] - tgt["y"]) / gd) * gkb
		Geom.clamp_arena(src)
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
		# flush any pending coalesced burn slices NOW — an instant respawn (the training dummy) would
		# wipe _dotAcc before the sim's next-tick corpse flush could emit the final burn number.
		var dacc: Dictionary = tgt.get("_dotAcc", {})
		if not dacc.is_empty():
			for sid in dacc:
				var bamt := int(round(float(dacc[sid])))
				if bamt > 0:
					state["events"].append({"type": "dmg", "src": sid, "tgt": tgt["id"], "amt": bamt, "crit": false, "proc": true, "t": state["t"]})
			tgt["_dotAcc"] = {}
		state["events"].append({"type": "kill", "killer": src["id"], "victim": tgt["id"], "t": state["t"]})
	# 16b. generic data-driven ability effects (8-skill expansion), resolved from the ability key in opts:
	# on-hit self shield (Walk-Off), one-buff dispel (Strip Ball), on-kill buff (Golden Goal). DIRECT damage
	# only — proc / DOT / hazard / reflected packets never resolve these (so a DOT kill grants no on-kill
	# reward and a reflected hit can't strip its own caster). Keyless packets (zones) resolve {}; a mob
	# ability resolves its real def but carries none of these fields → no-op either way.
	if not opts.get("proc", false) and not opts.get("dot", false) and not opts.get("reflected", false):
		var abd: Dictionary = _ability_def(sc, str(opts.get("key", "")))
		if not abd.is_empty():
			if dmg > 0.0 and abd.has("onHitSelfShieldPct") and src["alive"]:
				apply_shield(state, src, src, src["maxHP"] * float(abd["onHitSelfShieldPct"]), float(abd.get("onHitSelfShieldDur", 3.0)))
			if dmg > 0.0 and int(abd.get("dispelBuffs", 0)) > 0:
				for _i in int(abd["dispelBuffs"]):
					if not dispel_one(tgt):
						break
			if not tgt["alive"] and abd.has("onKillBuff"):
				apply_buff_dict(src, abd["onKillBuff"])
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
		if icd > 0.0 and float(pt.get(pid, 0.0)) > 0.0:
			continue                                      # still on internal cooldown
		var chance := float(p.get("chance", 1.0))
		if chance < 1.0 and _proc_roll(state, src, tgt, pid) >= chance:
			continue                                      # didn't proc (a failed roll doesn't consume the ICD)
		if icd > 0.0:
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
			"SHIELD":                                     # P7b: self-shield (e.g. on_lowhp panic guard). No rng; no supportBoost (class-neutral).
				src["shield"] += float(p.get("amt", 0.0))
				src["shieldT"] = maxf(src["shieldT"], float(p.get("dur", 3.0)))
			"HEAL":                                       # P7b: self-heal (e.g. on_kill sustain), capped at maxHP
				var h: float = min(src["maxHP"] - src["hp"], float(p.get("amt", 0.0)))
				src["hp"] += h
				src["healing"] += h
			"HASTE":                                      # P7b: temp move-speed (amt = bonus fraction, applied as 1+amt). Apply ONLY when the proc wins (no active ms buff, or the proc is >= the active one) so a weaker proc never weakens NOR extends a stronger ability buff (e.g. stolenbase 1.45) — and NEVER overwrite an ability SELF-SLOW (ms < 1.0, e.g. Goal-Line Stand): erasing the malus while its DR persists would break that ability's tradeoff.
				var pms: float = 1.0 + float(p.get("amt", 0.0))
				if src["buffs"]["msT"] <= 0.0 or (pms >= src["buffs"]["ms"] and float(src["buffs"]["ms"]) >= 1.0):
					src["buffs"]["ms"] = pms
					src["buffs"]["msT"] = maxf(src["buffs"]["msT"], float(p.get("dur", 3.0)))
					src["buffs"]["msSrc"] = "proc"        # item-granted → dispel spares it
			"GUARD":                                      # P7b: temp damage reduction (amt = dr fraction). Same win-only rule: never weaken NOR extend a stronger active dr buff.
				var pdr: float = float(p.get("amt", 0.0))
				if src["buffs"]["drT"] <= 0.0 or pdr >= src["buffs"]["dr"]:
					src["buffs"]["dr"] = pdr
					src["buffs"]["drT"] = maxf(src["buffs"]["drT"], float(p.get("dur", 3.0)))
					src["buffs"]["drSrc"] = "proc"        # item-granted → dispel spares it
	src["_procT"] = pt

# One deterministic roll in [0,1) for proc chances, hashed from (sim tick, source id, TARGET id,
# proc id) with the mulberry32 mix. The target key makes same-tick multi-hit abilities (AoE swings,
# multi-projectile ticks) roll independently per hit instead of sharing one all-or-nothing roll.
# Draws NOTHING from state.rng — the main stream stays byte-identical whether or not procs exist
# (the invariant the balance harness relies on), and the same seed+timeline replays the same procs.
static func _proc_roll(state: Dictionary, src: Dictionary, tgt: Dictionary, pid: String) -> float:
	var a: int = Rng._i32(int(round(float(state["t"]) * 30.0)) + Rng._imul(str(src["id"]).hash(), 0x9E3779B9) + Rng._imul(str(tgt["id"]).hash(), 0x27D4EB2F) + Rng._imul(pid.hash(), 0x85EBCA6B))
	a = Rng._i32(a + 0x6D2B79F5)
	var t := Rng._imul(a ^ (Rng._u32(a) >> 15), 1 | a)
	var m := Rng._imul(t ^ (Rng._u32(t) >> 7), 61 | t)
	t = Rng._i32(t + m) ^ t
	return float(Rng._u32(t ^ (Rng._u32(t) >> 14))) / 4294967296.0

static func apply_heal(state: Dictionary, src: Dictionary, tgt: Dictionary, amt: float) -> void:
	if not tgt["alive"]:
		return
	var sc: Dictionary = GameData.CLASSES[src["classId"]]
	var boosted: float = amt * (sc["supportBoost"] if sc.has("supportBoost") else 1.0)
	var real: float = min(tgt["maxHP"] - tgt["hp"], boosted)
	tgt["hp"] += real
	src["healing"] += real
	# presentation event only — never feeds the sim. Per-hit lifesteal + the zone regens deliberately
	# DON'T event (they write hp directly; per-hit text would spam — coalesce like _dotAcc if ever wanted).
	var evamt := int(round(real))
	if evamt > 0:
		state["events"].append({"type": "heal", "src": src["id"], "tgt": tgt["id"], "amt": evamt, "t": state["t"]})

static func apply_shield(state: Dictionary, src: Dictionary, tgt: Dictionary, amt: float, dur: float) -> void:
	var sc: Dictionary = GameData.CLASSES[src["classId"]]
	var boosted: float = amt * (sc["supportBoost"] if sc.has("supportBoost") else 1.0)
	tgt["shield"] += boosted
	tgt["shieldT"] = max(tgt["shieldT"], dur)
	src["healing"] += boosted * 0.5
	var evamt := int(round(boosted))
	if evamt > 0:
		state["events"].append({"type": "shield", "src": src["id"], "tgt": tgt["id"], "amt": evamt, "t": state["t"]})
