extends Node
## AUTHORITATIVE SERVER (skeleton — fill in during Phase 2+).
##
## Owns the world state and the combat tick. Reuse the deterministic engine in shared/:
##   - shared/GameData.gd : classes, abilities, stats, venues (source of truth)
##   - shared/Sim.gd      : create_match() / sim_tick(state, dt) — runs headless already
## On a real server you'll likely run a continuous world tick (not match-based) but the same
## Combat/Abilities/AI modules resolve actions authoritatively.
##
## Networking: Godot high-level multiplayer (ENetMultiplayerPeer.create_server). Clients are
## peers with NO authority — they send intents; the server validates + broadcasts snapshots.
## Persistence: Supabase (accounts, characters, inventory, progression).

const GameData := preload("res://shared/GameData.gd")
const Sim := preload("res://shared/Sim.gd")

const PORT := 7777

func _ready() -> void:
	print("[server] ready. Classes available: ", GameData.CLASSES.size(), " | venues: ", GameData.MAP_IDS)
	# TODO Phase 2:
	#   var peer := ENetMultiplayerPeer.new(); peer.create_server(PORT)
	#   multiplayer.multiplayer_peer = peer
	#   multiplayer.peer_connected.connect(_on_peer_connected)
	#   then run an authoritative world tick and broadcast state.

func _on_peer_connected(_id: int) -> void:
	pass  # TODO: spawn the player's character (loaded from Supabase) into the world.
