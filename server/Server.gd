extends Node
## SHARED ZONE SERVER (Phase 4). One persistent, server-authoritative overworld that several
## accounts' characters share. Combines Phase 2 (authoritative ENet world tick) with Phase 3
## (accounts): a joining client authenticates with its Supabase access token, the server loads
## that account's character (class + saved position) and spawns it, and persists position back.
##
## - Players are team 0 (they coexist — abilities target enemies, so they don't hit each other).
## - A few neutral training-dummy mobs (team 1) populate the zone (botsFrozen = passive).
## - Per-client snapshots are interest-managed: a client only receives entities near its fighter.
##
## SECURITY NOTE: ENet here is UNENCRYPTED. Only the short-lived access token crosses the wire
## (never the long-lived refresh token — the client keeps that and re-issues fresh access tokens
## via reauth()). A production deployment must enable ENet DTLS before exposing this publicly.

const Sim := preload("res://shared/Sim.gd")
const GameData := preload("res://shared/GameData.gd")
const Geom := preload("res://shared/Geom.gd")
const Rng := preload("res://shared/Rng.gd")

const PORT := 7777
const MAP_ID := "stadium"
const SEED := 20260621
const SIM_DT := 1.0 / 30.0
const ZONE_TEAM_SIZE := 5
const RESPAWN_DELAY := 4.0
const SAVE_INTERVAL := 15.0
const INTEREST_RADIUS := 450.0
const STALE_INTENT_TICKS := 30
const MOBS := [
	{"class": "linebacker", "x": 620.0, "y": 200.0},
	{"class": "goalkeeper", "x": 620.0, "y": 340.0},
]

var net: Node = null
var supa: Node = null

var _state: Dictionary = {}
var _peers: Array = []
var _authing := {}                  # peer ids with an authenticate() in flight (race guard)
var _session := {}                  # peer id → {fid, access, char_id, name}
var _move := {}
var _pending_ability := {}
var _last_aseq := {}
var _intent_age := {}
var _spawn_pos := {}
var _respawn := {}
var _fseq := 0
var _acc := 0.0
var _save_t := 0.0
var _snap_count := 0

func start() -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		push_error("[zone] create_server(%d) failed: %d" % [PORT, err])
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Engine.max_fps = 60
	_state = Sim.create_match([], [], SEED, MAP_ID)
	_state["zone"] = true                        # persistent: no match-end / no overtime ramp
	_state["botsFrozen"] = true                  # mobs are passive training dummies
	for m in MOBS:
		_spawn_fighter(m["class"], 1, Vector2(m["x"], m["y"]))
	print("[zone] online on UDP %d  (map=%s, %d mobs)" % [PORT, MAP_ID, MOBS.size()])
	return true

# ---- connection / auth ----
func _on_peer_connected(pid: int) -> void:
	print("[zone] peer %d connected — awaiting auth" % pid)

func _on_peer_disconnected(pid: int) -> void:
	_authing.erase(pid)
	if not _session.has(pid):
		return
	var s = _session[pid]                        # capture before erasing (the save coroutine holds it)
	var f = _find(s["fid"])
	if f != null and f["alive"]:
		_save_one(s, f)                          # final save (fire-and-forget; uses captured session)
	_remove_fighter(s["fid"])
	_peers.erase(pid)
	_session.erase(pid)
	_move.erase(pid)
	_pending_ability.erase(pid)
	_last_aseq.erase(pid)
	_intent_age.erase(pid)
	print("[zone] peer %d left" % pid)

# client → server: prove identity with the access token; the server loads the real character.
func authenticate(pid: int, access: String, _refresh: String = "") -> void:
	if pid in _peers or _authing.has(pid) or supa == null:
		return
	_authing[pid] = true                         # reserve synchronously, BEFORE the await (race guard)
	var res = await supa.get_character_as(access)
	_authing.erase(pid)
	if not (pid in multiplayer.get_peers()) or pid in _peers:
		return                                   # peer left or got authenticated meanwhile
	if not res.get("ok") or res.get("character") == null:
		print("[zone] peer %d auth failed (%s) — kicking" % [pid, res.get("error", "no character")])
		multiplayer.multiplayer_peer.disconnect_peer(pid)
		return
	var ch = res["character"]
	var fid := _spawn_player(ch)
	_peers.append(pid)
	_session[pid] = {"fid": fid, "access": access, "char_id": str(ch["id"]), "name": str(ch.get("name", "?"))}
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	net.assign_fighter.rpc_id(pid, fid)
	print("[zone] %s (%s) joined as %s — now %d player(s)" % [ch.get("name", "?"), ch.get("class", "?"), fid, _peers.size()])

# client periodically re-issues a fresh access token (the refresh token never leaves the client)
func reauth(pid: int, access: String) -> void:
	if _session.has(pid) and access != "":
		_session[pid]["access"] = access

func _spawn_player(ch) -> String:
	var cls: String = str(ch.get("class", "striker"))
	if not GameData.CLASSES.has(cls):
		cls = "striker"
	var pos := Vector2(float(ch.get("last_x", 480.0)), float(ch.get("last_y", 270.0)))
	return _spawn_fighter(cls, 0, pos)

func _spawn_fighter(cls: String, team: int, pos: Vector2) -> String:
	var slot := 0
	for f in _state["fighters"]:
		if f["team"] == team:
			slot += 1
	_fseq += 1
	var f := GameData.create_fighter(cls, team, slot, Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	f["id"] = ("p" if team == 0 else "m") + str(_fseq)   # unique, monotonic — no slot-reuse collisions
	f["x"] = pos.x
	f["y"] = pos.y
	Geom.clamp_arena(f)
	_state["fighters"].append(f)
	_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])
	return f["id"]

func _remove_fighter(fid: String) -> void:
	var keep := []
	for f in _state["fighters"]:
		if f["id"] != fid:
			keep.append(f)
	_state["fighters"] = keep
	_spawn_pos.erase(fid)
	_respawn.erase(fid)

# ---- intents (client → server) ----
func submit_intent(pid: int, mv: Dictionary) -> void:
	if not _move.has(pid):
		return
	var v := Vector2(clampf(float(mv.get("mx", 0.0)), -1.0, 1.0), clampf(float(mv.get("my", 0.0)), -1.0, 1.0))
	if v.length() > 1.0:
		v = v.normalized()
	_move[pid] = {"mx": v.x, "my": v.y}
	_intent_age[pid] = 0

func submit_ability(pid: int, key, seq) -> void:
	if not _session.has(pid) or typeof(key) != TYPE_STRING:
		return
	if int(seq) > int(_last_aseq.get(pid, 0)):
		_last_aseq[pid] = int(seq)
		_pending_ability[pid] = key

# ---- authoritative tick ----
func _physics_process(delta: float) -> void:
	if _state.is_empty():
		return
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		_state["winner"] = null
		_state["controlled"] = {}
		for pid in _peers:
			var fid: String = _session[pid]["fid"]
			_intent_age[pid] = int(_intent_age.get(pid, 0)) + 1
			var mv = _move.get(pid, {"mx": 0.0, "my": 0.0})
			var mx: float = mv["mx"]
			var my: float = mv["my"]
			if _intent_age[pid] > STALE_INTENT_TICKS:
				mx = 0.0
				my = 0.0
			_state["controlled"][fid] = {"mx": mx, "my": my, "ability": _pending_ability.get(pid, "")}
			_pending_ability[pid] = ""
		Sim.sim_tick(_state, SIM_DT)
		_tick_respawns(SIM_DT)
		_acc -= SIM_DT
		steps += 1
	if steps == 5:
		_acc = 0.0
	_save_t += delta
	if _save_t >= SAVE_INTERVAL:
		_save_t = 0.0
		_save_all()
	if steps > 0:
		_broadcast()

func _tick_respawns(dt: float) -> void:
	for f in _state["fighters"]:
		if not f["alive"] and not _respawn.has(f["id"]):
			_respawn[f["id"]] = RESPAWN_DELAY
	var done := []
	for id in _respawn:
		_respawn[id] -= dt
		if _respawn[id] <= 0.0:
			done.append(id)
	for id in done:
		_respawn.erase(id)
		_revive(_find(id))

func _revive(f) -> void:
	if f == null:
		return
	var orig_id = f["id"]
	var fresh := GameData.create_fighter(f["classId"], f["team"], f["slot"], Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	_fseq += 1
	for k in fresh:
		f[k] = fresh[k]
	f["id"] = orig_id                            # keep the unique id across respawn
	var sp = _spawn_pos.get(orig_id, Vector2(f["x"], f["y"]))
	f["x"] = sp.x
	f["y"] = sp.y

func _find(id) -> Variant:
	for f in _state["fighters"]:
		if f["id"] == id:
			return f
	return null

# ---- persistence (server-authoritative; access token kept fresh via reauth) ----
func _save_all() -> void:
	for pid in _peers.duplicate():
		if not _session.has(pid):
			continue
		var f = _find(_session[pid]["fid"])
		if f != null and f["alive"]:
			_save_one(_session[pid], f)

func _save_one(session: Dictionary, f) -> void:
	if f == null or not f["alive"]:             # never persist a corpse's position
		return
	await supa.save_character_as(session["access"], session["char_id"],
		{"last_x": f["x"], "last_y": f["y"], "last_map": MAP_ID})

# ---- interest-managed snapshots (server → clients) ----
func _broadcast() -> void:
	for pid in _peers:
		var f = _find(_session[pid]["fid"])
		if f == null:
			continue
		net.receive_snapshot.rpc_id(pid, _snapshot_for(Vector2(f["x"], f["y"])))
	_state["events"].clear()
	_snap_count += 1
	if _snap_count % 90 == 0:
		print("[zone] t=%.1f players=%d entities=%d" % [_state["t"], _peers.size(), _state["fighters"].size()])

func _snapshot_for(center: Vector2) -> Dictionary:
	var fs := []
	for f in _state["fighters"]:
		if Vector2(f["x"] - center.x, f["y"] - center.y).length() <= INTEREST_RADIUS:
			fs.append({
				"id": f["id"], "classId": f["classId"], "team": f["team"],
				"x": f["x"], "y": f["y"], "hp": f["hp"], "maxHP": f["maxHP"],
				"alive": f["alive"], "flash": f["flash"], "cds": f["cds"].duplicate(),
			})
	var ps := []
	for p in _state["projectiles"]:
		if Vector2(p["x"] - center.x, p["y"] - center.y).length() <= INTEREST_RADIUS:
			ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0)})
	return {"fighters": fs, "projectiles": ps, "events": _state["events"].duplicate(true), "t": _state["t"]}
