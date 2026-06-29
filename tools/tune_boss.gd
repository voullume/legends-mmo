extends SceneTree
## Scaled BOSS-tuning harness — N level-scaled format-5 AI players vs the Head Coach, scaled EXACTLY like
## the server (_scale_mob, tier boss = ×6 HP / ×1.8 dmg), in the persistent-zone model (zone=true: no
## TIME_LIMIT timeout / no overtime ramp, like the live zone). Reports the boss's win rate + whether the
## fight reaches phase 3. CAVEATS (this is a rough FLOOR, both directions): no server here, so the boss has
## NO summoned cone adds (helps players) AND its Full Camp Reset ult is full-power with NO power cores to
## destroy + AI players don't seek cover to break LOS (both hurt players). Ungeared AI also understate real
## player power. Target: the boss must LOSE to 5 and not be trivial vs 2-3; phase must reach 3 in won fights.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const World = preload("res://shared/World.gd")
const Rng = preload("res://shared/Rng.gd")

# mirror server/Server.gd _scale_mob + constants
const MOB_HP_SCALE := 0.35
const MOB_DMG_SCALE := 0.28
const MOB_BOSS_HP := 6.0
const MOB_BOSS_DMG := 1.8
const LEVEL_HP := 60.0

func _scale_boss(f: Dictionary, lvl: int) -> void:
	var hp_s: float = MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * MOB_BOSS_HP
	var dmg_s: float = MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * MOB_BOSS_DMG
	f["maxHP"] = f["maxHP"] * hp_s
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s

func _encounter(n_players: int, player_lvl: int, seed_value: int, map_dict: Dictionary) -> Dictionary:
	var rng = Rng.new(seed_value)
	var fighters := []
	var players := []
	for i in n_players:
		var p = GameData.create_fighter("striker", 0, i, rng, 5)
		p["maxHP"] += (player_lvl - 1) * LEVEL_HP
		p["hp"] = p["maxHP"]
		fighters.append(p)
		players.append(p)
	var boss = GameData.create_fighter("head_coach", 1, 0, rng, 5)
	boss["mobLevel"] = 8
	boss["mobTier"] = "boss"
	_scale_boss(boss, 8)
	fighters.append(boss)
	var state := {
		"t": 0.0, "seed": seed_value, "rng": rng, "fighters": fighters, "zone": true,   # persistent: no timeout/OT
		"projectiles": [], "zones": [], "events": [],
		"focus": [null, null], "lastFocusEval": -1.0, "winner": null, "timeout": false,
		"compA": [], "compB": [], "teamSize": 5, "mapId": str(map_dict["id"]), "map": map_dict,
	}
	var guard := 0
	var cap := 30 * 200   # 200s wall — a boss fight is long; never relies on TIME_LIMIT
	var maxphase := 0
	var result := "cap"   # cap-hit = boss survived
	while guard < cap:
		Sim.sim_tick(state, 1.0 / 30.0)
		state["events"].clear()
		maxphase = maxi(maxphase, int(boss.get("phase", 0)))
		if not boss["alive"]:
			result = "players"; break
		var any_alive := false
		for p in players:
			if p["alive"]: any_alive = true; break
		if not any_alive:
			result = "boss"; break
		guard += 1
	return {"result": result, "maxphase": maxphase, "dur": snappedf(state["t"], 0.1)}

func _measure(player_lvl: int) -> void:
	var maps := [{"id": "stadium", "obstacles": []},
		{"id": "bossarena", "obstacles": World.obstacle_circles("glitchyard_boss")}]
	for n in [1, 2, 3, 5]:
		var boss_wins := 0; var games := 0; var reached3 := 0; var pwins := 0; var dursum := 0.0
		for s in [1, 2, 3, 4, 5, 6]:
			for mp in maps:
				var r = _encounter(n, player_lvl, s, mp)
				games += 1
				dursum += r["dur"]
				if r["result"] != "players": boss_wins += 1
				else: pwins += 1
				if r["maxphase"] >= 3: reached3 += 1
		print("   vs %d player(s): boss wins %d/%d (%2.0f%%)  | phase3 reached %d/%d  | avg %ds" % [
			n, boss_wins, games, 100.0 * boss_wins / games, reached3, games, int(dursum / games)])

func _init() -> void:
	print("=== Head Coach boss vs N format-5 lvl-8 AI players (FLOOR: no adds, full-power ult, AI doesn't dodge) ===")
	_measure(8)
	quit()
