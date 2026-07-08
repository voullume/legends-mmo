extends SceneTree
## Builder Mode P0 smoke — server-side foundation, headless, no net / no live DB (a stub Supabase drives the
## async unlock). Proves:
##   • the build catalog is well-formed, priced exactly per §3d, and only references props that exist on disk;
##   • _build_price maps known models → their tier price and any unknown/forged id → -1 (unbuyable);
##   • the owned (50) + per-model (20) caps gate at their boundaries and fail CLOSED on a negative count;
##   • the Locker-Room unlock lock serializes + rate-limits (one holder, 300 ms window);
##   • buy_locker_room's credit logic is correct: can't-afford no-ops, an afford charges 10,000 exactly ONCE
##     and sets the flag, an already-owned re-buy is a no-op, and a lost flip refunds in full.
## The schema + the live gated PATCH (locker_unlock_as) are verified separately (MCP introspection + a connect
## test) — this proves the pure server logic that rides on top of them.
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

# a tiny stand-in for Supabase — no HTTP; returns canned results + records calls so the test can assert on them.
class StubSupa extends Node:
	var service_key := "stub"
	var flip := true                 # what locker_unlock_as returns (true = WE flipped false→true)
	var unlock_calls := 0
	var saves := 0
	func locker_unlock_as(_char_id: String) -> bool:
		unlock_calls += 1
		return flip
	func save_character_as(_token, _char_id, _fields) -> Dictionary:
		saves += 1
		return {"ok": true}

# resolve a prop id to its .glb on disk the same way Client._prop_entry does (first dir that has it wins).
const PROP_DIRS := ["res://models/meshy/props/", "res://models/kits/nature/", "res://models/kits/city/"]
func _prop_exists(id: String) -> bool:
	for d in PROP_DIRS:
		if FileAccess.file_exists(d + id + ".glb"):
			return true
	return false

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _sess(srv, credits: int, unlocked := false) -> void:
	srv._session[1] = {"fid": "f1", "access": "tok", "char_id": "c1", "name": "Tester",
		"xp": 0, "level": 1, "map": World.HOME, "credits": credits, "tokens": 0,
		"locker_unlocked": unlocked}

func _init() -> void:
	_run()   # launch the coroutine; it quit()s when done (awaits on the stub resolve synchronously)

func _run() -> void:
	var srv = ServerScript.new()

	# ---- 1. catalog integrity ----
	var tier_price := {"small": 250, "medium": 600, "tree": 1000, "prop": 1500, "large": 4000}
	var bad_price := 0
	var missing_asset := []
	for m in ServerScript.BUILD_CATALOG:
		var tier: String = str(ServerScript.BUILD_CATALOG[m])
		if int(tier_price.get(tier, -999)) != srv._build_price(m): bad_price += 1
		if not _prop_exists(str(m)): missing_asset.append(str(m))
	ok(bad_price == 0, "every catalog model prices from its tier per §3d")
	ok(missing_asset.is_empty(), "every catalog model has a .glb on disk (missing: %s)" % str(missing_asset))
	ok(ServerScript.BUILD_TIER_PRICE == tier_price, "tier prices are 250/600/1000/1500/4000 (§3d)")
	ok(srv._build_catalog().size() == (ServerScript.BUILD_CATALOG as Dictionary).size(), "_build_catalog pushes one entry per model")
	var sample = srv._build_catalog()[0]
	ok(sample.has("model") and sample.has("tier") and sample.has("price"), "_build_catalog entries carry {model,tier,price}")

	# ---- 2. _build_price: known → tier price; unknown/forged/empty → -1 (never buyable) ----
	ok(srv._build_price("tree_oak") == 1000, "tree_oak = 1000")
	ok(srv._build_price("flower_redA") == 250 and srv._build_price("stadium") == 4000, "flower_redA=250, stadium=4000")
	ok(srv._build_price("cone") == -1, "cone is NOT a build prop (special primitive kind) → -1")
	ok(srv._build_price("not_a_real_model") == -1, "unknown model → -1")
	ok(srv._build_price("") == -1, "empty model → -1")

	# ---- 3. caps: 50 total + 20 per-model, gated at the boundary; a negative (failed-fetch) count fails closed ----
	ok(ServerScript.BUILD_OWNED_CAP == 50 and ServerScript.BUILD_PER_MODEL_CAP == 20, "caps are 50 / 20")
	ok(srv._build_within_caps(0, 0), "empty inventory can buy")
	ok(srv._build_within_caps(49, 19), "at 49 owned / 19 of-model can buy the 50th")
	ok(not srv._build_within_caps(50, 0), "at 50 owned → blocked (total cap)")
	ok(not srv._build_within_caps(10, 20), "at 20 of one model → blocked (per-model cap)")
	ok(not srv._build_within_caps(-1, 0) and not srv._build_within_caps(0, -1), "a failed count (-1) fails closed")

	# ---- 4. the unlock lock: one holder at a time + a 300 ms rate-limit window ----
	_sess(srv, 20000)
	ok(srv._locker_lock(1), "first lock acquires")
	ok(not srv._locker_lock(1), "second lock while busy is rejected (serialized)")
	srv._locker_busy.erase(1)
	ok(not srv._locker_lock(1), "still rate-limited within 300 ms even after release")
	ok(not srv._locker_lock(99), "no session → no lock")

	# ---- 5. buy_locker_room credit logic (stub Supabase; call _do_ directly to isolate from the lock) ----
	var stub := StubSupa.new()
	srv.supa = stub
	srv.net = null

	# 5a. can't afford (9,999 < 10,000) → no charge, no unlock, no DB call
	_sess(srv, 9999)
	await srv._do_buy_locker_room(1)
	ok(int(srv._session[1]["credits"]) == 9999 and not bool(srv._session[1]["locker_unlocked"]), "can't afford → unchanged")
	ok(stub.unlock_calls == 0, "can't afford → no DB unlock attempted")

	# 5b. exactly affords → deduct 10,000 ONCE, flag set, persisted
	_sess(srv, 10000)
	stub.flip = true
	await srv._do_buy_locker_room(1)
	ok(int(srv._session[1]["credits"]) == 0, "afford → credits 10000→0 (charged exactly once)")
	ok(bool(srv._session[1]["locker_unlocked"]), "afford → locker_unlocked set")
	ok(stub.unlock_calls == 1 and stub.saves >= 1, "afford → one flip + a persist")

	# 5c. already owned → no-op (no re-charge, no DB call) — blocks a double-buy
	var prev_calls := stub.unlock_calls
	_sess(srv, 30000, true)
	await srv._do_buy_locker_room(1)
	ok(int(srv._session[1]["credits"]) == 30000, "already owned → no re-charge")
	ok(stub.unlock_calls == prev_calls, "already owned → no DB call")

	# 5d. lost flip (another session unlocked first) → full refund, flag stays false
	_sess(srv, 15000)
	stub.flip = false
	await srv._do_buy_locker_room(1)
	ok(int(srv._session[1]["credits"]) == 15000, "lost flip → credits refunded in full")
	ok(not bool(srv._session[1]["locker_unlocked"]), "lost flip → not unlocked")

	stub.free()   # not parented to the tree — free it so headless exit is clean
	srv.free()
	print("=== builder P0: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
