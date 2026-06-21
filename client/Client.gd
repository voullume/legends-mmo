extends Node
## CLIENT (skeleton). Input + rendering.
##
## PHASE 1 GOAL: spawn ONE local, player-controlled fighter in a small world — no networking.
## Reuse from the prototype (../legends-arena/scripts/Arena.gd is the reference renderer):
##   - the character kit: load models/meshy/<sport>_rigged.glb + merge clips/ onto its
##     AnimationPlayer (idle/run/attack/throw/kick/hit/death/cast)
##   - animation driving, impact/skill FX, orbit/follow camera
## Class + ability definitions live in shared/GameData.gd.
##
## Later phases: connect to the server (ENetMultiplayerPeer.create_client), send input,
## render server snapshots; Supabase login + character select before entering the world.

const GameData := preload("res://shared/GameData.gd")

func _ready() -> void:
	print("[client] ready. TODO Phase 1: world + camera + a player-controlled character.")
	# Suggested first build:
	#   1. a ground/world node + light + camera
	#   2. add_child(preload("res://client/Player.gd").new()) with a chosen class_id
	#   3. wire input -> movement + ability animations + FX
