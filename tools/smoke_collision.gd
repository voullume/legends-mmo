extends SceneTree
## Decoration-prop collision smoke: World.collision_from_decals reads the map's decals + makes block circles for
## SOLID props (buildings/trees/fences/rocks) but NOT flat décor (grass/flowers/rings/cones); and AI.separation
## pushes a fighter OUT of a decal circle — so players + mobs can't walk through the town's props.
const World = preload("res://shared/World.gd")
const AI = preload("res://shared/AI.gd")
const GameData = preload("res://shared/GameData.gd")
const Rng = preload("res://shared/Rng.gd")

var pass_n := 0
var fail_n := 0
func ok(c: bool, l: String) -> void:
	if c: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % l)

func _init() -> void:
	# ---- 1. footprint table: solids collide, flat décor doesn't ----
	ok(World.PROP_FOOTPRINT.has("building-a") and World.PROP_FOOTPRINT.has("tree_oak") and World.PROP_FOOTPRINT.has("fence_planks") and World.PROP_FOOTPRINT.has("rack"), "buildings/trees/fences/racks have collision footprints")
	ok(not World.PROP_FOOTPRINT.has("grass_large") and not World.PROP_FOOTPRINT.has("flower_redA") and not World.PROP_FOOTPRINT.has("cone"), "grass/flowers/cones are flat (no collision)")

	# ---- 2. collision_from_decals reads the live home.json + generates circles ----
	var circles = World.collision_from_decals("home")
	ok(circles.size() > 0, "home decoration generates collision circles (got %d)" % circles.size())
	var allok := true
	var maxr := 0.0
	for c in circles:
		if not (c is Dictionary and c.has("x") and c.has("y") and float(c.get("r", 0.0)) > 0.0):
			allok = false
		maxr = maxf(maxr, float(c.get("r", 0.0)))
	ok(allok, "every circle is {x,y,r>0}")
	ok(maxr >= 30.0, "a large prop (building) yields a big block radius (max %.0f)" % maxr)
	# r scales with h: the same model at 2× height → 2× radius
	var r1 = World.collision_from_decals("home")   # (stable read)
	ok(r1.size() == circles.size(), "collision read is stable")

	# a map with NO decal file + no const decals → no circles (safe)
	ok(World.collision_from_decals("nonexistent_map").is_empty(), "a map with no décor yields no collision circles")

	# ---- 3. AI.separation pushes a fighter OUT of a decal circle to r+14 ----
	var rng = Rng.new(1)
	var f = GameData.create_fighter("striker", 0, 0, rng, 5)
	f["x"] = 300.0; f["y"] = 300.0                                  # start ON a circle at (300,300) r=40
	var st := {"fighters": [f], "zones": [], "map": {"id": "t", "obstacles": [{"x": 300.0, "y": 300.0, "r": 40.0}]}}
	for i in 20: AI.separation(st, f, 1.0 / 30.0)
	var dist := Vector2(f["x"] - 300.0, f["y"] - 300.0).length()
	ok(dist >= 53.0, "a fighter on a decal circle is pushed OUT to r+14 (dist %.1f, want ≥54)" % dist)

	# a fighter far from the circle is unaffected
	var f2 = GameData.create_fighter("striker", 0, 1, rng, 5)
	f2["x"] = 700.0; f2["y"] = 300.0
	var st2 := {"fighters": [f2], "zones": [], "map": {"id": "t", "obstacles": [{"x": 300.0, "y": 300.0, "r": 40.0}]}}
	var bx: float = f2["x"]; var by: float = f2["y"]
	AI.separation(st2, f2, 1.0 / 30.0)
	ok(absf(f2["x"] - bx) < 0.01 and absf(f2["y"] - by) < 0.01, "a fighter far from a circle is unaffected")

	print("=== collision: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
