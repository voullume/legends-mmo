extends SceneTree
## Fast FORMAT_MODS[5] tuning harness: baseline 8-class round-robin (no talents), 3 seeds x 5 maps.
## Matches bal_p1's 6-seed spread within ~3 pts (verified), so it's a reliable ~2x-faster tuning signal.
## Goal: pull every class toward ~50% (spread < ~15). Confirm the final with tools/bal_p1.gd (6 seeds).
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")
const SEEDS := [1, 2, 3]
const TEAM := 5

func _init() -> void:
	var classes: Array = GameData.playable_ids()
	var maps: Array = GameData.MAP_IDS
	var wins := {}
	var games := {}
	for c in classes:
		wins[c] = 0.0
		games[c] = 0.0
	for i in classes.size():
		for j in classes.size():
			if i == j:
				continue
			var a: String = classes[i]
			var b: String = classes[j]
			var ca := []
			var cb := []
			for _k in TEAM:
				ca.append(a)
				cb.append(b)
			for s in SEEDS:
				for m in maps:
					var w = Sim.run_headless_match(ca, cb, s, m)["winner"]
					games[a] += 1.0
					games[b] += 1.0
					if w == 0:
						wins[a] += 1.0
					elif w == 1:
						wins[b] += 1.0
					else:
						wins[a] += 0.5
						wins[b] += 0.5
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
	print("spread=%.1f  | %s" % [hi - lo, line])
	quit(0)
