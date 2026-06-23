extends Node
## Entry point. Server-authoritative architecture (see HANDOFF.md).
##
## Boot modes (pass after `--`, e.g. `godot -- --online`):
##   (none)          ACCOUNT → single-player LOCAL world as your character (Phase 3).
##   --online [ip]   ACCOUNT → join the shared persistent ZONE (default 127.0.0.1).
##   --server        Dedicated shared ZONE server (headless authoritative host).
##   --practice      Phase 1 LOCAL sandbox — no account, free class cycling + bots.
##   --port <n>      bind/connect port (default 7777).
##   --dtls          encrypt the ENet transport (self-signed). Use it on BOTH server and clients
##                   for any internet-exposed host. (Not needed over a VPN like Tailscale.)
##
## The zone server owns the world + combat (shared/Sim.gd) and persistence; clients authenticate
## with their Supabase token, the server loads their account's character, and input flows through
## the same Sim "controlled" seam used since Phase 1.

const NetScript := preload("res://client/Net.gd")
const ServerScript := preload("res://server/Server.gd")
const ClientScript := preload("res://client/Client.gd")
const NetClientScript := preload("res://client/NetClient.gd")
const AccountScript := preload("res://client/Account.gd")
const SupaScript := preload("res://client/Supabase.gd")
const SERVER_PORT := 7777
const PUBLIC_HOST := "159.89.132.86"   # exported/distributed builds connect straight here (double-click → online, DTLS)

func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var port := int(_arg_value(args, "--port", str(SERVER_PORT)))
	var dtls := "--dtls" in args
	if "--server" in args:
		print("[boot] ZONE SERVER (port %d%s)" % [port, " · DTLS" if dtls else ""])
		_make_zone_server(port, dtls, _arg_value(args, "--bind", ""))
	elif "--online" in args:
		var ip := _arg_value(args, "--online", "127.0.0.1")
		print("[boot] ONLINE — account → shared zone @ %s:%d%s" % [ip, port, " · DTLS" if dtls else ""])
		var tok := _arg_value(args, "--token", "")
		if tok != "":                              # debug: skip the login UI, use a provided token
			var supa := SupaScript.new()
			supa.name = "Supa"
			add_child(supa)
			supa.access_token = tok
			supa.refresh_token = _arg_value(args, "--refresh", "")
			_enter_online(supa, {}, ip, port, dtls)
		else:
			var acct := AccountScript.new()
			acct.entered.connect(func(supa, character): _enter_online(supa, character, ip, port, dtls))
			add_child(acct)
	elif "--practice" in args:
		print("[boot] PRACTICE sandbox (local, no account)")
		add_child(ClientScript.new())
	elif PUBLIC_HOST != "" and not OS.has_feature("editor"):
		# a distributed/exported build (double-click, no args) goes straight to the live public server;
		# running from source/the editor still drops into the local single-player world below.
		print("[boot] PUBLIC build — account → live zone @ %s:%d · DTLS" % [PUBLIC_HOST, port])
		var acct := AccountScript.new()
		acct.entered.connect(func(supa, character): _enter_online(supa, character, PUBLIC_HOST, port, true))
		add_child(acct)
	else:
		print("[boot] ACCOUNT — login → local world")
		var acct := AccountScript.new()
		acct.entered.connect(_on_entered_local)
		add_child(acct)

# ---- Phase 4: dedicated shared zone ----
func _make_zone_server(port: int, dtls: bool, bind_ip := "") -> void:
	var net := NetScript.new()
	net.name = "Net"
	add_child(net)
	var supa := SupaScript.new()
	supa.name = "Supa"
	supa.service_key = OS.get_environment("SUPABASE_SERVICE_KEY")   # server-only; bypasses RLS for inventory writes
	if supa.service_key == "":
		print("[zone] ⚠ SUPABASE_SERVICE_KEY not set — loot/equip persistence will fail against the locked-down inventory table. See TESTING.md.")
	add_child(supa)
	var server := ServerScript.new()
	server.name = "Server"
	server.net = net
	server.supa = supa
	net.server = server
	add_child(server)
	server.start(port, dtls, bind_ip)

func _enter_online(supa, character, ip: String, port := SERVER_PORT, dtls := false) -> void:
	var net := NetScript.new()
	net.name = "Net"
	add_child(net)
	var client := NetClientScript.new()
	client.name = "Client"
	client.net = net
	net.client = client
	client.access_token = supa.access_token       # initial identity token sent to the zone
	client.supa = supa                            # kept for periodic reauth (refresh token stays local)
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	client.autowalk = "--autowalk" in args
	if supa.get_parent() != null:                 # move the live session out before freeing the UI
		supa.get_parent().remove_child(supa)
	for c in get_children():
		if c.get_script() == AccountScript:
			c.queue_free()
	add_child(client)
	client.add_child(supa)
	Engine.max_fps = 60
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		client.net_error("Could not start client (%d)" % err)
		return
	if dtls:                                       # encrypt the link (server self-signed; client encrypts, doesn't verify)
		var derr := peer.host.dtls_client_setup(ip, TLSOptions.client_unsafe())
		if derr != OK:
			client.net_error("DTLS setup failed (%d)" % derr)
			return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(client._on_connected)
	multiplayer.connection_failed.connect(func() -> void: client.net_error("Connection failed — is the zone server running? (godot -- --server)"))
	multiplayer.server_disconnected.connect(func() -> void: client.net_error("Disconnected from the zone."))

# ---- Phase 3: account → single-player local world ----
func _on_entered_local(supa, character) -> void:
	var client := ClientScript.new()
	client.class_locked = true
	client.locked_class = str(character.get("class", "striker"))
	client.char_id = str(character.get("id", ""))
	client.char_name = str(character.get("name", ""))
	if character.get("last_x") != null and character.get("last_y") != null:
		client.start_pos = Vector2(float(character["last_x"]), float(character["last_y"]))
		client.has_start_pos = true
	client.supa = supa
	if supa.get_parent() != null:
		supa.get_parent().remove_child(supa)
	for c in get_children():
		if c.get_script() == AccountScript:
			c.queue_free()
	add_child(client)
	client.add_child(supa)

func _arg_value(args: Array, key: String, def: String) -> String:
	var i := args.find(key)
	if i >= 0 and i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
		return args[i + 1]
	return def
