extends CharacterBody3D
## PLAYER-CONTROLLED FIGHTER (skeleton — the heart of Phase 1).
##
## Drive a Meshy character with real-time input: move with WASD/click, fire the class's
## abilities (from shared/GameData.gd) which play the matching animation + FX.
##
## Asset wiring (proven in the prototype):
##   - base model:  res://models/meshy/<sport>_rigged.glb  (sport from GameData.CLASSES[class_id].sport, lowercased)
##   - animations:  res://models/meshy/clips/<sport>_<clip>.res  -> merge into one AnimationPlayer
##     clips: idle, run, walk, attack, hit, death, throw, cast (+ kick for soccer)
##   - the Meshy rig hand bone is "RightHand" (note its ~0.02 internal scale — see HANDOFF.md)

const GameData := preload("res://shared/GameData.gd")

@export var class_id: String = "striker"
@export var move_speed: float = 6.0

var _anim: AnimationPlayer = null

func _ready() -> void:
	# TODO: instantiate the Meshy character for this class_id, merge its .res clips, play "idle".
	print("[player] class=", class_id, " sport=", GameData.CLASSES.get(class_id, {}).get("sport", "?"))

func _physics_process(_delta: float) -> void:
	# TODO Phase 1:
	#   - read movement input -> velocity -> move_and_slide(); face travel direction
	#   - play "run" while moving, "idle" when still
	#   - on ability input: resolve via shared/Abilities logic, play attack/throw/kick/cast, spawn FX
	pass
