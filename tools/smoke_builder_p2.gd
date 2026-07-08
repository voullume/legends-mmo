extends SceneTree
## Builder Mode P2 smoke — the build RPCs (server-side; a stub Supabase that MODELS the inventory table so the
## gated place/move/remove behave like the real atomic PATCHes). Proves: build_buy gates on home + a real catalog
## model + credits + the 50/20 caps (fetched under the lock, fail-closed on a read error), deducts once, refunds on
## insert failure; place/move/remove require being in your OWN locker, are dupe-safe (gated), clamp client coords
## into the room, and keep the instance decal cache in sync; remove returns the SAME item to the Build tab.
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

# a stub that models the inventory rows so the gated PATCHes are realistic (place only if unplaced+owned, etc.)
class StubSupa extends Node:
	var service_key := "stub"
	var inv := {}                  # uuid -> {char, model, placed, xform}
	var n := 0
	var fail_insert := false       # add_build_item_as fails (test the refund path)
	var fail_count := false        # build_owned_models_as returns null (test fail-closed)
	var fail_read := false         # get_placed_build_items_as returns null (test the cache-keep-on-error path)
	func _uid(i: int) -> String:
		return "00000000-0000-0000-0000-%012d" % i
	func seed(char_id: String, model: String, count: int) -> void:
		for i in count:
			n += 1
			inv[_uid(n)] = {"char": char_id, "model": model, "placed": false, "xform": null}
	func build_owned_models_as(char_id: String):
		if fail_count: return null
		var out := []
		for id in inv:
			if inv[id]["char"] == char_id: out.append(inv[id]["model"])
		return out
	func add_build_item_as(char_id: String, model: String) -> Dictionary:
		if fail_insert: return {"ok": false}
		n += 1
		var id := _uid(n)
		inv[id] = {"char": char_id, "model": model, "placed": false, "xform": null}
		return {"ok": true, "id": id}
	func build_place_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
		var it = inv.get(item_id)
		if it == null or it["char"] != char_id or it["placed"]: return {"ok": false}   # gated: owned + unplaced
		it["placed"] = true; it["xform"] = xform
		return {"ok": true}
	func build_move_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
		var it = inv.get(item_id)
		if it == null or it["char"] != char_id or not it["placed"]: return {"ok": false}
		it["xform"] = xform
		return {"ok": true}
	func build_remove_as(char_id: String, item_id: String) -> Dictionary:
		var it = inv.get(item_id)
		if it == null or it["char"] != char_id or not it["placed"]: return {"ok": false}
		it["placed"] = false; it["xform"] = null
		return {"ok": true}
	func get_placed_build_items_as(_token, char_id: String):
		if fail_read: return null   # simulate a transient read error → caller must KEEP its prior cache
		var out := []
		for id in inv:
			if inv[id]["char"] == char_id and inv[id]["placed"]:
				out.append({"model": inv[id]["model"], "xform": inv[id]["xform"]})
		return out
	func save_character_as(_t, _c, _f) -> Dictionary:
		return {"ok": true}
	# find the first unplaced item id of char (for place tests)
	func first_owned(char_id: String) -> String:
		for id in inv:
			if inv[id]["char"] == char_id and not inv[id]["placed"]: return str(id)
		return ""

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _sess_home(srv, pid: int, char_id: String, credits: int) -> void:
	srv._session[pid] = {"fid": "f%d" % pid, "access": "tok", "char_id": char_id, "name": "P%d" % pid,
		"xp": 0, "level": 1, "map": World.HOME, "credits": credits, "tokens": 0, "locker_unlocked": true}

func _init() -> void:
	_run()

func _run() -> void:
	var srv = ServerScript.new()
	var stub := StubSupa.new()
	srv.supa = stub
	srv.net = null

	# ================= build_buy =================
	# not at home → no-op
	_sess_home(srv, 1, "cA", 5000); srv._session[1]["map"] = "glitchyard_1"
	await srv._do_build_buy(1, "tree_oak")
	ok(int(srv._session[1]["credits"]) == 5000 and stub.inv.is_empty(), "build_buy outside home is a no-op")

	# unknown/forged model → no-op (no charge, no insert)
	_sess_home(srv, 1, "cA", 5000)
	await srv._do_build_buy(1, "totally_fake_model")
	ok(int(srv._session[1]["credits"]) == 5000 and stub.inv.is_empty(), "build_buy of an unknown model is a no-op")

	# insufficient credits → no-op
	_sess_home(srv, 1, "cA", 999)
	await srv._do_build_buy(1, "tree_oak")   # 1000
	ok(int(srv._session[1]["credits"]) == 999 and stub.inv.is_empty(), "build_buy with too few credits is a no-op")

	# valid buy → deduct once + one unplaced row
	_sess_home(srv, 1, "cA", 5000)
	await srv._do_build_buy(1, "tree_oak")
	ok(int(srv._session[1]["credits"]) == 4000, "valid build_buy deducts the price once (5000→4000)")
	ok(stub.inv.size() == 1, "valid build_buy inserts exactly one row")
	var only = stub.inv[stub.inv.keys()[0]]
	ok(str(only["model"]) == "tree_oak" and not only["placed"], "the bought item is the model, UNPLACED")

	# fail-closed: a failed count read → no charge, no insert
	stub.fail_count = true
	_sess_home(srv, 1, "cA", 5000)
	var before_n := stub.inv.size()
	await srv._do_build_buy(1, "bag")
	ok(int(srv._session[1]["credits"]) == 5000 and stub.inv.size() == before_n, "build_buy fails CLOSED when the count read fails")
	stub.fail_count = false

	# insert failure → full refund
	stub.fail_insert = true
	_sess_home(srv, 1, "cA", 5000)
	await srv._do_build_buy(1, "bag")   # 1500
	ok(int(srv._session[1]["credits"]) == 5000, "build_buy refunds in full when the insert fails")
	stub.fail_insert = false

	# owned cap: seed 50 → any buy no-ops (no charge)
	stub.inv.clear(); stub.seed("cCap", "flower_redA", 50)
	_sess_home(srv, 2, "cCap", 100000)
	await srv._do_build_buy(2, "bag")
	ok(int(srv._session[2]["credits"]) == 100000 and stub.inv.size() == 50, "at 50 owned → build_buy is capped (no charge, no insert)")

	# per-model cap: seed 20 tree_oak → tree_oak no-ops, but a DIFFERENT model succeeds
	stub.inv.clear(); stub.seed("cMod", "tree_oak", 20)
	_sess_home(srv, 3, "cMod", 100000)
	await srv._do_build_buy(3, "tree_oak")
	ok(stub.inv.size() == 20 and int(srv._session[3]["credits"]) == 100000, "at 20 of one model → that model is capped")
	await srv._do_build_buy(3, "bag")
	ok(stub.inv.size() == 21 and int(srv._session[3]["credits"]) == 98500, "a DIFFERENT model still buys (owned 20<50)")

	# ================= place / move / remove =================
	stub.inv.clear()
	stub.seed("cP", "tree_oak", 1)
	var item := stub.first_owned("cP")
	# put the player in THEIR OWN locker instance
	var key := srv._ensure_instance(World.LOCKER, "cP", 1)
	_sess_home(srv, 4, "cP", 0); srv._session[4]["map"] = key

	# place from OUTSIDE your locker → no-op (guard)
	srv._session[4]["map"] = World.HOME
	await srv._do_build_place(4, item, {"x": 100.0, "y": 100.0, "h": 2.0, "yaw": 0.0})
	ok(not stub.inv[item]["placed"], "place is refused when you're not in your own locker")
	srv._session[4]["map"] = key

	# valid place: placed + coords CLAMPED into the room (700×460; 9999 → clamped)
	await srv._do_build_place(4, item, {"x": 9999.0, "y": -50.0, "h": 99.0, "yaw": 100.0})
	ok(stub.inv[item]["placed"], "valid place flips placed=true")
	var xf: Dictionary = stub.inv[item]["xform"]
	ok(float(xf["x"]) <= 670.0 and float(xf["x"]) >= 30.0, "placed x is clamped inside the room walls")
	ok(float(xf["y"]) >= 30.0 and float(xf["y"]) <= 430.0, "placed y is clamped inside the room walls")
	ok(float(xf["h"]) <= 15.0, "placement scale (h) is clamped to BUILD_H_MAX")
	ok(srv._instances[key].get("decals", []).size() == 1, "placing refreshed the instance decal cache")

	# re-place the same (already-placed) item → gated no-op
	var xf_before = stub.inv[item]["xform"].duplicate()
	await srv._do_build_place(4, item, {"x": 50.0, "y": 50.0, "h": 1.0, "yaw": 0.0})
	ok(stub.inv[item]["xform"]["x"] == xf_before["x"], "re-placing an already-placed item is a gated no-op")

	# move the placed item → xform updates (clamped)
	await srv._do_build_move(4, item, {"x": 200.0, "y": 150.0, "h": 3.0, "yaw": 0.5})
	ok(abs(float(stub.inv[item]["xform"]["x"]) - 200.0) < 0.01, "move updates the placed item's xform")

	# remove → returns the SAME item to the Build tab (placed=false), decal cache empties
	await srv._do_build_remove(4, item)
	ok(not stub.inv[item]["placed"] and stub.inv.size() == 1, "remove returns the SAME item to the Build tab (no dupe, no delete)")
	ok(srv._instances[key].get("decals", []).size() == 0, "removing emptied the instance decal cache")
	# move a now-UNPLACED item → gated no-op
	await srv._do_build_move(4, item, {"x": 300.0, "y": 300.0, "h": 2.0, "yaw": 0.0})
	ok(not stub.inv[item]["placed"], "moving an unplaced item is a gated no-op")

	# ================= _clamp_locker_xform =================
	var c := srv._clamp_locker_xform({"x": -999.0, "y": 99999.0, "h": -5.0, "oy": 999.0, "yaw": 0.0})
	ok(float(c["x"]) == 50.0 and float(c["y"]) == 410.0, "clamp pins x/y to the walkable margins (= ARENA_PAD 50)")
	ok(float(c["h"]) == 0.4 and float(c["oy"]) == 8.0, "clamp pins h/oy to their ranges")
	var c2 := srv._clamp_locker_xform("not a dict")
	ok(c2.has("x") and c2.has("yaw"), "clamp tolerates a non-dict xform (returns safe defaults)")

	# ===== review fixes: untrusted-input hardening =====
	# NaN / Inf / null / Array / Dict values must NEVER crash the clamp or leak through as junk — all → finite defaults
	var cj := srv._clamp_locker_xform({"x": NAN, "y": INF, "h": null, "oy": [1, 2], "yaw": {}})
	ok(is_finite(cj["x"]) and is_finite(cj["y"]) and is_finite(cj["h"]) and is_finite(cj["oy"]) and is_finite(cj["yaw"]), "clamp sanitizes NaN/Inf/null/Array/Dict to FINITE values (no crash, no junk)")
	ok(float(cj["x"]) >= 30.0 and float(cj["x"]) <= 670.0, "a NaN x clamps to a safe in-room default")
	ok(float(cj["h"]) >= 0.4 and float(cj["h"]) <= 15.0, "a null h clamps to a safe scale")
	# _locker_decals must render a junk (null-coord) DB row at a safe default instead of throwing + blanking the room
	var jd := srv._locker_decals([
		{"model": "tree_oak", "xform": {"x": 100.0, "y": 100.0, "h": 3.0, "yaw": 0.0, "oy": 0.0}},
		{"model": "bag", "xform": {"x": null, "y": null, "h": null, "yaw": null, "oy": null}},   # persisted junk
	])
	ok(jd.size() == 2 and is_finite(float(jd[1]["x"])) and is_finite(float(jd[1]["h"])), "_locker_decals renders a junk null-coord row safely (no crash, no blank)")

	# a transient placed-items READ error must KEEP the prior decal cache, not blank the room
	stub.inv.clear(); stub.seed("cR", "tree_oak", 1)
	var itR := stub.first_owned("cR")
	var keyR := srv._ensure_instance(World.LOCKER, "cR", 1)
	_sess_home(srv, 9, "cR", 0); srv._session[9]["map"] = keyR
	await srv._do_build_place(9, itR, {"x": 100.0, "y": 100.0, "h": 2.0, "yaw": 0.0})
	ok(srv._instances[keyR]["decals"].size() == 1, "placed → cache has 1 decal")
	stub.fail_read = true
	await srv._do_build_move(9, itR, {"x": 200.0, "y": 200.0, "h": 2.0, "yaw": 0.0})   # DB move ok, refresh read fails
	ok(srv._instances[keyR]["decals"].size() == 1, "a failed refresh read KEEPS the prior cache (room not blanked)")
	stub.fail_read = false

	stub.free()
	srv.free()
	print("=== builder P2: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
