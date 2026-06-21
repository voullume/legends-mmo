extends Node
## NETWORK BRIDGE (Phase 2). A single node placed at the SAME tree path (/root/Main/Net) on
## the server and every client, so Godot's high-level multiplayer can route RPCs by node path.
## It just forwards: client→server intents/class, and server→client snapshots/assignment.
##
##   client  --submit_intent / set_class-->  server
##   server  --receive_snapshot / assign_fighter-->  client

var server: Node = null    # set on the server/host instance
var client: Node = null    # set on a remote-client instance

# ---- client → server (any peer may call these on the authority) ----
# movement: high-rate, latest-wins, OK to drop a packet
@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_intent(mv: Dictionary) -> void:
	if server != null:
		server.submit_intent(multiplayer.get_remote_sender_id(), mv)

# ability press: reliable + sequence-de-duplicated so a press is never lost or double-fired
@rpc("any_peer", "call_remote", "reliable")
func submit_ability(key: String, seq: int) -> void:
	if server != null:
		server.submit_ability(multiplayer.get_remote_sender_id(), key, seq)

@rpc("any_peer", "call_remote", "reliable")
func authenticate(access_token: String) -> void:
	if server != null:
		server.authenticate(multiplayer.get_remote_sender_id(), access_token)

# client re-issues a fresh access token periodically (refresh token never leaves the client)
@rpc("any_peer", "call_remote", "reliable")
func reauth(access_token: String) -> void:
	if server != null:
		server.reauth(multiplayer.get_remote_sender_id(), access_token)

# zone chat: client → server, server → all clients
@rpc("any_peer", "call_remote", "reliable")
func send_chat(text: String) -> void:
	if server != null:
		server.chat(multiplayer.get_remote_sender_id(), text)

@rpc("authority", "call_remote", "reliable")
func recv_chat(sender: String, text: String) -> void:
	if client != null:
		client.recv_chat(sender, text)

# ---- server → client (only the authority may call these) ----
@rpc("authority", "call_remote", "unreliable_ordered")
func receive_snapshot(snap: Dictionary) -> void:
	if client != null:
		client.receive_snapshot(snap)

@rpc("authority", "call_remote", "reliable")
func assign_fighter(fid: String) -> void:
	if client != null:
		client.assign_fighter(fid)
