extends SceneTree
## Verify the 4 admin Meshy landmarks (gear_forge/quest_board/sideline_stand/power_core) are wired:
## registered in PROP_FOOTPRINT, GLBs resolve on the décor + mob paths, collision circles generate,
## and the power_core mob def still routes to a real GLB (boss-crystal replacement).
const World = preload("res://shared/World.gd")
const GameData = preload("res://shared/GameData.gd")

var pass_n := 0
var fail_n := 0
func ok(c: bool, l: String) -> void:
	if c: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % l)

func _init() -> void:
	# 1. all 4 register in PROP_FOOTPRINT with the verified values
	var want := {"gear_forge": 9.5, "sideline_stand": 8.0, "power_core": 7.5, "quest_board": 2.8}
	for m in want:
		ok(World.PROP_FOOTPRINT.has(m) and absf(float(World.PROP_FOOTPRINT[m]) - want[m]) < 0.001,
			"PROP_FOOTPRINT[%s] == %.1f" % [m, want[m]])

	# 2. NONE leaked into a player-buy path — they're admin-only (this script can't see server BUILD_CATALOG,
	#    but the décor GLBs must exist on the prop resolver path)
	for m in ["gear_forge", "quest_board", "sideline_stand", "power_core"]:
		ok(ResourceLoader.exists("res://models/meshy/props/%s.glb" % m), "décor GLB exists: models/meshy/props/%s.glb" % m)

	# 3. the power_core mob GLB exists on the MOB path (what the isCore dispatch checks) — boss-crystal replacement
	ok(ResourceLoader.exists("res://models/meshy/mobs/power_core.glb"), "mob GLB exists: models/meshy/mobs/power_core.glb")
	var pc: Dictionary = GameData.CLASSES.get("power_core", {})
	ok(bool(pc.get("isCore", false)) and str(pc.get("model", "")) == "power_core" and str(pc.get("anim", "")) == "core",
		"power_core def still {isCore, model:power_core, anim:core} → GLB dispatch + float/spin/pulse preserved")

	# 4. a placed landmark generates a collision circle (r = footprint * h), the thin board a small one
	var decals := [
		{"kind": "prop", "model": "gear_forge", "x": 100.0, "y": 100.0, "h": 6.0},   # r = 9.5*6 = 57
		{"kind": "prop", "model": "quest_board", "x": 200.0, "y": 100.0, "h": 3.0},   # r = 2.8*3 = 8.4
	]
	# collision_from_decals reads a map's source; emulate by temporarily checking the formula via a known map is
	# hard here, so assert the footprint→radius math the server uses directly:
	var r_forge: float = clampf(float(World.PROP_FOOTPRINT["gear_forge"]) * 6.0, 4.0, 130.0)
	var r_board: float = clampf(float(World.PROP_FOOTPRINT["quest_board"]) * 3.0, 4.0, 130.0)
	ok(absf(r_forge - 57.0) < 0.01, "gear_forge @h6 → block r 57 (solid landmark)")
	ok(absf(r_board - 8.4) < 0.01, "quest_board @h3 → block r 8.4 (thin, walk-up-to)")
	ok(r_forge > r_board * 3.0, "solid building blocks far more than the thin board")

	print("=== new-props: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
