extends Node
## CLIENT — Phase 1: a single, local, player-controlled fighter in a practice arena.
##
## Architecture: the shared deterministic engine (shared/Sim.gd) is authoritative and ticks
## the WHOLE world at 30 Hz. The player's fighter is driven through the Sim's controlled
## seam (Player.gd → intent → Sim._player_step); sparring bots run the ported team AI. The
## client only RENDERS sim state (character kit + animations + FX, ported from the prototype
## ~/legends-arena/scripts/Arena.gd) and feeds input. No win/lose — dead fighters respawn.
##
## Controls: WASD move (camera-relative) · 1-5 abilities (1=basic … 5=ult) · LMB basic
##           RMB-drag orbit camera · wheel zoom · C cycle class · R reset arena

const GameData := preload("res://shared/GameData.gd")
const Sim := preload("res://shared/Sim.gd")
const Geom := preload("res://shared/Geom.gd")
const World := preload("res://shared/World.gd")
const PlayerCtl := preload("res://client/Player.gd")

# --- world scale / look ---
const SCALE := 0.05                       # sim units → world units (960×540 → 48×27)
const MESHY_SCALE := 1.9
const MESHY_FLIP := false
const CHAR_Y := 0.0
# In-hand sport prop (the Batter's bat) attached to the Meshy "RightHand" bone, so it follows the swing.
const PROP_SCALE := 1.0                     # bump if the bat looks too big/small in hand
const MESHY_BAT_MUL := 95.0                 # the Meshy RightHand bone has a ~0.02 internal scale — counter it
const MESHY_PROP_ROT := Vector3(0, 0, 0)    # tweak if the bat sits at the wrong angle
const MESHY_PROP_OFS := Vector3(0, 0, 0)
const SIM_DT := 1.0 / 30.0
const BAR_W := 2.2
const BAR_H := 0.26
const UI_Y := 3.6
const DMG_NUM_Y := 4.4
const HIT_Y := 1.7
const SHAKE_MAX := 1.1                      # camera screen-shake cap (world units of jitter)
const SHAKE_DECAY := 5.0                     # how fast a shake settles
const RESPAWN_DELAY := 3.0
const MAP_ID := "stadium"                 # open field; obstacle rendering supports any venue

# --- camera (3rd-person follow + orbit) ---
const FOV := 60.0
const ORBIT_SENS := 0.006
const ZOOM_STEP := 1.12
const DIST_MIN := 10.0
const DIST_MAX := 55.0
const PITCH_MIN := 0.62        # keep it overhead — no dropping to a flat free-cam angle
const PITCH_MAX := 1.45        # up to near top-down

const TEAM_COLOR := [Color(0.26, 0.74, 0.98), Color(0.98, 0.46, 0.52)]
const PLAYABLE := ["striker", "batter", "spiker", "linebacker", "pitcher", "quarterback", "setter", "goalkeeper"]
const BOTS := ["linebacker", "setter"]

# Meshy clip-name map (sport → renderer anim roles). Soccer throws by kicking.
# Per-ability clip overrides (classId → {ability key → clip name}), beyond the by-type default.
const ANIM_OVERRIDE := {"goalkeeper": {"distribution": "throw"}}
const HIT_SPEED := 3.0          # play the 1.67s hit clip ~3x → a quick ~0.55s flinch, not a long lurch
const HIT_FLINCH_CD := 1.2      # min seconds between flinches, so a flurry of hits isn't constant flinching
# Action clips are authored 2.7–4.3s — far longer than abilities actually fire. Play each one to ~a
# fraction of its cooldown (clamped) so frequent basics read snappy and long-cooldown ults read heavier.
const CAST_DUR_FRAC := 0.6
const CAST_DUR_MIN := 0.55      # quick floor for frequent basics
const CAST_DUR_MAX := 1.0       # ceiling so even long-cooldown abilities (power swings/ults) stay punchy, not slow

var _state: Dictionary
var _meshy := {}
var _nodes := {}                          # fighter id → render node dict
var _spawn_pos := {}                      # fighter id → Vector2 (sim) spawn for respawn
var _respawn := {}                        # fighter id → seconds until revive
var _player: Node
var _player_id := "0-0"
var _player_class_idx := 0

# Phase 3 — account-bound character: class is locked (no cycling) and position persists.
var class_locked := false
var locked_class := ""
var start_pos := Vector2.ZERO
var has_start_pos := false
var supa = null
var char_id := ""
var char_name := ""
var _save_t := 0.0
var _save_note := ""
var _quitting := false

var _world_root: Node3D
var _fx_root: Node3D
var _portal_root: Node3D = null            # portal pad visuals (rebuilt when the world's portals change)
var _portals_sig := ""
var _ground: MeshInstance3D                # floor planes, resized when the arena (map) size changes
var _field: MeshInstance3D
var _arena_sig := ""
var _proj_pool := []
var _fx_active := []                       # {node, t, life, vel}
var _shake := 0.0                          # current camera screen-shake magnitude (decays each frame)
var _num_pool := []
var _pop_pool := []

var _cam: Camera3D
var _focus := Vector3.ZERO
var _yaw := 0.0
var _pitch := 1.12             # high, MMO-style overhead angle by default
var _dist := 26.0
var _dragging := false
var _rmb_moved := false       # distinguishes a right-CLICK (invite) from a right-drag (camera)
var _acc := 0.0
var _bots_frozen := true        # start paused so the player can feel out controls unrushed

var _hud: CanvasLayer
var _info: RichTextLabel
var _bar: RichTextLabel
var _hotbar: HBoxContainer                 # MMO-style skill bar (a slot per ability)
var _slots := []                           # [{root, cd, cs}] per ability
var _hotbar_class := ""
var _tooltip: PanelContainer
var _tt_label: RichTextLabel

func _ready() -> void:
	_load_meshy()
	_build_world()
	_build_hud()
	_enter_mode()

# Phase-1 LOCAL sandbox. NetClient (Phase 2) overrides this to connect to a server instead,
# reusing every rendering helper below.
func _enter_mode() -> void:
	if locked_class != "":
		# Phase 3: enter as the account's character (class fixed, position restored)
		if not GameData.CLASSES.has(locked_class):
			push_warning("[client] unknown class '%s' — falling back to default" % locked_class)
			locked_class = PLAYABLE[0]
		_player_class_idx = max(0, PLAYABLE.find(locked_class))
		_setup_match(locked_class)
		if has_start_pos:
			_place_player_at(start_pos)
		if class_locked:
			get_tree().set_auto_accept_quit(false)   # save on window close
		print("[client] entered as %s the %s (class locked)" % [char_name, locked_class])
	else:
		_setup_match(PLAYABLE[_player_class_idx])
		print("[client] Phase 1 arena ready — WASD move, 1-5 abilities, C cycle class, R reset.")

# ============================================================ assets / characters
func _load_meshy() -> void:
	var configs := {
		"Baseball": {"prefix": "baseball", "ranged": "throw"},
		"Football": {"prefix": "football", "ranged": "throw"},
		"Volleyball": {"prefix": "volleyball", "ranged": "throw"},
		"Soccer": {"prefix": "soccer", "ranged": "kick"},
	}
	for sport in configs:
		var prefix: String = configs[sport]["prefix"]
		var base_path := "res://models/meshy/%s_rigged.glb" % prefix
		if not ResourceLoader.exists(base_path):
			continue
		var entry := {"base": load(base_path), "clips": {},
			"anims": {"idle": "idle", "run": "run", "melee": "attack", "ranged": configs[sport]["ranged"],
				"hit": "hit", "death": "death", "cast": "cast"}}
		for cn in ["idle", "run", "walk", "attack", "hit", "death", "throw", "kick", "cast"]:
			var p := "res://models/meshy/clips/%s_%s.res" % [prefix, cn]
			if ResourceLoader.exists(p):
				var clip: Animation = load(p)
				if cn in ["idle", "run", "walk"]:        # cyclic clips shipped as LOOP_NONE → make them loop
					clip.loop_mode = Animation.LOOP_LINEAR  # smooth cycle (no freeze/pop at the end of each stride)
				else:                                    # action clips bake big root (Hips) drift → pin it in place
					_strip_root_motion(clip, cn != "death")   # keep Y for the death collapse; flatten it everywhere else
				_strip_hips_scale(clip)              # idle bakes a 1.176 Hips scale → strip it so size stays constant
				entry["clips"][cn] = clip
		if entry["clips"].has("idle") and entry["clips"].has("attack"):
			_meshy[sport] = entry
	print("[client] Meshy characters loaded: ", _meshy.keys(), " (", _meshy.size(), "/4 sports)")

func _find_anim(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

# Returns {model, anim, anims, scale} for a fighter's sport (Meshy, or capsule fallback).
func _make_character(f: Dictionary) -> Dictionary:
	var sport: String = GameData.CLASSES[f["classId"]]["sport"]
	if _meshy.has(sport):
		var entry = _meshy[sport]
		var inst = entry["base"].instantiate()
		var ap := _find_anim(inst)
		if ap != null:
			var lib := ap.get_animation_library("")
			if lib == null:
				lib = AnimationLibrary.new()
				ap.add_animation_library("", lib)
			for cn in entry["clips"]:
				if not lib.has_animation(cn):
					lib.add_animation(cn, entry["clips"][cn])
		return {"model": inst, "anim": ap, "anims": entry["anims"], "scale": MESHY_SCALE}
	# fallback: a colored capsule (assets missing) so the arena still runs
	var cap := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.8
	cap.mesh = cm
	cap.position.y = 0.9
	cap.material_override = _mat(GameData.CLASSES[f["classId"]].get("color", "#cccccc"))
	return {"model": cap, "anim": null, "anims": {}, "scale": 1.0}

# ============================================================ world / camera
func _mat(col) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = (Color(col) if col is String else col)
	return m

# A held sport prop for the class, or null. The Batter carries a bat (a tapered cylinder); _spawn pins
# it to the RightHand bone so it tracks the swing. (Balls are intentionally omitted — a ball stuck in
# the hand reads oddly during a throw, where the projectile is its own FX.)
func _class_prop(class_id: String) -> Node3D:
	if class_id != "batter":
		return null
	var root := Node3D.new()
	root.scale = Vector3(PROP_SCALE, PROP_SCALE, PROP_SCALE)
	var bat := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.055
	cm.bottom_radius = 0.02
	cm.height = 0.82
	bat.mesh = cm
	bat.material_override = _mat(Color(0.66, 0.45, 0.26))
	bat.position = Vector3(0, 0.40, 0)
	root.add_child(bat)
	return root

func _quad(w: float, h: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	var mt := StandardMaterial3D.new()
	mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mt.albedo_color = col
	mi.material_override = mt
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _aw() -> float:
	return float(_state.get("arenaW", GameData.ARENA_W))

func _ah() -> float:
	return float(_state.get("arenaH", GameData.ARENA_H))

func _world(f: Dictionary) -> Vector3:
	return Vector3((f["x"] - _aw() / 2.0) * SCALE, 0.0, (f["y"] - _ah() / 2.0) * SCALE)

# Resize the floor when the arena (map) size changes — i.e. when you cross into the other world.
func _resize_arena() -> void:
	var sig := "%dx%d" % [int(_aw()), int(_ah())]
	if sig == _arena_sig:
		return
	_arena_sig = sig
	if _ground != null and _ground.mesh is PlaneMesh:
		(_ground.mesh as PlaneMesh).size = Vector2(_aw() * SCALE + 24.0, _ah() * SCALE + 24.0)
	if _field != null and _field.mesh is PlaneMesh:
		(_field.mesh as PlaneMesh).size = Vector2(_aw() * SCALE, _ah() * SCALE)

func _build_world() -> void:
	_world_root = Node3D.new()
	add_child(_world_root)
	_fx_root = Node3D.new()
	add_child(_fx_root)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -42, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.07, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.52, 0.64)
	env.ambient_light_energy = 0.75
	env.fog_enabled = true
	env.fog_density = 0.004
	env.fog_light_color = Color(0.06, 0.08, 0.12)
	we.environment = env
	add_child(we)

	# ground + field
	var ground := MeshInstance3D.new()
	var gp := PlaneMesh.new()
	gp.size = Vector2(GameData.ARENA_W * SCALE + 24.0, GameData.ARENA_H * SCALE + 24.0)
	ground.mesh = gp
	ground.material_override = _mat(Color(0.10, 0.13, 0.10))
	add_child(ground)
	_ground = ground
	var field := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(GameData.ARENA_W * SCALE, GameData.ARENA_H * SCALE)
	field.mesh = fp
	field.position.y = 0.01
	field.material_override = _mat(Color(0.16, 0.30, 0.18))
	add_child(field)
	_field = field

	# obstacles (rigs) for the chosen map — cylinders
	for o in GameData.MAPS[MAP_ID]["obstacles"]:
		var rig := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = o["r"] * SCALE
		cyl.bottom_radius = o["r"] * SCALE
		cyl.height = 2.2
		rig.mesh = cyl
		rig.position = Vector3((o["x"] - GameData.ARENA_W / 2.0) * SCALE, 1.1, (o["y"] - GameData.ARENA_H / 2.0) * SCALE)
		rig.material_override = _mat(Color(0.30, 0.32, 0.38))
		add_child(rig)

	_cam = Camera3D.new()
	_cam.fov = FOV
	add_child(_cam)
	_update_cam()

func _update_cam() -> void:
	var dir := Vector3(cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw))
	_cam.position = _focus + dir * _dist
	if _shake > 0.001:                       # screen shake: jitter the camera, still aimed at the focus
		_cam.position += Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * (_shake * 2.0)
	_cam.look_at(_focus, Vector3.UP)

func _add_shake(amt: float) -> void:
	_shake = minf(SHAKE_MAX, _shake + amt)

# ============================================================ match setup
func _setup_match(player_class: String) -> void:
	_teardown()
	_state = Sim.create_match([player_class], BOTS.duplicate(), 20260620, MAP_ID)
	_state["botsFrozen"] = _bots_frozen
	for f in _state["fighters"]:
		_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])
		_spawn(f)
	# wire the player controller into the controlled seam (shared intent dict reference)
	_player = PlayerCtl.new()
	_player.class_id = player_class
	add_child(_player)
	_state["controlled"] = {_player_id: _player.intent}
	_focus = _world(_state["fighters"][0])

func _teardown() -> void:
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
		_player = null
	for id in _nodes:
		var n = _nodes[id]
		if is_instance_valid(n["holder"]):
			n["holder"].queue_free()
	_nodes.clear()
	_spawn_pos.clear()
	_respawn.clear()
	for p in _proj_pool:
		if is_instance_valid(p):
			p.queue_free()
	_proj_pool.clear()
	for fx in _fx_active:
		if is_instance_valid(fx["node"]):
			fx["node"].visible = false
			if fx["kind"] == "num":
				_num_pool.append(fx["node"])
			else:
				_pop_pool.append(fx["node"])   # re-pool in-flight FX so a mid-anim reset doesn't strand nodes
	_fx_active.clear()
	_acc = 0.0

func _spawn(f: Dictionary) -> void:
	var holder := Node3D.new()
	_world_root.add_child(holder)
	holder.position = _world(f)

	var ring := MeshInstance3D.new()
	var rcyl := CylinderMesh.new()
	rcyl.top_radius = 1.25
	rcyl.bottom_radius = 1.25
	rcyl.height = 0.05
	ring.mesh = rcyl
	ring.position.y = 0.05
	var ring_col: Color = TEAM_COLOR[f["team"]]
	var lpf = _find_fighter(_player_id)
	if lpf != null and _hostile_pair(lpf, f):
		ring_col = Color(1.0, 0.4, 0.4)              # a hostile (non-party) player in a PvP zone reads red
	var rmat := _mat(ring_col)
	rmat.emission_enabled = true
	rmat.emission = ring_col
	rmat.emission_energy_multiplier = 0.5
	ring.material_override = rmat
	holder.add_child(ring)

	var kit := _make_character(f)
	var model = kit["model"]
	var msc: float = kit["scale"]
	model.scale = Vector3(msc, msc, msc)
	model.position.y = CHAR_Y
	holder.add_child(model)
	var ap = kit["anim"]
	if ap != null:
		ap.playback_default_blend_time = 0.12
		_safe_play(ap, kit["anims"].get("idle", "idle"))

	var prop := _class_prop(str(f["classId"]))   # held sport prop (the Batter's bat) on the hand bone
	if prop != null:
		var skel := _find_skeleton(model)
		if skel != null:
			var ba := BoneAttachment3D.new()
			skel.add_child(ba)
			ba.bone_name = "RightHand"
			prop.scale *= MESHY_BAT_MUL          # counter the hand bone's tiny internal scale
			prop.rotation_degrees = MESHY_PROP_ROT
			prop.position = MESHY_PROP_OFS
			ba.add_child(prop)

	var ui := Node3D.new()
	ui.position.y = UI_Y
	holder.add_child(ui)
	ui.add_child(_quad(BAR_W + 0.08, BAR_H + 0.08, Color(0, 0, 0, 0.6)))
	var fill := _quad(BAR_W, BAR_H, Color(0.3, 0.85, 0.4))
	fill.position.z = 0.01
	ui.add_child(fill)
	var label := Label3D.new()                # level / tier nameplate (mobs, and players online)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0016
	label.font_size = 56
	label.outline_size = 16
	label.outline_modulate = Color(0, 0, 0, 0.9)
	label.position.y = BAR_H + 0.32
	ui.add_child(label)

	_nodes[f["id"]] = {
		"holder": holder, "model": model, "anim": ap, "anims": kit["anims"], "mscale": msc,
		"ui": ui, "fill": fill, "label": label, "last": holder.position, "vel": Vector2.ZERO,
		"pcds": {}, "busy": "", "atk_clip": "", "atk_speed": 1.0, "died": false, "hit_cd": 0.0, "pflash": 0.0,
	}

# ============================================================ main loop
func _process(delta: float) -> void:
	if _state.is_empty():
		return
	# 1) input → intent (before the tick, zero-lag)
	if _player != null:
		_player.poll(_yaw)

	# 2) fixed-step authoritative sim. Practice arena: never let a winner latch.
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		_state["winner"] = null
		Sim.sim_tick(_state, SIM_DT)
		_acc -= SIM_DT
		steps += 1
		_handle_events()
		_tick_respawns(SIM_DT)
	if steps == 5:
		_acc = 0.0

	_render_world(delta)

	# Phase 3: persist position to the account's character every 10s
	if supa != null and char_id != "" and not _quitting:
		_save_t += delta
		if _save_t >= 10.0:
			_save_t = 0.0
			_save_progress()

# Render the current _state — shared by the LOCAL sandbox and the networked client (which
# fills _state from server snapshots instead of ticking the sim locally).
func _render_world(delta: float) -> void:
	_sync_projectiles()
	_update_fx(delta)
	var pf = _find_fighter(_player_id)
	if pf != null:
		var tf := _world(pf)
		tf.y = 1.4
		_focus = _focus.lerp(tf, clampf(delta * 5.0, 0.0, 1.0))
	_update_cam()

	for f in _state["fighters"]:
		var n = _nodes.get(f["id"])
		if n == null:
			continue
		_detect_cast(n, f)
		n["hit_cd"] = maxf(0.0, n["hit_cd"] - delta)
		if not f["alive"]:
			_drive_anim(n, f, false)
			n["pflash"] = f["flash"]
			continue
		var holder: Node3D = n["holder"]
		var target := _world(f)
		var tvel := Vector2(target.x - n["last"].x, target.z - n["last"].z)
		n["last"] = target
		n["vel"] = n["vel"].lerp(tvel, clampf(delta * 5.0, 0.0, 1.0))
		holder.position = holder.position.lerp(target, clampf(delta * 14.0, 0.0, 1.0))
		var moving: bool = n["vel"].length() > 0.0016
		# face heading while moving, else the nearest enemy
		var flip: float = PI if MESHY_FLIP else 0.0
		var model: Node3D = n["model"]   # scale is constant (set at spawn) — idle stands tall, run crouches, blended
		var tgt_yaw: float = model.rotation.y
		if moving:
			tgt_yaw = atan2(n["vel"].x, n["vel"].y) + flip
		else:
			var ed := _enemy_dir(f)
			if ed != Vector2.ZERO:
				tgt_yaw = atan2(ed.x, ed.y) + flip
		model.rotation.y = lerp_angle(model.rotation.y, tgt_yaw, clampf(delta * 9.0, 0.0, 1.0))
		_drive_anim(n, f, moving)
		_update_ui(n, f)
		n["pflash"] = f["flash"]

	_resize_arena()
	_render_portals()
	_update_hud()

# Draw the current world's portal pads (sent in the snapshot). Rebuilt only when they change
# (i.e. when you cross into the other world), so it's cheap.
func _render_portals() -> void:
	var portals: Array = _state.get("portals", [])
	var sig := JSON.stringify(portals)
	if sig == _portals_sig:
		return
	_portals_sig = sig
	if _portal_root != null:
		_portal_root.queue_free()
		_portal_root = null
	if portals.is_empty() or _world_root == null:
		return
	_portal_root = Node3D.new()
	_world_root.add_child(_portal_root)
	for p in portals:
		var pos := Vector3((float(p["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(p["y"]) - _ah() / 2.0) * SCALE)
		var pillar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = World.PORTAL_RADIUS * SCALE
		cyl.bottom_radius = World.PORTAL_RADIUS * SCALE
		cyl.height = 3.0
		pillar.mesh = cyl
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.35, 0.8, 1.0, 0.32)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.4, 0.85, 1.0)
		mat.emission_energy_multiplier = 1.6
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		pillar.material_override = mat
		pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pillar.position = pos + Vector3(0.0, 1.5, 0.0)
		_portal_root.add_child(pillar)
		var lbl := Label3D.new()
		lbl.text = str(p.get("label", "Portal"))
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.fixed_size = true
		lbl.pixel_size = 0.0016
		lbl.font_size = 52
		lbl.outline_size = 16
		lbl.outline_modulate = Color(0, 0, 0, 0.9)
		lbl.modulate = Color(0.65, 0.92, 1.0)
		lbl.position = pos + Vector3(0.0, 3.7, 0.0)
		_portal_root.add_child(lbl)

func _handle_events() -> void:
	for ev in _state["events"]:
		var t = ev.get("type", "")
		if t == "dmg":
			var tgt := str(ev["tgt"])
			var crit := bool(ev["crit"])
			var taken := tgt == _player_id                 # I got hit
			var dealt := str(ev.get("src", "")) == _player_id   # I landed the hit
			_spawn_num(tgt, int(ev["amt"]), crit, taken, dealt)
			_spawn_pop(tgt, crit)
			var tf = _find_fighter(tgt)
			if tf != null:
				AudioManager.play_sfx("crit" if crit else "hit", _world(tf))
			if taken:                                       # shake when I take damage (more for a big/crit hit)
				var pf = _find_fighter(_player_id)
				var frac: float = (float(ev["amt"]) / maxf(1.0, float(pf["maxHP"]))) if pf != null else 0.0
				_add_shake(clampf(0.15 + frac * 2.4 + (0.12 if crit else 0.0), 0.0, SHAKE_MAX))
		elif t == "kill":
			var victim := str(ev["victim"])
			var vf = _find_fighter(victim)
			_spawn_death(victim)
			if vf != null:
				AudioManager.play_sfx("death", _world(vf))
			if str(ev.get("killer", "")) == _player_id:
				_add_shake(0.35)                            # a satisfying thump on your kill
			elif victim == _player_id:
				_add_shake(SHAKE_MAX)                       # you died — full shake
	_state["events"].clear()

func _tick_respawns(dt: float) -> void:
	for f in _state["fighters"]:
		if not f["alive"] and not _respawn.has(f["id"]):
			_respawn[f["id"]] = RESPAWN_DELAY
	var done := []
	for id in _respawn:
		_respawn[id] -= dt
		if _respawn[id] <= 0.0:
			done.append(id)
	for id in done:
		_respawn.erase(id)
		_revive(_find_fighter(id))

# Reset a dead fighter to a fresh combat state at its spawn (training-arena respawn).
func _revive(f) -> void:
	if f == null:
		return
	f["hp"] = f["maxHP"]
	f["alive"] = true
	f["shield"] = 0.0
	f["shieldT"] = 0.0
	f["casting"] = null
	f["stun"] = 0.0
	f["slowT"] = 0.0
	f["slowAmt"] = 0.0
	f["evade"] = 0.0
	f["untarget"] = 0.0
	f["flash"] = 0.0
	f["buffs"] = {"nextdmg": 0.0, "crit": 0.0, "critT": 0.0, "atkspd": 1.0, "atkspdT": 0.0,
		"dr": 0.0, "drT": 0.0, "ms": 1.0, "msT": 0.0, "bypass": 0.0, "reflect": 0.0}
	f["momentum"] = 0.0
	f["momentumT"] = 0.0
	f["barrier"] = 0.0
	f["barrierT"] = 0.0
	f["barrierStored"] = 0.0
	f["_barrierAb"] = null
	f["hatTarget"] = null
	f["hatCount"] = 0
	f["hatChainT"] = 0.0
	f["noDmgT"] = 0.0
	f["atkCommitT"] = 0.0
	f["chaseT"] = 0.0
	for k in f["cds"]:
		f["cds"][k] = 0.0
	# restore the remaining create_fighter fields so a respawn == a fresh spawn (port parity)
	f["supportCasts"] = 0
	f["deathT"] = 0.0
	f["_pocketDR"] = 0.0
	f["lastCastKey"] = ""
	f["dmgDealt"] = 0.0
	f["dmgTaken"] = 0.0
	f["healing"] = 0.0
	f["mitigated"] = 0.0
	f["kills"] = 0
	f["hx"] = float(1 if f["team"] == 0 else -1)
	f["hy"] = 0.0
	f["facing"] = 1 if f["team"] == 0 else -1
	f["strafeDir"] = 1 if (f["team"] + f["slot"]) % 2 == 0 else -1
	f["moveMode"] = "approach"
	f["flipT"] = 0.0
	# drop any input queued while dead so it doesn't auto-fire on the first revived tick
	if _player != null and f["id"] == _player_id:
		_player.intent["ability"] = ""
	var sp: Vector2 = _spawn_pos[f["id"]]
	f["x"] = sp.x
	f["y"] = sp.y
	var n = _nodes.get(f["id"])
	if n != null:
		n["died"] = false
		n["busy"] = ""
		n["ui"].visible = true
		n["holder"].position = _world(f)
		n["last"] = n["holder"].position
		n["vel"] = Vector2.ZERO
		if n["anim"] != null:
			_safe_play(n["anim"], n["anims"].get("idle", "idle"))

# ============================================================ animation
func _safe_play(ap: AnimationPlayer, clip: String, speed := 1.0) -> void:
	if ap != null and ap.has_animation(clip):
		ap.play(clip, -1, speed)

# Meshy action clips bake huge root (Hips) translation — the hit clip drifts ~128u, sliding the whole
# mesh off its ground ring. The server owns position, so action animation must play IN PLACE: pin the
# Hips X/Z (and Y, except for the death collapse) to the clip's first frame. Idempotent; no-op on the
# already-clean idle/run/walk. (Path is "Armature/Skeleton3D:Hips" across all four rigs.)
static func _strip_root_motion(clip: Animation, clamp_y: bool) -> void:
	for i in clip.get_track_count():
		if clip.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		if not str(clip.track_get_path(i)).ends_with(":Hips"):
			continue
		var kc := clip.track_get_key_count(i)
		if kc == 0:
			return
		var base: Vector3 = clip.track_get_key_value(i, 0)
		for k in kc:
			var v: Vector3 = clip.track_get_key_value(i, k)
			v.x = base.x
			v.z = base.z
			if clamp_y:
				v.y = base.y
			clip.track_set_key_value(i, k, v)
		return

# The Meshy idle clip bakes a Hips SCALE of ~1.176 (the character balloons 17% when idle, then snaps
# back the instant it runs/acts — reads as a shrink). No other clip animates scale, so remove any Hips
# scale track → the bone uses its rest scale and the character stays one constant size.
static func _strip_hips_scale(clip: Animation) -> void:
	for i in range(clip.get_track_count() - 1, -1, -1):
		if clip.track_get_type(i) == Animation.TYPE_SCALE_3D and str(clip.track_get_path(i)).ends_with(":Hips"):
			clip.remove_track(i)

func _ability_type(class_id: String, key) -> String:
	if key == null or key == "":
		return ""
	for ab in GameData.CLASSES[class_id]["abilities"]:
		if ab["key"] == key:
			return ab["type"]
	return ""

# Detect a fresh cast by a cooldown rising, then queue the right one-shot clip.
func _detect_cast(n: Dictionary, f: Dictionary) -> void:
	var atk := ""
	var spd := 1.0
	for k in f["cds"]:
		# derive the clip from the specific ability whose cooldown rose this frame (not the
		# global lastCastKey, which can mismatch when two casts land in one render frame).
		if f["cds"][k] > float(n["pcds"].get(k, 0.0)) + 0.05:
			var t := _ability_type(f["classId"], k)
			var am: Dictionary = n["anims"]
			if ANIM_OVERRIDE.has(f["classId"]) and ANIM_OVERRIDE[f["classId"]].has(k):
				atk = ANIM_OVERRIDE[f["classId"]][k]
			elif t == "projectile" or t == "barrage":
				atk = am.get("ranged", "")
			elif t == "melee" or t == "meleeAoe" or t == "dashAttack" or t == "leapAttack":
				atk = am.get("melee", "")
			elif t == "selfbuff" or t == "allybuff" or t == "allyheal" or t == "teamheal" or t == "zone" or t == "barrier":
				atk = am.get("cast", "")
			if atk != "":
				spd = _cast_speed(n["anim"], atk, float(f["cds"][k]))   # snap to the ability's cadence
			break
	n["pcds"] = f["cds"].duplicate()
	n["atk_clip"] = atk
	n["atk_speed"] = spd

# Speed so an action clip plays in ~CAST_DUR_FRAC of the ability's cooldown (clamped). Only ever speeds
# up (>=1x); cap at 6x to avoid a blur. cd = the cooldown just set by the cast (its rising-edge value).
func _cast_speed(ap: AnimationPlayer, clip: String, cd: float) -> float:
	if ap == null or not ap.has_animation(clip):
		return 1.0
	var clen: float = ap.get_animation(clip).length
	if clen <= 0.0:
		return 1.0
	var target := clampf(cd * CAST_DUR_FRAC, CAST_DUR_MIN, CAST_DUR_MAX)
	return clampf(clen / target, 1.0, 6.0)

func _drive_anim(n: Dictionary, f: Dictionary, moving: bool) -> void:
	var ap: AnimationPlayer = n["anim"]
	if ap == null:
		return
	var am: Dictionary = n["anims"]
	if not f["alive"]:
		if not n["died"]:
			n["died"] = true
			n["ui"].visible = false
			_safe_play(ap, am.get("death", "death"))
		return
	# never interrupt a one-shot (attack/cast/hit) still playing
	if n["busy"] != "" and ap.is_playing() and ap.current_animation == n["busy"]:
		return
	n["busy"] = ""
	if n["atk_clip"] != "":
		n["busy"] = n["atk_clip"]
		_safe_play(ap, n["atk_clip"], n.get("atk_speed", 1.0))   # snappy, scaled to the ability's cadence
	elif f["flash"] > 0.0 and n["pflash"] <= 0.0 and n["hit_cd"] <= 0.0:
		n["busy"] = am.get("hit", "hit")
		n["hit_cd"] = HIT_FLINCH_CD
		_safe_play(ap, am.get("hit", "hit"), HIT_SPEED)   # snappy in-place flinch (root motion stripped at load)
	else:
		var clip: String = am.get("run", "run") if moving else am.get("idle", "idle")
		if ap.current_animation != clip or not ap.is_playing():
			_safe_play(ap, clip)

func _update_ui(n: Dictionary, f: Dictionary) -> void:
	var ui: Node3D = n["ui"]
	ui.look_at(2.0 * ui.global_position - _cam.global_position, Vector3.UP)
	var frac: float = clampf(f["hp"] / f["maxHP"], 0.0, 1.0)
	var fill: MeshInstance3D = n["fill"]
	fill.scale.x = max(frac, 0.001)
	fill.position.x = -BAR_W / 2.0 * (1.0 - frac)
	(fill.material_override as StandardMaterial3D).albedo_color = (Color(0.9, 0.3, 0.3) if frac < 0.35 else Color(0.3, 0.85, 0.4))
	var label: Label3D = n["label"]
	if f.get("dummy", false):
		label.text = "Training Dummy"
		label.modulate = Color(0.72, 0.74, 0.8)
	elif f.has("mobTier"):
		var tier: String = str(f["mobTier"])
		var lvl := int(f.get("mobLevel", 1))
		if tier == "boss":
			label.text = "Lv %d  ☠ BOSS" % lvl
			label.modulate = Color(1.0, 0.3, 0.32)
		elif tier == "elite":
			label.text = "Lv %d  ★ ELITE" % lvl
			label.modulate = Color(1.0, 0.55, 0.4)
		else:
			label.text = "Lv %d" % lvl
			label.modulate = Color(0.92, 0.82, 0.6)
	elif f.has("level"):
		var lpf = _find_fighter(_player_id)
		var hostile: bool = lpf != null and _hostile_pair(lpf, f)
		label.text = ("⚔ Lv %d" % int(f["level"])) if hostile else ("Lv %d" % int(f["level"]))
		label.modulate = Color(1.0, 0.45, 0.45) if hostile else Color(0.6, 0.85, 1.0)
	elif label.text != "":
		label.text = ""

# ============================================================ FX
# amt floater. `taken` = the local player got hit (red), `dealt` = the local player landed it
# (white / gold crit); anyone else's combat shows dimmer + smaller so the screen doesn't clutter.
func _spawn_num(tgt_id, amt: int, crit: bool, taken := false, dealt := false) -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var l: Label3D
	if _num_pool.is_empty():
		l = Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0011
		l.font_size = 96
		l.outline_size = 22
		l.outline_modulate = Color(0, 0, 0, 0.9)
		_fx_root.add_child(l)
	else:
		l = _num_pool.pop_back()
	l.visible = true
	l.text = ("%d!" % amt) if crit else str(amt)
	if taken:
		l.modulate = Color(1.0, 0.36, 0.3)              # damage I take = red
	elif dealt:
		l.modulate = Color(1.0, 0.85, 0.35) if crit else Color(1.0, 1.0, 0.95)
	else:
		l.modulate = Color(0.78, 0.8, 0.86)             # someone else's hit = dim
	var s := 1.0
	if crit: s = 1.85
	if taken: s *= 1.15
	if not (taken or dealt): s *= 0.7
	l.scale = Vector3.ONE * s
	var pos := _world(f)
	pos.y = DMG_NUM_Y
	l.position = pos
	_fx_active.append({"node": l, "t": 0.0, "life": (1.0 if crit else 0.82), "vel": (3.2 if crit else 2.6), "kind": "num"})

func _spawn_pop(tgt_id, crit := false) -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var p: MeshInstance3D
	if _pop_pool.is_empty():
		p = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.45
		sm.height = 0.9
		sm.radial_segments = 8
		sm.rings = 5
		p.mesh = sm
		var mt := StandardMaterial3D.new()
		mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mt.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		p.material_override = mt
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fx_root.add_child(p)
	else:
		p = _pop_pool.pop_back()
	(p.material_override as StandardMaterial3D).albedo_color = Color(1, 0.95, 0.7)   # set per spawn (pool shared w/ death)
	p.visible = true
	var pos := _world(f)
	pos.y = HIT_Y
	p.position = pos
	p.scale = Vector3.ONE * (0.8 if crit else 0.5)
	_fx_active.append({"node": p, "t": 0.0, "life": (0.32 if crit else 0.22), "vel": 0.0, "kind": "pop", "big": crit})

# a bigger, redder burst when a fighter dies (driven by the kill event)
func _spawn_death(tgt_id) -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var p: MeshInstance3D
	if _pop_pool.is_empty():
		p = MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.45
		sm.height = 0.9
		sm.radial_segments = 8
		sm.rings = 5
		p.mesh = sm
		var mt := StandardMaterial3D.new()
		mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mt.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		p.material_override = mt
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fx_root.add_child(p)
	else:
		p = _pop_pool.pop_back()
	(p.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.5, 0.35)
	p.visible = true
	var pos := _world(f)
	pos.y = HIT_Y
	p.position = pos
	p.scale = Vector3.ONE * 0.6
	_fx_active.append({"node": p, "t": 0.0, "life": 0.5, "vel": 0.0, "kind": "death"})

func _update_fx(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * SHAKE_DECAY)
	var keep := []
	for fx in _fx_active:
		fx["t"] += delta
		var k: float = fx["t"] / fx["life"]
		var node = fx["node"]
		if k >= 1.0:
			node.visible = false
			if fx["kind"] == "num":
				_num_pool.append(node)
			else:
				_pop_pool.append(node)
			continue
		if fx["kind"] == "num":
			node.position.y += fx["vel"] * delta
			(node as Label3D).modulate.a = 1.0 - k
		elif fx["kind"] == "death":
			node.scale = Vector3.ONE * (0.6 + k * 6.0)       # big expanding burst
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k
		else:
			var s: float = (0.5 + k * 2.4) * (1.7 if fx.get("big", false) else 1.0)
			node.scale = Vector3.ONE * s
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k
		keep.append(fx)
	_fx_active = keep

func _sync_projectiles() -> void:
	var shown := 0
	for p in _state["projectiles"]:
		if p.get("delay", 0.0) > 0.0:
			continue
		var pm: MeshInstance3D
		if shown < _proj_pool.size():
			pm = _proj_pool[shown]
		else:
			pm = MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.32
			sm.height = 0.64
			pm.mesh = sm
			var mt := StandardMaterial3D.new()
			mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mt.emission_enabled = true
			mt.albedo_color = Color(1, 0.92, 0.6)
			mt.emission = Color(1, 0.85, 0.4)
			pm.material_override = mt
			pm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_fx_root.add_child(pm)
			_proj_pool.append(pm)
		pm.visible = true
		pm.position = Vector3((p["x"] - _aw() / 2.0) * SCALE, 1.4, (p["y"] - _ah() / 2.0) * SCALE)
		shown += 1
	for i in range(shown, _proj_pool.size()):
		_proj_pool[i].visible = false

# ============================================================ helpers
func _find_fighter(id) -> Variant:
	for f in _state["fighters"]:
		if f["id"] == id:
			return f
	return null

# is fighter b hostile to fighter a? Mirrors the server's Combat.is_hostile (cross-team always; in a
# PvP zone two players are hostile unless they share a non-empty party key, both carried in snapshots).
func _hostile_pair(a: Dictionary, b: Dictionary) -> bool:
	if str(a["id"]) == str(b["id"]):
		return false
	if int(a.get("team", 0)) != int(b.get("team", 0)):
		return true
	if not bool(_state.get("pvp", false)) or int(a.get("team", 0)) != 0:
		return false
	var pa := str(a.get("party", ""))
	return pa == "" or pa != str(b.get("party", ""))   # hostile unless same non-empty party

func _enemy_dir(f: Dictionary) -> Vector2:
	var best = null
	var bd := INF
	for e in _state["fighters"]:
		if _hostile_pair(f, e) and e["alive"]:
			var d := Geom.dist(f, e)
			if d < bd:
				bd = d
				best = e
	if best == null:
		return Vector2.ZERO
	return Vector2(best["x"] - f["x"], best["y"] - f["y"])

# ============================================================ Phase 3 persistence
func _place_player_at(pos: Vector2) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	pf["x"] = pos.x
	pf["y"] = pos.y
	_spawn_pos[_player_id] = pos
	var n = _nodes.get(_player_id)
	if n != null:
		n["holder"].position = _world(pf)
		n["last"] = n["holder"].position
	_focus = _world(pf)

func _save_progress() -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or not pf["alive"] or supa == null or char_id == "":
		return                          # don't persist a corpse's death-spot
	var r = await supa.save_character(char_id, {"last_x": pf["x"], "last_y": pf["y"], "last_map": MAP_ID})
	if r.get("ok"):
		_save_note = "progress saved"
	elif r.get("expired"):
		_save_note = "session expired — relog to save"
	else:
		_save_note = "save failed"

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and supa != null and char_id != "" and not _quitting:
		_quitting = true
		await _save_progress()
		get_tree().quit()

# ============================================================ input (camera + meta)
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_dist = clampf(_dist / ZOOM_STEP, DIST_MIN, DIST_MAX)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_dist = clampf(_dist * ZOOM_STEP, DIST_MIN, DIST_MAX)
	elif e is InputEventMouseMotion and _dragging:
		_yaw -= e.relative.x * ORBIT_SENS
		_pitch = clampf(_pitch + e.relative.y * ORBIT_SENS, PITCH_MIN, PITCH_MAX)  # drag up = look down (MMO-natural)
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.physical_keycode == KEY_P:
			_bots_frozen = not _bots_frozen
			if _state != null:
				_state["botsFrozen"] = _bots_frozen
		elif e.physical_keycode == KEY_C:
			if class_locked:
				return                              # one class per account — no cycling
			_player_class_idx = (_player_class_idx + 1) % PLAYABLE.size()
			_setup_match(PLAYABLE[_player_class_idx])
		elif e.physical_keycode == KEY_R:
			_setup_match(PLAYABLE[_player_class_idx])
			if has_start_pos:
				_place_player_at(start_pos)

# ============================================================ HUD
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.scroll_active = false
	_info.position = Vector2(16, 12)
	_info.custom_minimum_size = Vector2(520, 0)
	_hud.add_child(_info)
	_bar = RichTextLabel.new()
	_bar.bbcode_enabled = true
	_bar.fit_content = true
	_bar.scroll_active = false
	_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_bar.position = Vector2(16, -120)
	_bar.custom_minimum_size = Vector2(900, 0)
	_hud.add_child(_bar)
	# skill bar (hotbar) + hover tooltip
	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", 6)
	_hud.add_child(_hotbar)
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.z_index = 4096                       # always draw on top of panels (it's a sibling under _hud)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat clicks meant for the UI under it
	_tt_label = RichTextLabel.new()
	_tt_label.bbcode_enabled = true
	_tt_label.fit_content = true
	_tt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE  # display-only; don't block the UI beneath
	_tt_label.custom_minimum_size = Vector2(250, 0)
	_tooltip.add_child(_tt_label)
	_hud.add_child(_tooltip)

# (re)build a slot per ability when the class is known/changes
func _build_hotbar(class_id: String) -> void:
	for s in _slots:
		s["root"].queue_free()
	_slots.clear()
	_hotbar_class = class_id
	var abilities: Array = GameData.CLASSES[class_id]["abilities"]
	for i in abilities.size():
		var ab = abilities[i]
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(60, 60)
		var bg := ColorRect.new()
		bg.size = Vector2(60, 60)
		bg.color = _slot_color(ab)
		slot.add_child(bg)
		var cd := ColorRect.new()                # cooldown wipe (dark, height = cd fraction)
		cd.color = Color(0, 0, 0, 0.62)
		cd.size = Vector2(60, 0)
		slot.add_child(cd)
		var kl := Label.new()                    # keybind
		kl.text = str(i + 1)
		kl.position = Vector2(4, 1)
		kl.add_theme_font_size_override("font_size", 16)
		slot.add_child(kl)
		var nl := Label.new()                    # ability name (small, wrapped)
		nl.text = str(ab["name"])
		nl.position = Vector2(2, 30)
		nl.size = Vector2(56, 28)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", 10)
		slot.add_child(nl)
		var cs := Label.new()                    # cooldown seconds (center)
		cs.position = Vector2(0, 18)
		cs.size = Vector2(60, 24)
		cs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cs.add_theme_font_size_override("font_size", 20)
		slot.add_child(cs)
		slot.mouse_entered.connect(_on_slot_hover.bind(i))
		slot.mouse_exited.connect(_on_slot_unhover)
		_hotbar.add_child(slot)
		_slots.append({"root": slot, "cd": cd, "cs": cs})

func _slot_color(ab: Dictionary) -> Color:
	if ab.get("ult", false): return Color(0.36, 0.30, 0.10)       # ultimate = gold-ish
	if ab.get("basic", false): return Color(0.14, 0.26, 0.16)     # basic = green-ish
	if ab["type"] in ["allybuff", "allyheal", "teamheal"]: return Color(0.13, 0.22, 0.30)  # support = blue
	return Color(0.16, 0.18, 0.24)                                # normal

func _update_hotbar(pf: Dictionary) -> void:
	if pf.get("classId", "") != _hotbar_class:
		_build_hotbar(str(pf["classId"]))
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_hotbar.position = Vector2((vp.x - _hotbar.size.x) / 2.0, vp.y - 86.0)
	var abilities: Array = GameData.CLASSES[str(pf["classId"])]["abilities"]
	for i in _slots.size():
		var ab = abilities[i]
		var total: float = float(ab.get("cd", 0.0))
		var rem: float = float(pf.get("cds", {}).get(ab["key"], 0.0))
		var frac: float = clampf(rem / total, 0.0, 1.0) if total > 0.0 else 0.0
		_slots[i]["cd"].size = Vector2(60.0, frac * 60.0)
		_slots[i]["cs"].text = ("%d" % int(ceil(rem))) if rem > 0.05 else ""

func _on_slot_hover(i: int) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or i >= GameData.CLASSES[str(pf["classId"])]["abilities"].size():
		return
	_tt_label.text = _ability_tooltip(GameData.CLASSES[str(pf["classId"])]["abilities"][i], pf)
	_tooltip.visible = true
	_tooltip.reset_size()
	var sp: Vector2 = _slots[i]["root"].global_position
	_tooltip.position = Vector2(sp.x - 95.0, sp.y - _tooltip.size.y - 8.0)

func _on_slot_unhover() -> void:
	_tooltip.visible = false

# the skill's real numbers, computed from the player's current stats + gear
func _ability_tooltip(ab: Dictionary, pf: Dictionary) -> String:
	var L := ["[b]%s[/b]  [color=#7f93a8]%s[/color]" % [ab["name"], str(ab["type"])]]
	var dm: float = float(pf.get("dmgMult", 1.0))
	var mhp: float = float(pf.get("maxHP", 1000.0))
	if ab.has("dmg"):
		L.append("Damage: [color=#ff9a6b]%d[/color]" % int(round(float(ab["dmg"]) * dm)))
		var cr: float = float(pf.get("crit", 0.0))
		if cr > 0.0:
			L.append("Crit: %d%% for %.1f×" % [int(round(cr * 100.0)), float(pf.get("critMult", 1.5))])
	if ab.has("healPct"):
		L.append("Heal: [color=#9fe8a0]%d[/color]" % int(round(float(ab["healPct"]) * mhp)))
	if ab.has("shieldPct"):
		L.append("Shield: [color=#9fd0ff]%d[/color]" % int(round(float(ab["shieldPct"]) * mhp)))
	if ab.has("range"):
		L.append("[color=#9fb4c8]Range: %d[/color]" % int(ab["range"]))
	if ab.has("dist"):
		L.append("[color=#9fb4c8]Dash: %d[/color]" % int(ab["dist"]))
	if ab.has("stun"):
		L.append("[color=#d7c27a]Stun: %.1fs[/color]" % float(ab["stun"]))
	if ab.has("slow"):
		L.append("[color=#d7c27a]Slow: %d%% for %.1fs[/color]" % [int(float(ab["slow"]["amt"]) * 100.0), float(ab["slow"]["dur"])])
	if ab.has("dur"):
		L.append("[color=#9fb4c8]Duration: %.1fs[/color]" % float(ab["dur"]))
	L.append("[color=#7f93a8]Cooldown: %.1fs[/color]" % float(ab.get("cd", 0.0)))
	return "\n".join(L)

func _update_hud() -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or _player == null:
		return
	var c: Dictionary = GameData.CLASSES[pf["classId"]]
	var alive_txt := "[color=#ff6b6b](respawning…)[/color]" if not pf["alive"] else ""
	var bots_txt := "[color=#7fd4ff][b]BOTS PAUSED[/b] — press P to engage[/color]" if _bots_frozen else "[color=#ff8a8a][b]BOTS ACTIVE[/b] — press P to pause[/color]"
	var title: String = ("%s the %s" % [char_name, c["name"]]) if char_name != "" else c["name"]
	var controls := "WASD move · 1-8 abilities · LMB basic · [b]Tab[/b] target · RMB-drag camera · wheel zoom · [b]P[/b] pause bots · [b]R[/b] reset"
	if not class_locked:
		controls += " · [b]C[/b] class"
	var save_txt := ("   [color=#7fd4ff]%s[/color]" % _save_note) if _save_note != "" else ""
	_info.text = "[b]%s[/b]  [color=#9fb4c8]%s · %s[/color]   HP %d/%d %s   %s%s\n[color=#7f93a8]%s[/color]" % [
		title, c["sport"], c["role"], int(round(pf["hp"])), int(pf["maxHP"]), alive_txt, bots_txt, save_txt, controls]
	_update_hotbar(pf)                           # the visual skill bar replaces the old text row
