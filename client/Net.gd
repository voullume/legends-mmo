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

# loot drop notification (server → the looting client)
@rpc("authority", "call_remote", "reliable")
func recv_loot(item: String, rarity: String, slot: String, amt: int, stat: String) -> void:
	if client != null:
		client.recv_loot(item, rarity, slot, amt, stat)

# equip/unequip an item (client → server); server pushes back a refresh
@rpc("any_peer", "call_remote", "reliable")
func equip(item_id: String, slot: String) -> void:
	if server != null:
		server.equip(multiplayer.get_remote_sender_id(), item_id, slot)

@rpc("authority", "call_remote", "reliable")
func recv_inventory_changed() -> void:
	if client != null:
		client.recv_inventory_changed()

# admin tool: one gated command channel (the server re-checks the admin flag) + the admin notice
@rpc("any_peer", "call_remote", "reliable")
func admin_cmd(cmd: String, args: Dictionary) -> void:
	if server != null:
		server.admin_cmd(multiplayer.get_remote_sender_id(), cmd, args)

@rpc("authority", "call_remote", "reliable")
func recv_admin(on: bool) -> void:
	if client != null:
		client.recv_admin(on)

# ---- parties (client → server) ----
@rpc("any_peer", "call_remote", "reliable")
func party_invite(target_fid: String) -> void:
	if server != null:
		server.party_invite(multiplayer.get_remote_sender_id(), target_fid)

@rpc("any_peer", "call_remote", "reliable")
func party_accept(inviter_fid: String) -> void:
	if server != null:
		server.party_accept(multiplayer.get_remote_sender_id(), inviter_fid)

@rpc("any_peer", "call_remote", "reliable")
func party_decline() -> void:
	if server != null:
		server.party_decline(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable")
func party_leave() -> void:
	if server != null:
		server.party_leave(multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "reliable")
func recv_party_invite(inviter_name: String, inviter_fid: String) -> void:
	if client != null:
		client.recv_party_invite(inviter_name, inviter_fid)

# ---- shop (client → server; server re-validates credits/ownership/location) ----
@rpc("any_peer", "call_remote", "reliable")
func shop_buy(slot: String, rarity: String) -> void:
	if server != null:
		server.shop_buy(multiplayer.get_remote_sender_id(), slot, rarity)

@rpc("any_peer", "call_remote", "reliable")
func shop_roll(rarity: String) -> void:
	if server != null:
		server.shop_roll(multiplayer.get_remote_sender_id(), rarity)

@rpc("any_peer", "call_remote", "reliable")
func shop_sell(item_id: String) -> void:
	if server != null:
		server.shop_sell(multiplayer.get_remote_sender_id(), item_id)

# bulk sell (client → server; server re-validates ownership/location, skips equipped/locked, dedups)
@rpc("any_peer", "call_remote", "reliable")
func shop_sell_many(item_ids: Array) -> void:
	if server != null:
		server.shop_sell_many(multiplayer.get_remote_sender_id(), item_ids)

# toggle an item's persistent locked (protected-from-sell) flag
@rpc("any_peer", "call_remote", "reliable")
func inv_set_locked(item_id: String, locked: bool) -> void:
	if server != null:
		server.inv_set_locked(multiplayer.get_remote_sender_id(), item_id, locked)

# Phase 4: bulk salvage gear → scrap; upgrade one item a level (server re-validates location/cost/ownership)
@rpc("any_peer", "call_remote", "reliable")
func salvage_many(item_ids: Array) -> void:
	if server != null:
		server.salvage_many(multiplayer.get_remote_sender_id(), item_ids)

@rpc("any_peer", "call_remote", "reliable")
func forge_upgrade(item_id: String) -> void:
	if server != null:
		server.forge_upgrade(multiplayer.get_remote_sender_id(), item_id)

@rpc("authority", "call_remote", "reliable")
func recv_shop_info(info: Dictionary) -> void:
	if client != null:
		client.recv_shop_info(info)

# ---- quests (client → server: accept/turn-in; server → client: state + progress) ----
@rpc("any_peer", "call_remote", "reliable")
func quest_action(action: String, quest_id: String) -> void:
	if server != null:
		server.quest_action(multiplayer.get_remote_sender_id(), action, quest_id)

@rpc("authority", "call_remote", "reliable")
func recv_quest_state(states: Dictionary) -> void:
	if client != null:
		client.recv_quest_state(states)

@rpc("authority", "call_remote", "reliable")
func recv_quest_update(quest_id: String, progress: int, completed: bool) -> void:
	if client != null:
		client.recv_quest_update(quest_id, progress, completed)

# ---- server → client (only the authority may call these) ----
@rpc("authority", "call_remote", "unreliable_ordered")
func receive_snapshot(snap: Dictionary) -> void:
	if client != null:
		client.receive_snapshot(snap)

@rpc("authority", "call_remote", "reliable")
func assign_fighter(fid: String) -> void:
	if client != null:
		client.assign_fighter(fid)
