extends SceneTree
## Verifies the snapshot-META optimization end-to-end in logic:
##  SERVER: ships META only when it changes (or on the heartbeat) — change-detected via str(meta).hash().
##  CLIENT: caches the last META and overlays it onto every snapshot, so _state always carries self/pads/portals
##          even on the (vast majority of) ticks where META is omitted.

var pass_n := 0
var fail_n := 0
func ok(c: bool, l: String) -> void:
	if c: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % l)

const HEARTBEAT := 30

# --- server: decide whether to attach META this tick (mirrors Server._broadcast) ---
var _meta_hash := {}
var _meta_tick := {}
func server_send(pid: int, snap: Dictionary, meta: Dictionary, snap_count: int) -> bool:
	var mh := str(meta).hash()
	if not _meta_hash.has(pid) or int(_meta_hash[pid]) != mh or (snap_count - int(_meta_tick.get(pid, -9999))) >= HEARTBEAT:
		snap["meta"] = meta
		_meta_hash[pid] = mh
		_meta_tick[pid] = snap_count
		return true
	return false

# --- client: overlay cached META (mirrors NetClient.receive_snapshot) ---
var _meta := {}
var _state := {}
func client_recv(snap: Dictionary) -> void:
	if snap.has("meta"):
		_meta = snap["meta"]
	for k in _meta:
		snap[k] = _meta[k]
	_state = snap

func _init() -> void:
	var META := {"self": {"level": 5, "maxHP": 120.0, "equip_bonus": {"PWR": 3}}, "portals": [{"to": "home"}],
		"shop": {"x": 1240.0, "y": 420.0}}

	# ---- 1. change detection: unchanged META hashes identical; changed differs ----
	ok(str(META).hash() == str(META.duplicate(true)).hash(), "identical META → identical hash (omit on unchanged ticks)")
	var m2 := META.duplicate(true); m2["self"]["level"] = 6
	ok(str(META).hash() != str(m2).hash(), "changed META (level up) → different hash → re-ship")

	# ---- 2. first snapshot MUST carry META (client starts with an empty cache) ----
	ok(server_send(1, {"fighters": []}, META, 0) == true, "first tick ships META (no cached hash yet)")

	# ---- 3. steady state: unchanged META omitted for the next 29 ticks, then heartbeat re-ships at +30 ----
	var omitted := 0
	var reship := -1
	for t in range(1, 40):
		var s := {"fighters": []}
		if server_send(1, s, META, t):
			if reship < 0: reship = t
		else:
			omitted += 1
	ok(omitted >= 25, "unchanged META omitted on the vast majority of ticks (%d/39 omitted)" % omitted)
	ok(reship == HEARTBEAT, "heartbeat re-ships META at exactly +%d ticks (got +%d)" % [HEARTBEAT, reship])

	# ---- 4. client overlay: a snapshot WITHOUT meta still yields full _state from cache ----
	client_recv({"fighters": [{"id": "a"}], "meta": META.duplicate(true)})   # tick with meta
	ok(_state.has("self") and int(_state["self"]["level"]) == 5 and _state.has("shop"), "client caches META on the meta-bearing tick")
	client_recv({"fighters": [{"id": "a", "x": 10.0}]})                       # tick WITHOUT meta
	ok(_state.has("self") and int(_state["self"]["level"]) == 5, "self sheet survives a meta-less tick (overlay from cache)")
	ok(_state.has("portals") and _state.has("shop"), "portals + pads survive a meta-less tick")
	ok(_state["fighters"][0].get("x", 0.0) == 10.0, "the live per-tick data (fighter x) still updates")

	# ---- 5. a CHANGED meta replaces the cache wholesale (e.g. leaving home drops the shop pad) ----
	client_recv({"fighters": [], "meta": {"self": {"level": 5}, "portals": [{"to": "combat"}]}})   # new zone: no shop
	ok(not _state.has("shop"), "leaving home (new META without shop) → stale pad cleared (wholesale replace)")
	ok(_state.has("portals") and str(_state["portals"][0]["to"]) == "combat", "portals updated to the new zone")

	print("=== snapshot-meta: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
