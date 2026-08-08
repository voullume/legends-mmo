extends "res://client/Client.gd"
## Dev-only (Main's --capture mode): the offline art-pass renderer. Boots the full render stack
## (_build_world/_build_hud) but SKIPS the practice-sandbox sim/player/bots — Main injects a
## synthetic snapshot state and drives _render_world manually, so shots show ONLY the zone.
func _enter_mode() -> void:
	pass
