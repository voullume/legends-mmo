extends SceneTree
## Secret-boss (Head Coach PRIME) length probe — 5 level-10 AI players vs the boss scaled EXACTLY like the
## server (tier boss ×6, ×hpMult 8, level) + its 6 power cores (which give it 60% DR while any is alive), in
## the persistent-zone model with the secret-arena cover. Reports kill time or cap-survival. This is a FLOOR
## with a big caveat: the AI does not optimally focus the cores to drop the shield, so it runs LONGER than a
## coordinated team — treat a long floor as "very hard", and the real >10-min target as a design goal to be
## confirmed by playtest. Per-fight wall cap = 18 min so the sim terminates.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const World = preload("res://shared/World.gd")
const Rng = preload("res://shared/Rng.gd")

const MOB_HP_SCALE := 0.35
const MOB_DMG_SCALE := 0.28
const MOB_BOSS_HP := 6.0
const MOB_BOSS_DMG := 1.8
const MOB_ELITE_HP := 2.2
const LEVEL_HP := 60.0

func _scale(f: Dictionary, lvl: int, tier: String, hpmult: float) -> void:
	var hp_t: float = MOB_BOSS_HP if tier == "boss" else (MOB_ELITE_HP if tier == "elite" else 1.0)
	var dmg_t: float = MOB_BOSS_DMG if tier == "boss" else 1.0
	f["maxHP"] = f["maxHP"] * MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * hp_t * hpmult
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * dmg_t * float(GameData.CLASSES.get(str(f["classId"]), {}).get("dmgScale", 1.0))

func _run(n_players: int, seed_value: int) -> Dictionary:
	var rng = Rng.new(seed_value)
	var fighters := []
	var players := []
	for i in n_players:
		var p = GameData.create_fighter("striker", 0, i, rng, 5)
		p["maxHP"] += (10 - 1) * LEVEL_HP; p["hp"] = p["maxHP"]
		fighters.append(p); players.append(p)
	var boss = GameData.create_fighter("head_coach_prime", 1, 0, rng, 5)
	boss["mobLevel"] = 10; boss["mobTier"] = "boss"
	_scale(boss, 10, "boss", float(GameData.CLASSES["head_coach_prime"].get("hpMult", 1.0)))
	fighters.append(boss)
	var bosshp := float(boss["maxHP"])
	for i in 6:
		var core = GameData.create_fighter("power_core", 1, 10 + i, rng, 5)
		core["mobLevel"] = 7; core["mobTier"] = "minion"; core["isCore"] = true
		_scale(core, 7, "minion", 1.0)
		core["x"] = 500.0 + i * 70.0; core["y"] = 470.0
		fighters.append(core)
	var st := {
		"t": 0.0, "seed": seed_value, "rng": rng, "fighters": fighters, "zone": true,
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": [], "compB": [], "teamSize": 5, "mapId": "sec",
		"map": {"id": "sec", "obstacles": World.obstacle_circles("glitchyard_secret")},
	}
	var guard := 0
	var cap := 30 * 60 * 18   # 18 min wall
	var maxphase := 0
	while guard < cap:
		Sim.sim_tick(st, 1.0 / 30.0)
		st["events"].clear()
		maxphase = maxi(maxphase, int(boss.get("phase", 0)))
		if not boss["alive"]:
			return {"res": "killed", "dur": st["t"], "phase": maxphase, "hp_pct": 0.0}
		var any := false
		for p in players:
			if p["alive"]: any = true; break
		if not any:
			return {"res": "wipe", "dur": st["t"], "phase": maxphase, "hp_pct": 100.0 * boss["hp"] / bosshp}
		guard += 1
	return {"res": "cap", "dur": st["t"], "phase": maxphase, "hp_pct": 100.0 * boss["hp"] / bosshp}

func _init() -> void:
	print("=== Head Coach PRIME (secret) — 5 lvl-10 AI vs boss + 6 cores (60% DR while cores up), floor ===")
	for s in [1, 2]:
		var r = _run(5, s)
		print("  seed %d: %s after %ds  | maxphase %d | boss HP left %.0f%%" % [s, r["res"], int(r["dur"]), r["phase"], r["hp_pct"]])
	quit()
