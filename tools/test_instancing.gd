extends SceneTree
## P0+P1 instancing + Intensity test (server-side; no net/supa). Proves: instance create/teardown lifecycle
## + no per-id dict leak; Intensity scaling (higher tier → more mob HP/dmg via _scale_mob); the clear-objective
## flag is stamped; the XP curve is monotonic and the level cap is bounded. Pure/headless — the DB unlock +
## enter_camp RPC + client selector are verified separately (MCP + live connect).
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _objective_mob(srv, key: String):
	for f in srv._worlds[key]["fighters"]:
		if f.get("objective", false):
			return f
	return null

func _init() -> void:
	var srv = ServerScript.new()
	for mapname in World.MAPS:
		if World.is_instance_template(mapname):
			continue
		srv._worlds[mapname] = srv._new_world(mapname)
	srv._spawn_world_actors()

	# --- template parsing ---
	ok(srv._template("camp#p9#3") == "camp", "_template strips instance+tier suffix")
	ok(srv._template("home") == "home", "_template leaves static names")
	ok(srv._is_instance("camp#p9#3") and not srv._is_instance("home"), "_is_instance parse")
	ok(not srv._worlds.has("camp"), "camp template is NOT a static world")

	var static_worlds: int = srv._worlds.size()
	var home_mobs := 0
	for f in srv._worlds["home"]["fighters"]:
		if f["team"] == 1: home_mobs += 1

	# --- create (tier 1) ---
	var key: String = srv._ensure_instance("camp", "ptest", 1)
	ok(key == "camp#ptest#1", "instance key format includes tier")
	ok(srv._worlds.has(key) and srv._worlds.size() == static_worlds + 1, "one new world created")
	var mobs := []
	for f in srv._worlds[key]["fighters"]:
		if f["team"] == 1: mobs.append(str(f["id"]))
	ok(mobs.size() == (World.MOBS["camp"] as Array).size(), "spawned the template roster (%d)" % mobs.size())
	var obj1 = _objective_mob(srv, key)
	ok(obj1 != null, "clear-objective mob is flagged")

	# --- idempotent rejoin ---
	ok(srv._ensure_instance("camp", "ptest", 1) == key and srv._worlds.size() == static_worlds + 1, "re-ensure idempotent")

	# --- Intensity scaling: a tier-3 instance's objective mob has ~2.56x (1.6^2) the HP of the tier-1 one ---
	var key3: String = srv._ensure_instance("camp", "ptest3", 3)
	var obj3 = _objective_mob(srv, key3)
	ok(obj3 != null, "tier-3 objective mob exists")
	var o1: Dictionary = obj1
	var o3: Dictionary = obj3
	var ratio: float = float(o3["maxHP"]) / maxf(1.0, float(o1["maxHP"]))
	ok(abs(ratio - pow(1.6, 2)) < 0.05, "tier-3 HP ≈ 1.6^2 × tier-1 (got %.2f)" % ratio)
	ok(float(o3["dmgMult"]) > float(o1["dmgMult"]), "tier-3 dmg > tier-1 dmg")
	ok(int(o3.get("intensity", 0)) == 3, "objective mob carries its intensity tier")

	# --- Intensity curve helpers monotonic + tier 1 is a no-op ---
	ok(abs(srv._intensity_hp(1) - 1.0) < 0.001 and abs(srv._intensity_dmg(1) - 1.0) < 0.001, "Intensity 1 = ×1 (open-world safe)")
	ok(srv._intensity_hp(5) > srv._intensity_hp(4) and srv._intensity_dmg(5) > srv._intensity_dmg(4), "Intensity curves monotonic")

	# --- open-world mobs are unaffected (intensity defaults to 1) ---
	var open_mob = null
	for f in srv._worlds["glitchyard_1"]["fighters"]:
		if f["team"] == 1: open_mob = f; break
	ok(open_mob != null and int(open_mob.get("intensity", 1)) == 1, "open-world mobs default to Intensity 1")

	# --- XP curve: monotonic, super-linear, bounded cap ---
	ok(srv._xp_to_next(30) > srv._xp_to_next(8) and srv._xp_to_next(8) > srv._xp_to_next(1), "XP curve monotonic")
	ok(ServerScript.LEVEL_CAP == 30, "level cap = 30")

	# --- teardown both instances, assert no per-id leak ---
	var pfid: String = srv._spawn_fighter("striker", 0, World.CAMP_SPAWN, key)
	srv._maybe_teardown_instance(key)
	ok(srv._worlds.has(key), "occupied instance survives teardown check")
	# a DEAD-but-connected player must ALSO hold the instance (the soft-lock regression the review caught)
	var pf2: Dictionary = srv._find(pfid)
	pf2["alive"] = false
	srv._maybe_teardown_instance(key)
	ok(srv._worlds.has(key), "instance held by a DOWNED (dead-but-connected) player — not torn down")
	srv._remove_fighter(pfid)
	srv._maybe_teardown_instance(key)
	srv._maybe_teardown_instance(key3)
	ok(not srv._worlds.has(key) and not srv._worlds.has(key3), "empty instances torn down")
	ok(srv._worlds.size() == static_worlds, "world count back to baseline")
	var leaked := 0
	for mid in mobs:
		if srv._spawn_pos.has(mid) or srv._respawn.has(mid) or srv._mob_engaged.has(mid) or srv._tp_next.has(mid):
			leaked += 1
	ok(leaked == 0 and not srv._spawn_pos.has(pfid), "no per-id dict leak after teardown")

	var home_mobs2 := 0
	for f in srv._worlds["home"]["fighters"]:
		if f["team"] == 1: home_mobs2 += 1
	ok(home_mobs2 == home_mobs, "static home roster untouched")

	print("=== instancing + Intensity: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
