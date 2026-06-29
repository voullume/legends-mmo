extends SceneTree
## Scaled elite-tuning harness: builds a realistic camp encounter — N AI players (level-scaled, format-5
## like the live zone) vs 1 elite mob scaled EXACTLY like the server (_scale_mob) — and reports the elite's
## win rate + duration. NOTE: summoned adds are server-only (no server here), so the Drill Sergeant is
## measured WITHOUT its 3 cone adds → treat its number as a FLOOR (it's stronger live). Ungeared AI players
## also understate real (geared) player power. Target: an elite should lose to a small group, be a real
## threat 1v1 — not wipe a party.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const Rng = preload("res://shared/Rng.gd")

# mirror server/Server.gd _scale_mob + constants
const MOB_HP_SCALE := 0.35
const MOB_DMG_SCALE := 0.28
const MOB_ELITE_HP := 2.2
const MOB_ELITE_DMG := 1.6
const LEVEL_HP := 60.0

func _scale_mob(f: Dictionary, lvl: int, tier: String) -> void:
	var hp_t: float = MOB_ELITE_HP if tier == "elite" else 1.0
	var dmg_t: float = MOB_ELITE_DMG if tier == "elite" else 1.0
	var hp_s: float = MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * hp_t
	var dmg_s: float = MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * dmg_t
	f["maxHP"] = f["maxHP"] * hp_s
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s

func _encounter(elite: String, elite_lvl: int, n_players: int, player_lvl: int, seed_value: int, map_id: String) -> int:
	var rng = Rng.new(seed_value)
	var fighters := []
	for i in n_players:
		var p = GameData.create_fighter("striker", 0, i, rng, 5)   # format 5 = live zone
		p["maxHP"] += (player_lvl - 1) * LEVEL_HP
		p["hp"] = p["maxHP"]
		fighters.append(p)
	var m = GameData.create_fighter(elite, 1, 0, rng, 5)
	m["mobLevel"] = elite_lvl
	m["mobTier"] = "elite"
	_scale_mob(m, elite_lvl, "elite")
	fighters.append(m)
	var state := {
		"t": 0.0, "seed": seed_value, "rng": rng, "fighters": fighters,
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": [], "compB": [], "teamSize": 5, "mapId": map_id, "map": GameData.MAPS[map_id],
	}
	var guard := 0
	var cap := int(30 * (GameData.TIME_LIMIT + 5))
	while state["winner"] == null and guard < cap:
		Sim.sim_tick(state, 1.0 / 30.0)
		state["events"].clear()
		guard += 1
	return int(state["winner"]) if state["winner"] != null else -1   # 0 players, 1 elite

func _measure(elite: String, elite_lvl: int) -> void:
	print("--- %s (lvl %d elite, scaled) ---" % [elite, elite_lvl])
	for n in [1, 2, 3]:
		var elite_wins := 0
		var games := 0
		for s in [1, 2, 3, 4, 5, 6]:
			for mp in ["stadium", "trenches"]:
				var w = _encounter(elite, elite_lvl, n, 6, s, mp)
				games += 1
				if w == 1:
					elite_wins += 1
		print("   vs %d player(s): elite wins %d/%d (%.0f%%)" % [n, elite_wins, games, 100.0 * elite_wins / games])

func _init() -> void:
	print("=== scaled elite encounters (1 elite vs N format-5 lvl-6 players) — Drill excludes its adds (FLOOR) ===")
	_measure("sled_juggernaut", 5)
	_measure("ball_machine", 6)
	_measure("drill_sergeant", 7)
	quit()
