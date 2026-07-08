extends SceneTree
## Builder Mode P1 smoke — the private Locker Room zone (server-side; a stub Supabase for the placed-items read).
## Proves: the locker_room instance template + Home entry pad + exit portal exist and it's a SAFE, mob-less room;
## per-CHARACTER instance keying (keyed by char_id, NOT party/fid); _enter_locker_room gates on locker_unlocked;
## entry loads + caches the character's placed build items as decals; empty instances tear down; and _locker_decals
## formats rows into the {kind:"prop",...} decals Client._render_decals draws. Live DB read + walk-on portal +
## the snapshot attach are verified on connect.
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

# stand-in for Supabase — no HTTP; returns canned placed rows + records calls.
class StubSupa extends Node:
	var service_key := "stub"
	var rows := []                 # what get_placed_build_items_as returns
	var reads := 0
	func get_placed_build_items_as(_token, _char_id) -> Array:
		reads += 1
		return rows.duplicate(true)
	func save_character_as(_t, _c, _f) -> Dictionary:
		return {"ok": true}

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _boot(srv) -> void:
	for mapname in World.MAPS:
		if World.is_instance_template(mapname):
			continue
		srv._worlds[mapname] = srv._new_world(mapname)
	srv._spawn_world_actors()

# put a player fighter into home + a matching session; returns the fid
func _join(srv, pid: int, char_id: String, unlocked: bool) -> String:
	var fid: String = srv._spawn_fighter("striker", 0, World.HOME_SPAWN, World.HOME)
	srv._session[pid] = {"fid": fid, "access": "tok", "char_id": char_id, "name": "P%d" % pid,
		"xp": 0, "level": 1, "map": World.HOME, "credits": 0, "tokens": 0, "locker_unlocked": unlocked}
	if not (pid in srv._peers): srv._peers.append(pid)
	return fid

func _init() -> void:
	_run()

func _run() -> void:
	var srv = ServerScript.new()
	srv.supa = StubSupa.new()
	srv.net = null
	_boot(srv)

	# ---- 1. template + world config ----
	ok(World.LOCKER == "locker_room", "World.LOCKER = locker_room")
	ok(World.is_instance_template("locker_room"), "locker_room is an instance template (not a static world)")
	ok(not srv._worlds.has("locker_room"), "locker_room template is NOT booted as a static world")
	ok(srv._template("locker_room#abc#1") == "locker_room" and srv._is_instance("locker_room#abc#1"), "instance key parses to the template")
	var cfg: Dictionary = World.cfg("locker_room")
	ok(str(cfg.get("type")) == "safe" and not bool(cfg.get("aggro", true)) and not bool(cfg.get("pvp", true)), "locker_room is a SAFE, no-aggro, no-pvp room")

	# ---- 2. portals: a Home auto-entry pad + an exit back to home ----
	var home_entry = null
	for p in World.PORTALS.get(World.HOME, []):
		if str(p.get("instance", "")) == World.LOCKER: home_entry = p
	ok(home_entry != null and bool((home_entry as Dictionary).get("auto", false)), "Home has an auto walk-on Locker Room entry pad")
	var exit_ok := false
	for p in World.PORTALS.get(World.LOCKER, []):
		if str(p.get("to", "")) == World.HOME: exit_ok = true
	ok(exit_ok, "the Locker Room has an exit portal back to Home")

	# ---- 3. instance = SAFE room with NO mobs, tears down when empty ----
	var key: String = srv._ensure_instance(World.LOCKER, "charA", 1)
	ok(key == "locker_room#charA#1", "instance key is per-character (locker_room#<char>#1)")
	var mobs := 0
	for f in srv._worlds[key]["fighters"]:
		if f["team"] == 1: mobs += 1
	ok(mobs == 0, "the Locker Room spawns NO mobs (safe room)")
	srv._maybe_teardown_instance(key)
	ok(not srv._worlds.has(key), "empty locker instance torn down")

	# ---- 4. _enter_locker_room gating + per-character keying ----
	var fidLocked: String = _join(srv, 1, "charLocked", false)
	await srv._enter_locker_room(1)
	ok(str(srv._find(fidLocked)["map"]) == World.HOME, "a LOCKED player is NOT let in (stays home)")
	ok(not srv._worlds.has("locker_room#charLocked#1"), "no instance is created for a locked player")

	var fidA: String = _join(srv, 2, "charA", true)
	await srv._enter_locker_room(2)
	ok(str(srv._find(fidA)["map"]) == "locker_room#charA#1", "an UNLOCKED player enters their per-character room")

	var fidB: String = _join(srv, 3, "charB", true)
	await srv._enter_locker_room(3)
	ok(str(srv._find(fidB)["map"]) == "locker_room#charB#1", "a different character gets a DIFFERENT instance")
	ok(srv._worlds.has("locker_room#charA#1") and srv._worlds.has("locker_room#charB#1"), "both private rooms coexist")

	# same character steps out (room empties → tears down) then re-enters → the SAME key
	srv._relocate(srv._find(fidA), srv._session[2], World.HOME, World.HOME_SPAWN)
	ok(not srv._worlds.has("locker_room#charA#1"), "stepping out of an emptied room tears it down")
	await srv._enter_locker_room(2)
	ok(str(srv._find(fidA)["map"]) == "locker_room#charA#1", "re-entering returns to the same per-character key")

	# ---- 5. entry loads + caches the character's placed items as decals ----
	(srv.supa as StubSupa).rows = [{"model": "tree_oak", "xform": {"x": 120.0, "y": 200.0, "h": 3.0, "yaw": 0.5, "oy": 0.0}}]
	var fidC: String = _join(srv, 4, "charC", true)
	await srv._enter_locker_room(4)
	var meta = srv._instances.get("locker_room#charC#1")
	ok(meta != null and (meta.get("decals", []) as Array).size() == 1, "entry cached the placed item as a decal")
	var dec: Dictionary = (meta["decals"] as Array)[0]
	ok(str(dec["kind"]) == "prop" and str(dec["model"]) == "tree_oak" and abs(float(dec["x"]) - 120.0) < 0.01, "cached decal is a prop with the item's model + xform")

	# ---- 6. _locker_decals formatting (valid xform kept; null / missing xform skipped) ----
	var formatted: Array = srv._locker_decals([
		{"model": "bag", "xform": {"x": 1.0, "y": 2.0, "h": 2.5, "yaw": 0.0, "oy": 0.3}},
		{"model": "cone_x", "xform": null},          # unplaced/bad xform → skipped
		{"model": "rack"},                            # no xform → skipped
	])
	ok(formatted.size() == 1 and str(formatted[0]["model"]) == "bag" and abs(float(formatted[0]["oy"]) - 0.3) < 0.01, "_locker_decals keeps valid xforms, skips null/missing")

	# ---- 7. reconnect hardening: a tampered last_map pointing at a LIVE instance must NOT spawn you into it ----
	# (charA's room "locker_room#charA#1" is live from section 4). A client that PATCHed last_map to it — to bypass
	# the paid gate or enter another character's private room — must be sent HOME instead.
	ok(srv._worlds.has("locker_room#charA#1"), "charA's room is live for the reconnect test")
	var fidHack: String = srv._spawn_player({"class": "striker", "last_map": "locker_room#charA#1"}, 1)
	ok(str(srv._find(fidHack)["map"]) == World.HOME, "reconnect with a tampered instance last_map spawns HOME, not into the live instance")
	var fidCamp: String = srv._spawn_player({"class": "striker", "last_map": "camp#someone#5"}, 1)
	ok(str(srv._find(fidCamp)["map"]) == World.HOME, "the same guard also blocks tampered Camp/Drill instance keys")
	var fidZone: String = srv._spawn_player({"class": "striker", "last_map": World.GY1}, 1)
	ok(str(srv._find(fidZone)["map"]) == World.GY1, "a legit static-zone last_map still resumes there (no regression)")

	(srv.supa as Node).free()
	srv.free()
	print("=== builder P1: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
