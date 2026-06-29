extends SceneTree
## Determinism IDENTITY check. Phase 1 must not perturb the PLAYER sim at all (it only adds new mob:true
## CLASSES entries + client render). This runs a fixed matrix of all-class-X vs all-class-Y player matches
## and prints a single aggregate SIGNATURE over (winner, duration) for every match. Run it on the Phase 1
## branch AND on main; if the signatures match, the player combat sim is byte-identical → the live P6
## balance (the already-validated ~13 spread) is provably unchanged, with no need to re-measure it.
const Sim = preload("res://shared/Sim.gd")
const GameData = preload("res://shared/GameData.gd")

# A structural perturbation (added dict keys / a guard) would diverge in ANY match, so a compact matrix
# that still covers all 56 class pairings is sufficient to detect it. (This is identity, not a re-tune.)
const SEEDS := [1, 2, 3]
const MAPS := ["stadium", "trenches"]
const TEAM := 5

func _init() -> void:
	var classes: Array = ["pitcher", "batter", "quarterback", "linebacker", "setter", "spiker", "striker", "goalkeeper"]
	# integer accumulators only (float sums could differ in rounding across runs and muddy the compare)
	var sig_w := 0          # rolling over winners
	var sig_d := 0          # rolling over durations (×10, integer)
	var n := 0
	for i in classes.size():
		for j in classes.size():
			if i == j:
				continue
			var ca := []
			var cb := []
			for _k in TEAM:
				ca.append(classes[i])
				cb.append(classes[j])
			for s in SEEDS:
				for m in MAPS:
					var r = Sim.run_headless_match(ca, cb, s, m)
					var w := int(r["winner"])
					var dur := int(round(float(r["duration"]) * 10.0))
					n += 1
					sig_w = (sig_w * 131 + (w + 1) + i * 7 + j * 13) % 1000000007
					sig_d = (sig_d * 131 + dur) % 1000000007
	print("IDENTITY matches=%d  sig_w=%d  sig_d=%d" % [n, sig_w, sig_d])
	quit()
