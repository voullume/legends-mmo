# Client-only Bicycle Kick LEAP cue, world-space (top_level) so it can trail the caster across the arena.
# It renders the ATTACHED presentation only — a concise cyan body-linked ribbon, a short-lived contact
# soccer ball near the raised foot at the END of the rotation, and a cyan half-ring at the authoritative
# landing spot. The character's own arc/lift/backward-pitch is driven by Client._update_leaps (which owns
# the model node); this controller is fed the model + foot world positions each frame.
#
# The ball here is a CONTACT PROP, never a projectile: it appears only in the last part of the arc, does
# not launch/travel/persist/collide, and never enters the projectile pool. Started on an accepted
# bicyclekick cast-edge; the single-target impact is a SEPARATE confirmed-damage cue (Client._spawn_leap_impact).
# reduce_fx: ribbon → one short segment, contact ball kept, no landing ring.
extends Node3D

const _BALL_SCENE := "res://client/vfx/projectiles/soccer_ball/soccer_ball.tscn"
const TRAIL_N := 8              # ribbon sample count
const LAND_FADE := 0.3         # landing-ring tail after the arc completes

var _ribbon_width := 0.14
var _ball_scale := 0.22
var _land_scale := 1.0
var _cyan := Color(0.4, 0.9, 1.0)
var _gold := Color(1.0, 0.8, 0.35)

var _ribbon := []              # [{node, mat}] fading cyan billboard quads (motion ribbon)
var _trail := []               # recent model world positions (ring buffer, newest last)
var _ball: Node3D              # contact prop
var _roller: Node3D
var _arc: MeshInstance3D       # small warm-gold contact arc around the ball
var _arc_mat: StandardMaterial3D
var _ring: MeshInstance3D      # cyan landing half-ring
var _ring_mat: StandardMaterial3D
var _dest := Vector3.ZERO
var _t := 0.0                  # arc progress driver (Client passes progress; this is the tail timer)
var _tail := 0.0               # landing-ring fade timer (runs once progress hits 1)
var _landed := false
var _active := false
var _reduce := false

func _mat(col: Color, billboard := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = col
	return m

func _ready() -> void:
	top_level = true                                 # ignore _fx_root's transform → child local == world
	position = Vector3.ZERO
	for i in range(TRAIL_N):
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(_ribbon_width, _ribbon_width)
		q.mesh = qm
		var m := _mat(_cyan, true)
		q.material_override = m
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		q.visible = false
		add_child(q)
		_ribbon.append({"node": q, "mat": m})
	_ball = Node3D.new()
	_ball.scale = Vector3.ONE * _ball_scale
	_roller = (load(_BALL_SCENE) as PackedScene).instantiate()
	_ball.add_child(_roller)
	_ball.visible = false
	add_child(_ball)
	_arc = MeshInstance3D.new()
	var atm := TorusMesh.new()
	atm.inner_radius = 0.34
	atm.outer_radius = 0.42
	_arc.mesh = atm
	_arc_mat = _mat(_gold)
	_arc.material_override = _arc_mat
	_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_arc.visible = false
	add_child(_arc)
	_ring = MeshInstance3D.new()
	var rtm := TorusMesh.new()
	rtm.inner_radius = 0.36
	rtm.outer_radius = 0.46
	_ring.mesh = rtm
	_ring.rotation.x = deg_to_rad(90.0)              # flat landing disc
	_ring_mat = _mat(_cyan)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring.visible = false
	add_child(_ring)
	set_process(false)
	visible = false

func configure(d: Dictionary) -> void:
	_ribbon_width = float(d.get("ribbon_width", _ribbon_width))
	_ball_scale = float(d.get("ball_scale", _ball_scale))
	_land_scale = float(d.get("land_scale", _land_scale))
	_cyan = d.get("cyan", _cyan)
	_gold = d.get("gold", _gold)
	for r in _ribbon:
		(r["node"].mesh as QuadMesh).size = Vector2(_ribbon_width, _ribbon_width)
		var a: float = (r["mat"] as StandardMaterial3D).albedo_color.a
		r["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, a)
	if _ball != null:
		_ball.scale = Vector3.ONE * _ball_scale
	if _arc_mat != null:
		_arc_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, _arc_mat.albedo_color.a)
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, _ring_mat.albedo_color.a)

func begin(dest: Vector3, reduce: bool) -> void:
	_dest = dest
	_reduce = reduce
	_active = true
	_landed = false
	_t = 0.0
	_tail = 0.0
	_trail.clear()
	visible = true
	for r in _ribbon:
		r["node"].visible = false
	_ball.visible = false
	_arc.visible = false
	_ring.visible = false
	set_process(false)

# Driven each render frame by Client._update_leaps: the caster's model world position, an approximate foot
# world position (raised kicking foot), the 0-1 arc progress, the facing yaw, and dt.
func follow(model_world: Vector3, foot_world: Vector3, progress: float, facing_yaw: float, dt: float) -> void:
	if not _active:
		return
	# ── cyan body ribbon (sample the model path; fade by age) ──
	if progress < 1.0:
		_trail.append(model_world)
		if _trail.size() > TRAIL_N:
			_trail.remove_at(0)
	var n_show: int = 1 if _reduce else _trail.size()
	for i in range(_ribbon.size()):
		var r = _ribbon[i]
		var idx: int = _trail.size() - 1 - i
		var show := idx >= 0 and i < n_show and progress < 1.0
		r["node"].visible = show
		if show:
			r["node"].position = _trail[idx] + Vector3(0.0, 0.2, 0.0)
			var age: float = float(i) / float(max(1, n_show))
			r["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, (1.0 - age) * 0.7)
	# ── contact ball near the raised foot, only in the last part of the rotation ──
	var contact := progress >= 0.6 and progress < 1.0
	_ball.visible = contact
	_arc.visible = contact and not _reduce
	if contact:
		_ball.position = foot_world
		_ball.rotation.y = facing_yaw
		_roller.rotate(Vector3.RIGHT, dt * 22.0)     # spin fast for readability
		_arc.position = foot_world
		var ph: float = (progress - 0.6) / 0.4
		_arc.scale = Vector3.ONE * (0.7 + ph * 0.5)
		_arc_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, 1.0 - ph)
	# ── landing half-ring at the authoritative destination (movement readability, no area damage) ──
	if progress >= 1.0:
		if not _landed:
			_landed = true
			_ball.visible = false
			_arc.visible = false
			for r in _ribbon:
				r["node"].visible = false
		if not _reduce:
			_tail += dt
			var k: float = clampf(_tail / LAND_FADE, 0.0, 1.0)
			_ring.visible = k < 1.0
			_ring.position = _dest + Vector3(0.0, 0.06, 0.0)
			var rs: float = (0.7 + k * 0.6) * _land_scale
			_ring.scale = Vector3(rs, rs, rs)
			_ring_mat.albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, (1.0 - k) * 0.7)
		else:
			_tail = LAND_FADE

func is_done() -> bool:
	return _landed and _tail >= LAND_FADE

func stop() -> void:
	_active = false
	visible = false
	_ball.visible = false
	_arc.visible = false
	_ring.visible = false
	for r in _ribbon:
		r["node"].visible = false
	set_process(false)

func is_active() -> bool:
	return _active
