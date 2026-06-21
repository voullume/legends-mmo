extends Node
## Entry point. Boots as a dedicated server with `--server`, otherwise as a client.
##
## Architecture (see HANDOFF.md): server-authoritative. The server owns the world + combat
## (reuse shared/Sim.gd — it's deterministic and already runs headless). Clients send input
## and render snapshots. Persistence via Supabase.
##
## CURRENT FOCUS = Phase 1: a single, local, player-controlled character (no networking yet),
## reusing the existing classes/abilities (shared/GameData.gd) + Meshy characters/animations.

func _ready() -> void:
	if "--server" in OS.get_cmdline_args():
		print("[boot] starting DEDICATED SERVER")
		add_child(preload("res://server/Server.gd").new())
	else:
		print("[boot] starting CLIENT")
		add_child(preload("res://client/Client.gd").new())
