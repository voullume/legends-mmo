extends "res://client/Client.gd"
## NETWORKED CLIENT (Phase 2). Extends the Phase-1 renderer and reuses every rendering helper;
## the only difference is WHERE the world comes from: instead of ticking the sim locally, it
## fills _state from server snapshots and sends its input to the server's controlled seam.
##
## Two transports, identical rendering:
##   ONLINE — a remote client: intents/snapshots via the Net RPC bridge.
##   HOST   — the player who is also hosting: talks to the in-process Server directly.

const REAUTH_INTERVAL := 1500.0   # re-issue a fresh access token every 25 min (< ~1h TTL)
const DESPAWN_GRACE := 3.0        # keep an out-of-interest node hidden this long before freeing

var net: Node = null         # RPC bridge
var server = null            # in-process server (unused in the shared zone)
# `supa` (the live Supabase session, refreshed locally) is inherited from Client.
var access_token := ""       # initial token sent on connect to identify our account
var autowalk := false        # debug: send a constant move intent (headless netcode test)
var _connected := false
var _aseq := 0               # monotonic ability sequence id (server de-dupes)
var _reauth_t := 0.0
var _absent := {}            # fighter id → seconds out of interest range (despawn hysteresis)
var _net_msg := ""           # connection/disconnection banner for the HUD

# Replaces the LOCAL sandbox setup: no local match — wait for the server to assign a fighter.
func _enter_mode() -> void:
	Engine.max_fps = 60
	_player = PlayerCtl.new()
	add_child(_player)
	_player_id = ""              # set by assign_fighter()
	print("[netclient] ready — awaiting server fighter assignment")

# input runs at the fixed physics rate (bounded), independent of render fps
var _aw_t := 0
func _physics_process(_delta: float) -> void:
	if _player == null or _player_id == "":
		return
	if autowalk:
		_player.intent["mx"] = 1.0
		_player.intent["my"] = 0.0
		_aw_t += 1
		if _aw_t % 15 == 0:                          # also fire the basic to test networked combat
			var ks: Array = _player.ability_keys()
			if ks.size() > 0:
				_player.intent["ability"] = ks[0]
	else:
		_player.poll(_yaw)
	_send_movement()                                 # unreliable, latest-wins
	if _player.intent["ability"] != "":
		_send_ability(_player.intent["ability"])     # reliable, de-duplicated
		_player.intent["ability"] = ""

func _send_movement() -> void:
	var mv := {"mx": _player.intent["mx"], "my": _player.intent["my"]}
	if server != null:
		server.submit_intent_local(1, mv)
	elif net != null and _connected:
		net.submit_intent.rpc_id(1, mv)

func _send_ability(key: String) -> void:
	_aseq += 1
	if server != null:
		server.submit_ability_local(1, key, _aseq)
	elif net != null and _connected:
		net.submit_ability.rpc_id(1, key, _aseq)

# render only — the server owns the sim
func _process(delta: float) -> void:
	if supa != null and net != null and _connected:
		_reauth_t += delta
		if _reauth_t >= REAUTH_INTERVAL:
			_reauth_t = 0.0
			_do_reauth()
	if _state.is_empty():
		_update_hud()          # still show the connecting/error banner before any snapshot
		return
	_sync_nodes_to_state()
	_render_world(delta)

# ---- transport callbacks ----
func _on_connected() -> void:
	_connected = true
	_net_msg = ""
	print("[netclient] connected — authenticating to the zone")
	if net != null:
		net.authenticate.rpc_id(1, access_token)

# keep the server's access token fresh without ever sending the refresh token over the wire
func _do_reauth() -> void:
	if supa != null and await supa.refresh_session() and net != null:
		net.reauth.rpc_id(1, supa.access_token)

# shown on the HUD when the connection fails or the server goes away
func net_error(msg: String) -> void:
	_net_msg = msg
	push_warning("[netclient] " + msg)

func receive_snapshot(snap: Dictionary) -> void:
	_state = snap
	if _player != null and _player_id != "":
		var pf = _find_fighter(_player_id)
		if pf != null and _player.class_id != pf["classId"]:
			_player.class_id = pf["classId"]
	_handle_events()             # spawn damage-number / hit FX from this snapshot's events

func assign_fighter(fid: String) -> void:
	_player_id = fid
	print("[netclient] assigned fighter ", fid)

# spawn render nodes for new fighters, free nodes for ones that left, revive on respawn
func _sync_nodes_to_state() -> void:
	var present := {}
	for f in _state["fighters"]:
		present[f["id"]] = true
		_absent.erase(f["id"])                  # back in interest range
		if not _nodes.has(f["id"]):
			_spawn(f)
		else:
			var n = _nodes[f["id"]]
			n["holder"].visible = true          # unhide if it was hidden during the despawn grace
			if f["alive"] and n["died"]:        # server respawned it → reset the death pose
				n["died"] = false
				n["busy"] = ""
				n["ui"].visible = true
				n["holder"].position = _world(f)   # snap to spawn (don't slide from the death spot)
				n["last"] = n["holder"].position
				n["vel"] = Vector2.ZERO
				if n["anim"] != null:
					_safe_play(n["anim"], n["anims"].get("idle", "idle"))
	# entities out of interest range: hide now, but keep the model around briefly so boundary
	# jitter doesn't re-instantiate the GLB on every crossing.
	var dt := get_process_delta_time()
	for id in _nodes.keys():
		if not present.has(id):
			var n = _nodes[id]
			n["holder"].visible = false
			_absent[id] = float(_absent.get(id, 0.0)) + dt
			if _absent[id] >= DESPAWN_GRACE:
				if is_instance_valid(n["holder"]):
					n["holder"].queue_free()
				_nodes.erase(id)
				_absent.erase(id)

# camera/zoom only — class-cycle/reset/pause are server decisions in multiplayer
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_dist = clampf(_dist / ZOOM_STEP, DIST_MIN, DIST_MAX)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_dist = clampf(_dist * ZOOM_STEP, DIST_MIN, DIST_MAX)
	elif e is InputEventMouseMotion and _dragging:
		_yaw -= e.relative.x * ORBIT_SENS
		_pitch = clampf(_pitch + e.relative.y * ORBIT_SENS, PITCH_MIN, PITCH_MAX)

func _update_hud() -> void:
	if _net_msg != "":
		_info.text = "[b]Legends MMO — Online[/b]\n[color=#ff7a7a]%s[/color]" % _net_msg
		_bar.text = ""
		return
	if _player_id == "" or _player == null or _state.is_empty():
		_info.text = "[b]Legends MMO — Online[/b]\n[color=#7f93a8]connecting…[/color]"
		_bar.text = ""
		return
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	var c: Dictionary = GameData.CLASSES[pf["classId"]]
	var alive_txt := "[color=#ff6b6b](respawning…)[/color]" if not pf["alive"] else ""
	var role := "HOST" if server != null else "CLIENT"
	_info.text = "[b]%s[/b]  [color=#9fb4c8]%s · %s[/color]   HP %d/%d %s   [color=#7fd4ff]ONLINE · %s[/color]\n[color=#7f93a8]WASD move · 1-5 abilities · LMB basic · RMB-drag camera · wheel zoom[/color]" % [
		c["name"], c["sport"], c["role"], int(round(pf["hp"])), int(pf["maxHP"]), alive_txt, role]
	var parts := []
	var keys: Array = _player.ability_keys()
	for i in keys.size():
		var ab = Sim._ability_by_key(c, keys[i])
		var cd: float = pf["cds"].get(keys[i], 0.0)
		var col := "#4dd4ff"
		if ab.get("ult", false): col = "#ffd24d"
		elif ab.get("basic", false): col = "#9fe8a0"
		var label: String = ab["name"]
		if cd > 0.05:
			label = "%s [color=#ff8a8a]%.1f[/color]" % [ab["name"], cd]
		parts.append("[color=%s][b]%d[/b][/color] %s" % [col, i + 1, label])
	_bar.text = "   ".join(parts)
