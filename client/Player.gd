extends Node
## PLAYER INPUT CONTROLLER (Phase 1 — the human driver for one fighter).
##
## Produces an `intent` Dictionary that the shared Sim's controlled-fighter seam consumes
## (see shared/Sim.gd::_player_step). It does NOT render or own a body — the Client renders
## every fighter uniformly from sim state; this node only translates input → intent.
##
##   movement : WASD, camera-relative (Client passes the live camera yaw to poll()).
##   abilities: keys 1..5 = the class's abilities in GameData order (1=basic … 5=ult);
##              left mouse = the basic (ability 1).
##
## Phase 2 swaps this driver for network input feeding the same intent shape server-side.

const GameData := preload("res://shared/GameData.gd")

var class_id: String = "striker"
# Shared by reference with state["controlled"][fighter_id]; the Sim reads & consumes it.
var intent := {"mx": 0.0, "my": 0.0, "ability": ""}

func ability_keys() -> Array:
	var ks := []
	for ab in GameData.CLASSES[class_id]["abilities"]:
		ks.append(ab["key"])
	return ks

# Called by the Client each frame (before the sim tick) with the current camera yaw,
# so input maps to where the player is looking.
func poll(cam_yaw: float) -> void:
	var sx := 0.0
	var sy := 0.0
	if Input.is_physical_key_pressed(KEY_W): sy += 1.0
	if Input.is_physical_key_pressed(KEY_S): sy -= 1.0
	if Input.is_physical_key_pressed(KEY_D): sx += 1.0
	if Input.is_physical_key_pressed(KEY_A): sx -= 1.0
	# camera-relative basis on the ground plane, expressed in sim space (sim x = world X,
	# sim y = world Z). Derived from the orbit camera's look_at basis.
	var fwd := Vector2(-sin(cam_yaw), -cos(cam_yaw))   # W = away from camera
	var right := Vector2(cos(cam_yaw), -sin(cam_yaw))  # D = camera-right
	var m := fwd * sy + right * sx
	if m.length() > 1.0:
		m = m.normalized()
	intent["mx"] = m.x
	intent["my"] = m.y

# Ability presses are event-driven (queued, consumed by the next tick).
func _unhandled_input(e: InputEvent) -> void:
	var keys := ability_keys()
	if e is InputEventKey and e.pressed and not e.echo:
		var idx := -1
		match e.physical_keycode:
			KEY_1: idx = 0
			KEY_2: idx = 1
			KEY_3: idx = 2
			KEY_4: idx = 3
			KEY_5: idx = 4
		if idx >= 0 and idx < keys.size():
			intent["ability"] = keys[idx]
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		if keys.size() > 0:
			intent["ability"] = keys[0]
