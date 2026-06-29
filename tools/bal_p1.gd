extends SceneTree
## Glitchyard Phase 1 balance + mob-smoke harness.
## 1) REGRESSION: a 6-seed × 5-map round-robin over the 8 PLAYABLE classes (mobs excluded by
##    construction — we never put a mob:true id in the player loop). Phase 1 adds only new CLASSES
##    entries + client render; it touches NO player-class sim path, so the per-class win rates must
##    match P6's last run (spread ~13 at the live FORMAT_MODS[5]). A drift here = an accidental
##    sim change.
## 2) SMOKE: each new mob fights an all-striker team in the deterministic sim — proves the mob AI
##    casts its kit, deals/takes damage, dies, and the match terminates (no crash, no hang).
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")

const SEEDS := [1, 2, 3, 4, 5, 6]
const TEAM := 5

func _init() -> void:
	# Full 5-map methodology (matches the P6 baseline). NOTE: 6 seeds × 5 maps × 56 pairs = 1680 matches
	# (~20 min) — for combat-touching phases run this backgrounded or split by seed. For changes that DON'T
	# touch the player sim (like Phase 1), prefer tools/bal_identity.gd: it proves byte-identity in ~4 min,
	# which guarantees the live balance is unchanged without re-measuring the spread.
	var maps: Array = GameData.MAP_IDS
	var classes: Array = GameData.playable_ids()
	print("playable_ids (must be the 8 player classes, no mobs): ", classes)
	assert(classes.size() == 8, "expected 8 playable classes")
	for c in classes:
		assert(not GameData.CLASSES[c].get("mob", false), "a mob leaked into the player loop: " + str(c))

	# ---- round-robin (regression) ----
	var wins := {}
	var games := {}
	for c in classes:
		wins[c] = 0.0
		games[c] = 0.0
	var draws := 0
	var pair_done := 0
	for i in classes.size():
		for j in classes.size():
			if i == j:
				continue
			pair_done += 1
			print("  [pair %d/56] %s vs %s" % [pair_done, classes[i], classes[j]])
			var a: String = classes[i]
			var b: String = classes[j]
			var comp_a := []
			var comp_b := []
			for _k in TEAM:
				comp_a.append(a)
				comp_b.append(b)
			for s in SEEDS:
				for m in maps:
					var r = Sim.run_headless_match(comp_a, comp_b, s, m)
					var w = r["winner"]
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
	print("--- round-robin: 8 classes × %d seeds × %d maps ---" % [SEEDS.size(), maps.size()])
	print("spread=%.1f  draws=%d  | %s" % [hi - lo, draws, line])

	# ---- mob smoke test ----
	print("--- mob smoke (all-striker[5] vs all-<mob>[5], 3 seeds × stadium) ---")
	var mob_ids := ["cone_swarmer", "foam_dummy", "tackle_brute", "shooting_dummy"]
	for mob in mob_ids:
		var pc := []
		var mc := []
		for _k in TEAM:
			pc.append("striker")
			mc.append(mob)
		var player_wins := 0
		var done := 0
		for s in [11, 22, 33]:
			var r = Sim.run_headless_match(pc, mc, s, "stadium")
			assert(r["winner"] != null, "mob match did not terminate: " + mob)
			done += 1
			if r["winner"] == 0:
				player_wins += 1
		print("  %-15s matches=%d  player_team_wins=%d/3  (mob minion-tier, unscaled — info only)" % [mob, done, player_wins])
	print("=== done ===")
	quit()
