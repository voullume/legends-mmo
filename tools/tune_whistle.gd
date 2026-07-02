extends SceneTree
## WHISTLE-STUN harshness probe. The Whistle Burst (head_coach: meleeAoe radius 125 / cd 9 / stun 0.8,
## phase 0 → active the whole fight; head_coach_prime: primewhistle radius 155 / cd 7 / stun 1.0, phase 3)
## is the ONLY player-stun source in the boss arenas (every other boss ability is dmg / knockback / pull /
## slow / self-wallStun). So total player-stun-time = whistle impact. There is no HUD telegraph for it, so a
## face-tanking AI is a fair model of the real player experience. We report STUN UPTIME = fraction of alive-
## player-time spent stunned, per comp: melee (batter/linebacker sit inside the radius) vs ranged (striker
## kites outside it) vs a realistic 2-melee/3-ranged mix. High uptime on melee = too harsh → cut stun/raise cd.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const World = preload("res://shared/World.gd")
const Rng = preload("res://shared/Rng.gd")

const MOB_HP_SCALE := 0.35
const MOB_DMG_SCALE := 0.28
const MOB_BOSS_HP := 22.0
const MOB_BOSS_DMG := 2.1
const LEVEL_HP := 60.0

func _scale_boss(f: Dictionary, lvl: int) -> void:
	var bdef: Dictionary = GameData.CLASSES.get(str(f["classId"]), {})
	var hp_s: float = MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * MOB_BOSS_HP
	var dmg_s: float = MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * MOB_BOSS_DMG
	f["maxHP"] = f["maxHP"] * hp_s * float(bdef.get("hpMult", 1.0))
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s * float(bdef.get("dmgScale", 1.0))

# force_phase: drive the boss straight to a phase so a phase-gated whistle (prime's is phase 3) actually fires
# in this FLOOR (where the DR/HP wall means the fight never naturally reaches it). Pure measurement aid.
func _encounter(boss_id: String, comp: Array, player_lvl: int, boss_lvl: int, seed_value: int, map_dict: Dictionary, force_phase: int) -> Dictionary:
	var rng = Rng.new(seed_value)
	var fighters := []
	var players := []
	for i in comp.size():
		var p = GameData.create_fighter(str(comp[i]), 0, i, rng, 5)
		p["maxHP"] += (player_lvl - 1) * LEVEL_HP
		p["hp"] = p["maxHP"]
		fighters.append(p)
		players.append(p)
	var boss = GameData.create_fighter(boss_id, 1, 0, rng, 5)
	boss["mobLevel"] = boss_lvl
	boss["mobTier"] = "boss"
	_scale_boss(boss, boss_lvl)
	fighters.append(boss)
	var state := {
		"t": 0.0, "seed": seed_value, "rng": rng, "fighters": fighters, "zone": true,
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": [], "compB": [], "teamSize": 5, "mapId": str(map_dict["id"]), "map": map_dict,
	}
	var guard := 0
	var cap := 30 * 200
	var stun_ticks := 0            # alive-player-ticks spent with stun>0
	var alive_ticks := 0          # alive-player-ticks total
	var stun_apps := 0            # fresh whistle applications (stun rising from ~0 into the stun band)
	var prev_stun := {}
	var whistle_stun := 0.8
	for ab in GameData.CLASSES[boss_id]["abilities"]:
		if str(ab.get("name", "")).begins_with("Whistle"):
			whistle_stun = float(ab.get("stun", 0.8))
	while guard < cap:
		# pin the phase floor so a phase-gated whistle fires (monotonic max is preserved by the sim)
		if force_phase > 0 and int(boss.get("phase", 0)) < force_phase:
			boss["phase"] = force_phase
		Sim.sim_tick(state, 1.0 / 30.0)
		state["events"].clear()
		for p in players:
			if p["alive"]:
				alive_ticks += 1
				var st: float = float(p.get("stun", 0.0))
				if st > 0.0:
					stun_ticks += 1
				# a fresh application = stun jumps up near the whistle's value from a low prior
				if st > float(prev_stun.get(p["id"], 0.0)) + 0.3 and st >= whistle_stun - 0.05:
					stun_apps += 1
				prev_stun[p["id"]] = st
		if not boss["alive"]:
			break
		var any := false
		for p in players:
			if p["alive"]: any = true; break
		if not any:
			break
		guard += 1
	var uptime := 100.0 * float(stun_ticks) / maxf(1.0, float(alive_ticks))
	var mins := maxf(state["t"] / 60.0, 0.001)
	return {"uptime": uptime, "apps": stun_apps, "apps_per_min": float(stun_apps) / mins / maxf(1.0, float(comp.size())), "dur": snappedf(state["t"], 0.1)}

func _run(boss_id: String, boss_lvl: int, force_phase: int, whistle_desc: String) -> void:
	var map_dict := {"id": "bossarena", "obstacles": World.obstacle_circles("glitchyard_boss" if boss_id == "head_coach" else "glitchyard_secret")}
	var comps := {
		"melee (5x linebacker)": ["linebacker", "linebacker", "linebacker", "linebacker", "linebacker"],
		"melee (5x batter)":     ["batter", "batter", "batter", "batter", "batter"],
		"ranged (5x striker)":   ["striker", "striker", "striker", "striker", "striker"],
		"mix (2 batter/3 striker)": ["batter", "batter", "striker", "striker", "striker"],
	}
	print("=== %s — %s ===" % [boss_id, whistle_desc])
	for label in comps:
		var up := 0.0; var apm := 0.0; var dur := 0.0; var n := 0
		for s in [1, 2, 3, 4, 5, 6]:
			var r = _encounter(boss_id, comps[label], 8, boss_lvl, s, map_dict, force_phase)
			up += r["uptime"]; apm += r["apps_per_min"]; dur += r["dur"]; n += 1
		print("   %-26s stun uptime %4.1f%%   whistle stuns/player/min %.2f   (avg fight %ds)" % [label, up / n, apm / n, int(dur / n)])

func _init() -> void:
	print("Whistle-stun harshness: %% of alive-player-time spent stunned by the boss's Whistle Burst (its only stun).")
	print("Guide: <8%% mild · 8-15%% noticeable · >15%% harsh (esp. stacked with the boss's knockback/pull/slow kit).\n")
	_run("head_coach", 8, 0, "Whistle Burst: radius 125, cd 9.0, stun 0.8, PHASE 0 (whole fight)")
	print("")
	_run("head_coach_prime", 10, 3, "Total-reset kit incl. primewhistle: radius 155, cd 7.0, stun 1.0, PHASE 3 (phase forced for measurement)")
	quit()
