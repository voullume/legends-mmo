extends Node
## AUTHORITATIVE SERVER (Phase 2). Owns the world + combat tick using the deterministic shared
## engine, and syncs it to clients over Godot high-level multiplayer (ENet).
##
## Each connected player drives ONE fighter through the exact same Sim "controlled" seam the
## Phase-1 keyboard used — input now arrives over the network. Clients have NO authority: they
## send intents, the server validates them, runs the sim, and broadcasts snapshots.
##
## Roster is INCREMENTAL: joining, leaving, or changing class touches only the affected fighter
## — it never recreates the live match, so a disconnect or late join can't reset/teleport/heal
## the other duelist or wipe in-flight projectiles.

const Sim := preload("res://shared/Sim.gd")
const GameData := preload("res://shared/GameData.gd")
const Rng := preload("res://shared/Rng.gd")

const PORT := 7777
const MAP_ID := "stadium"
const MATCH_SEED := 20260620
const SIM_DT := 1.0 / 30.0
const DUEL_TEAM_SIZE := 1            # 1v1 bracket tuning
const RESPAWN_DELAY := 3.0
const DEFAULT_CLASS := "striker"
const STALE_INTENT_TICKS := 30       # ~1s without a fresh intent → stop drifting

var net: Node = null                 # the RPC bridge
var local_client: Node = null        # the host's own renderer (HOST mode); null when dedicated

var _state: Dictionary = {}
var _peers: Array = []               # ordered peer ids
var _peer_class := {}               # peer id → class id
var _peer_fid := {}                # peer id → fighter id
var _move := {}                    # peer id → {mx,my}     (movement, unreliable channel)
var _pending_ability := {}         # peer id → key to fire next tick (consumed once)
var _last_aseq := {}               # peer id → last ability sequence id (de-dup)
var _intent_age := {}              # peer id → ticks since last movement packet
var _spawn_pos := {}               # fighter id → Vector2 spawn (authoritative respawn point)
var _respawn := {}                 # fighter id → seconds until revive
var _fseq := 0                     # monotonic seed source for spawn jitter
var _acc := 0.0
var _snap_count := 0

func start(host_class := "") -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		push_error("[server] create_server(%d) failed: %d (port in use?)" % [PORT, err])
		if local_client != null:
			local_client.net_error("Server failed to start on UDP %d (port in use?)" % PORT)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Engine.max_fps = 60                 # don't busy-spin the headless main loop
	# start from a valid but empty world; players are added incrementally
	_state = Sim.create_match([], [], MATCH_SEED, MAP_ID)
	if local_client != null:            # HOST: the host plays as peer id 1
		var hc: String = host_class if host_class in GameData.class_ids() else DEFAULT_CLASS
		_add_player(1, hc)
	print("[server] listening on UDP %d  (map=%s)" % [PORT, MAP_ID])
	return true

# ---- roster (incremental — never recreates the live match) ----
func _on_peer_connected(pid: int) -> void:
	print("[server] peer %d connected" % pid)
	_add_player(pid, DEFAULT_CLASS)

func _on_peer_disconnected(pid: int) -> void:
	print("[server] peer %d disconnected" % pid)
	var fid: String = _peer_fid.get(pid, "")
	_peers.erase(pid)
	_peer_class.erase(pid)
	_peer_fid.erase(pid)
	_move.erase(pid)
	_pending_ability.erase(pid)
	_last_aseq.erase(pid)
	_intent_age.erase(pid)
	if fid != "":
		_remove_fighter(fid)            # only the leaver's fighter — survivor is untouched

func _add_player(pid: int, cls: String) -> void:
	if pid in _peers:
		return
	_peers.append(pid)
	_peer_class[pid] = cls
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	var team := _team_for_new()
	var fid := _spawn_fighter(pid, cls, team)
	_assign_fighter(pid, fid)
	print("[server] +player %d as %s → fighter %s (%d total)" % [pid, cls, fid, _peers.size()])

# client handshake: pick a class. Recreates ONLY this player's own fighter (resets just them,
# normally pre-combat at connect) — it does NOT touch the opponent.
func set_peer_class(pid: int, cls: String) -> void:
	if not (cls in GameData.class_ids()) or _peer_class.get(pid, "") == cls:
		return
	_peer_class[pid] = cls
	if not _peer_fid.has(pid):
		return
	var old_fid: String = _peer_fid[pid]
	var of = _find(old_fid)
	var team: int = of["team"] if of != null else _team_for_new()
	if of != null:
		_remove_fighter(old_fid)
	var fid := _spawn_fighter(pid, cls, team)
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_assign_fighter(pid, fid)

func _team_for_new() -> int:
	var c0 := 0
	var c1 := 0
	for f in _state["fighters"]:
		if f["team"] == 0:
			c0 += 1
		else:
			c1 += 1
	return 0 if c0 <= c1 else 1

func _spawn_fighter(pid: int, cls: String, team: int) -> String:
	var slot := 0
	for f in _state["fighters"]:
		if f["team"] == team:
			slot += 1
	_fseq += 1
	var f := GameData.create_fighter(cls, team, slot, Rng.new(MATCH_SEED + _fseq), DUEL_TEAM_SIZE)
	_state["fighters"].append(f)
	_peer_fid[pid] = f["id"]
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

func _assign_fighter(pid: int, fid: String) -> void:
	if pid == 1 and local_client != null:
		local_client.assign_fighter(fid)
	elif net != null:
		net.assign_fighter.rpc_id(pid, fid)

# ---- intents (client → server) ----
# movement on the unreliable channel: validated + clamped, latest wins
func submit_intent(pid: int, mv: Dictionary) -> void:
	if not _move.has(pid):
		return
	var v := Vector2(clampf(float(mv.get("mx", 0.0)), -1.0, 1.0), clampf(float(mv.get("my", 0.0)), -1.0, 1.0))
	if v.length() > 1.0:
		v = v.normalized()
	_move[pid] = {"mx": v.x, "my": v.y}
	_intent_age[pid] = 0

# abilities on the reliable channel: de-duplicated by sequence id, fired once
func submit_ability(pid: int, key, seq) -> void:
	if not _peer_fid.has(pid) or typeof(key) != TYPE_STRING:
		return
	if int(seq) > int(_last_aseq.get(pid, 0)):
		_last_aseq[pid] = int(seq)
		_pending_ability[pid] = key

func submit_intent_local(pid: int, mv: Dictionary) -> void:   # host's own movement
	submit_intent(pid, mv)

func submit_ability_local(pid: int, key, seq) -> void:        # host's own ability
	submit_ability(pid, key, seq)

# ---- authoritative tick ----
func _physics_process(delta: float) -> void:
	if _state.is_empty() or _state["fighters"].is_empty():
		return
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		_state["winner"] = null                       # duel arena: never latch a winner
		_state["controlled"] = {}
		for pid in _peers:
			if not _peer_fid.has(pid):
				continue
			_intent_age[pid] = int(_intent_age.get(pid, 0)) + 1
			var mv = _move.get(pid, {"mx": 0.0, "my": 0.0})
			var mx: float = mv["mx"]
			var my: float = mv["my"]
			if _intent_age[pid] > STALE_INTENT_TICKS:  # client went silent → stop drifting
				mx = 0.0
				my = 0.0
			# fresh intent dict each tick (never alias _move) — the seam consumes .ability
			_state["controlled"][_peer_fid[pid]] = {"mx": mx, "my": my, "ability": _pending_ability.get(pid, "")}
			_pending_ability[pid] = ""                 # one-shot, consumed
		Sim.sim_tick(_state, SIM_DT)
		_tick_respawns(SIM_DT)
		_acc -= SIM_DT
		steps += 1
	if steps == 5:
		_acc = 0.0
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

# Reset a dead fighter to a fresh state at its ORIGINAL spawn point (stored at creation).
func _revive(f) -> void:
	if f == null:
		return
	var fresh := GameData.create_fighter(f["classId"], f["team"], f["slot"], Rng.new(MATCH_SEED + _fseq), DUEL_TEAM_SIZE)
	_fseq += 1
	for k in fresh:
		f[k] = fresh[k]
	var sp = _spawn_pos.get(f["id"], Vector2(f["x"], f["y"]))
	f["x"] = sp.x
	f["y"] = sp.y

func _find(id):
	for f in _state["fighters"]:
		if f["id"] == id:
			return f
	return null

# ---- snapshots (server → clients) ----
func _broadcast() -> void:
	var snap := _snapshot()
	if net != null and multiplayer.has_multiplayer_peer():
		net.receive_snapshot.rpc(snap)         # to all remote peers
	if local_client != null:
		local_client.receive_snapshot(snap)    # host renders directly (same process)
	_state["events"].clear()
	_snap_count += 1
	if _snap_count % 90 == 0:
		var pos := []
		for f in _state["fighters"]:
			pos.append("%s@(%d,%d)hp%d" % [f["id"], int(f["x"]), int(f["y"]), int(round(f["hp"]))])
		print("[server] t=%.1f snaps=%d  %s" % [_state["t"], _snap_count, pos])

# A compact, render-only view (only the fields the client renderer reads).
func _snapshot() -> Dictionary:
	var fs := []
	for f in _state["fighters"]:
		fs.append({
			"id": f["id"], "classId": f["classId"], "team": f["team"],
			"x": f["x"], "y": f["y"], "hp": f["hp"], "maxHP": f["maxHP"],
			"alive": f["alive"], "flash": f["flash"], "cds": f["cds"].duplicate(),
		})
	var ps := []
	for p in _state["projectiles"]:
		ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0)})
	return {"fighters": fs, "projectiles": ps, "events": _state["events"].duplicate(true), "t": _state["t"]}
