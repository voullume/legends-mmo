extends Node
## Entry point. Server-authoritative architecture (see HANDOFF.md).
##
## Boot modes (pass after `--`, e.g. `godot -- --host`):
##   (none)          Phase 1 LOCAL sandbox — single-player practice arena.
##   --server        Phase 2 DEDICATED server (headless authoritative host, no rendering).
##   --host          Phase 2 HOST — run the server AND play locally (listen server).
##   --connect [ip]  Phase 2 CLIENT — connect to a server (default 127.0.0.1).
##   --class <id>    class to play as in host/connect modes (default striker).
##
## The server owns the world + combat (shared/Sim.gd, deterministic); clients send input and
## render snapshots. The player's input flows through the SAME Sim "controlled" seam Phase 1
## used — only the transport (keyboard → network) changed.

const NetScript := preload("res://client/Net.gd")
const ServerScript := preload("res://server/Server.gd")
const ClientScript := preload("res://client/Client.gd")
const NetClientScript := preload("res://client/NetClient.gd")
const SERVER_PORT := 7777

func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--server" in args:
		print("[boot] DEDICATED SERVER")
		_make_server(false, args)
	elif "--host" in args:
		print("[boot] HOST (server + local player)")
		_make_server(true, args)
	elif "--connect" in args:
		var ip := _arg_value(args, "--connect", "127.0.0.1")
		print("[boot] ONLINE CLIENT → ", ip)
		_make_client(ip, args)
	else:
		print("[boot] LOCAL sandbox (Phase 1)")
		add_child(ClientScript.new())

func _make_server(host: bool, args: Array) -> void:
	var net := NetScript.new()
	net.name = "Net"
	add_child(net)
	var server := ServerScript.new()
	server.name = "Server"
	server.net = net
	net.server = server
	add_child(server)
	if host:
		var client := NetClientScript.new()
		client.name = "Client"
		client.server = server          # host feeds intent + reads snapshots in-process
		client.autowalk = "--autowalk" in args
		server.local_client = client
		add_child(client)
		server.start(_arg_value(args, "--class", "striker"))
	else:
		server.start()

func _make_client(ip: String, args: Array) -> void:
	var net := NetScript.new()
	net.name = "Net"
	add_child(net)
	var client := NetClientScript.new()
	client.name = "Client"
	client.net = net
	net.client = client
	client.want_class = _arg_value(args, "--class", "striker")
	client.autowalk = "--autowalk" in args
	add_child(client)
	Engine.max_fps = 60
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, SERVER_PORT)
	if err != OK:
		push_error("[boot] create_client(%s:%d) failed: %d" % [ip, SERVER_PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(client._on_connected)
	multiplayer.connection_failed.connect(func() -> void: client.net_error("Connection failed — is a server running? (godot -- --server)"))
	multiplayer.server_disconnected.connect(func() -> void: client.net_error("Server disconnected."))

func _arg_value(args: Array, key: String, def: String) -> String:
	var i := args.find(key)
	if i >= 0 and i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
		return args[i + 1]
	return def
