extends SceneTree
## gameplay-length P4 balance proof: does a class-SYMMETRIC talent allocation preserve the FORMAT_MODS[5]
## ~50% class win-rate spread? Talents apply at the server stat-seam (base stats + talent delta -> derive ->
## FORMAT_MODS[5]) — this harness replicates that pipeline (_recompute_player_stats) by injecting the delta into
## every fighter right after create_match, then runs the SAME round-robin as bal_p1 (8 classes x seeds x maps)
## with and without talents. If the talented spread ~= the baseline spread, symmetry holds; a big widening means
## FORMAT_MODS[5] needs a re-tune (a symmetric +PWR still MULTIPLIES the existing per-class dmg gaps).
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")

const SEEDS := [1, 2, 3]           # 3 seeds x 5 maps x 56 pairs = 840 matches/run; 2 runs (baseline+talented)
const TEAM := 5

# the worst-case-for-drift representative allocation: max Power (a5 b5 c3) + max Tempo (a5 b5 c3) + 3 into Guard a
# = 29 points (L30), highest +PWR. Symmetric across all 8 classes (TALENT_SHAPE is shared).
func _rep_talents(cls: String) -> Dictionary:
	return {
		"%s_power_a" % cls: 5, "%s_power_b" % cls: 5, "%s_power_c" % cls: 3,
		"%s_tempo_a" % cls: 5, "%s_tempo_b" % cls: 5, "%s_tempo_c" % cls: 3,
		"%s_guard_a" % cls: 3,
	}

# replicate _recompute_player_stats: base stats + capped talent delta -> derive() -> FORMAT_MODS[5]
func _apply_talents(f) -> void:
	var cls := str(f["classId"])
	var delta := GameData.talent_stat_deltas(_rep_talents(cls), cls)
	var stats: Dictionary = GameData.CLASSES[cls]["stats"].duplicate()
	for st in delta:
		stats[st] = int(stats[st]) + mini(int(delta[st]), GameData.TALENT_STAT_CAP)
	var d := GameData.derive(stats)
	var bm: Dictionary = GameData.FORMAT_MODS.get(5, {}).get(cls, {})
	var maxhp: float = d["maxHP"]
	var dmg: float = d["dmgMult"]
	if bm.has("dmg"): dmg *= bm["dmg"]
	if bm.has("hp"): maxhp = round(maxhp * bm["hp"])
	f["maxHP"] = maxhp
	f["hp"] = maxhp
	f["dmgMult"] = dmg
	f["crit"] = d["crit"]
	f["critMult"] = d["critMult"]
	f["ms"] = d["ms"]
	f["cdr"] = d["cdr"]
	f["clutchDmg"] = d["clutchDmg"]
	f["clutchDR"] = d["clutchDR"]

func _match_winner(comp_a: Array, comp_b: Array, seed_value: int, map_id: String, with_talents: bool):
	var state = Sim.create_match(comp_a, comp_b, seed_value, map_id)
	if with_talents:
		for f in state["fighters"]:
			_apply_talents(f)
	var dt := 1.0 / 30.0
	var guard := 0
	var cap := int(30 * (GameData.TIME_LIMIT + 5))
	while state["winner"] == null and guard < cap:
		Sim.sim_tick(state, dt)
		guard += 1
	return state["winner"]

func _round_robin(classes: Array, maps: Array, with_talents: bool) -> void:
	var wins := {}
	var games := {}
	for c in classes:
		wins[c] = 0.0
		games[c] = 0.0
	var draws := 0
	for i in classes.size():
		for j in classes.size():
			if i == j:
				continue
			var a: String = classes[i]
			var b: String = classes[j]
			var comp_a := []
			var comp_b := []
			for _k in TEAM:
				comp_a.append(a)
				comp_b.append(b)
			for s in SEEDS:
				for m in maps:
					var w = _match_winner(comp_a, comp_b, s, m, with_talents)
					games[a] += 1.0
					games[b] += 1.0
					if w == 0:
						wins[a] += 1.0
					elif w == 1:
						wins[b] += 1.0
					else:
						wins[a] += 0.5
						wins[b] += 0.5
						draws += 1
	var rates := []
	for c in classes:
		rates.append([c, 100.0 * wins[c] / max(1.0, games[c])])
	rates.sort_custom(func(x, y): return x[1] > y[1])
	var lo := 999.0
	var hi := -1.0
	var line := ""
	for e in rates:
		line += "%s %.0f  " % [String(e[0]).substr(0, 4), e[1]]
		lo = min(lo, e[1])
		hi = max(hi, e[1])
	print("%s  spread=%.1f  draws=%d  | %s" % ["TALENTED" if with_talents else "BASELINE", hi - lo, draws, line])

func _init() -> void:
	var maps: Array = GameData.MAP_IDS
	var classes: Array = GameData.playable_ids()
	print("P4 talent balance proof — %d classes x %d seeds x %d maps, baseline vs symmetric max-power talents" % [classes.size(), SEEDS.size(), maps.size()])
	print("rep allocation (per class): +16 PWR, +10 PRE, +16 SPD, +10 INS, +6 END  (all <= TALENT_STAT_CAP %d)" % GameData.TALENT_STAT_CAP)
	_round_robin(classes, maps, false)
	_round_robin(classes, maps, true)
	print("=> compare the two spreads: similar = symmetry holds; a big widening = FORMAT_MODS[5] re-tune needed.")
	quit(0)
