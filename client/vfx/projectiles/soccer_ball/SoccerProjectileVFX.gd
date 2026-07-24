# Client-only presentation node for the Striker Finesse Shot projectile. It NEVER computes a path,
# speed, or collision — the shared server sim owns all of that. Each render frame _sync_projectiles
# feeds it the authoritative snapshot position; this node only spins the approved soccer ball, drags a
# short warm trail behind the ACTUAL render positions, and stays pooled (no per-frame allocation).
# Source of truth for the ball geometry is the approved OBJ imported under this directory.
# Handoff: too_add_models/projectile_vfx_previews/SOCCER_PROJECTILE_IMPLEMENTATION_HANDOFF.md
extends Node3D

const _BALL_SCENE := "res://client/vfx/projectiles/soccer_ball/soccer_ball.tscn"
# A jump larger than this (world units) between two render frames means the pooled node was reassigned
# to a different projectile, the ball re-entered interest range, or the owner teleported — reset the
# trail so it never streaks across the arena. One tick of travel (~420 sim * 0.05 SCALE = 21 world u/s
# over a ~0.05 s frame ≈ 1.05 u) stays well under this, so a normal flight never trips it.
const _DISCONTINUITY := 6.0

var _pivot: Node3D
var _trail: GPUParticles3D
var _trail_quad: QuadMesh
var _trail_pm: ParticleProcessMaterial
var _trail_ramp: Gradient
var _trail_qmat: StandardMaterial3D
var _glow: MeshInstance3D
var _glow_mat: StandardMaterial3D
var _spin_speed := 12.0
var _scale := 0.42
var _trail_life := 0.16
var _trail_width := 0.16
var _trail_color := Color(1.0, 0.86, 0.6)
var _reduce := false
var _last_pos := Vector3.ZERO
var _have_last := false
var _spin_axis := Vector3(0.35, 1.0, 0.15).normalized()

func _ready() -> void:
	_pivot = Node3D.new()
	add_child(_pivot)
	var ball := (load(_BALL_SCENE) as PackedScene).instantiate()
	_pivot.add_child(ball)
	# short warm trail — hugs the actual path (local_coords off so particles stay in world space and
	# fall behind as the emitter moves). amount is the hard cap on live particles: no runtime growth.
	_trail = GPUParticles3D.new()
	_trail.amount = 20
	_trail.lifetime = 0.16
	_trail.local_coords = false
	_trail.emitting = false
	_trail.draw_order = GPUParticles3D.DRAW_ORDER_LIFETIME
	_trail_pm = ParticleProcessMaterial.new()
	_trail_pm.gravity = Vector3.ZERO
	_trail_pm.initial_velocity_min = 0.0
	_trail_pm.initial_velocity_max = 0.0
	_trail_pm.scale_min = 0.6
	_trail_pm.scale_max = 1.0
	_trail_ramp = Gradient.new()                      # bright core -> hue -> gone (colours set by _apply_trail_color)
	_trail_ramp.set_color(0, Color(1.0, 0.95, 0.82, 0.7))
	_trail_ramp.set_color(1, Color(1.0, 0.55, 0.2, 0.0))
	var gtex := GradientTexture1D.new()
	gtex.gradient = _trail_ramp
	_trail_pm.color_ramp = gtex
	_trail.process_material = _trail_pm
	_trail_quad = QuadMesh.new()
	_trail_quad.size = Vector2(_trail_width, _trail_width)
	_trail_qmat = _additive_mat(Color(1.0, 0.86, 0.6))
	_trail_quad.material = _trail_qmat
	_trail.draw_pass_1 = _trail_quad
	add_child(_trail)
	# faint additive glow floor so the ball reads at distance without a big "magical core"
	_glow = MeshInstance3D.new()
	var gs := SphereMesh.new()
	gs.radius = 0.5
	gs.height = 1.0
	_glow.mesh = gs
	_glow_mat = _additive_mat(Color(1.0, 0.8, 0.5, 0.12))
	_glow_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_glow.material_override = _glow_mat
	_glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glow)
	_apply_trail_color()
	set_process(false)
	visible = false

# Recolour the trail + glow from _trail_color (warm for Finesse, blue-white for Through Ball, etc).
func _apply_trail_color() -> void:
	var c := _trail_color
	if _trail_pm != null:
		_trail_pm.color = c
	if _trail_ramp != null:
		_trail_ramp.set_color(0, Color(c.lightened(0.25).r, c.lightened(0.25).g, c.lightened(0.25).b, 0.7))
		_trail_ramp.set_color(1, Color(c.r, c.g, c.b, 0.0))
	if _trail_qmat != null:
		_trail_qmat.albedo_color = c
	if _glow_mat != null:
		_glow_mat.albedo_color = Color(c.r, c.g, c.b, 0.12)   # faint — never a large aura

func _additive_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = col
	return m

# (Re)apply tunables — called at pool creation AND live from the dev VFX tuner, so a value change
# takes effect on the ball currently in flight, not just the next spawn.
func configure(style: Dictionary) -> void:
	_spin_speed = float(style.get("spin_speed", 12.0))
	_scale = float(style.get("scale", 0.42))
	_trail_life = float(style.get("trail_life", 0.16))
	_trail_width = float(style.get("trail_width", 0.16))
	_trail_color = style.get("trail_color", _trail_color)
	if _pivot != null:
		_pivot.scale = Vector3.ONE * _scale
	if _glow != null:
		_glow.scale = Vector3.ONE * _scale
	if _trail_quad != null:
		_trail_quad.size = Vector2(_trail_width, _trail_width)
	if _trail != null:
		_trail.lifetime = maxf(0.02, (_trail_life * 0.4) if _reduce else _trail_life)
	_apply_trail_color()

# Restore a clean state when this pooled node is (re)assigned to a fresh projectile.
func reset_for_spawn(reduce: bool) -> void:
	_reduce = reduce
	visible = true
	_have_last = false
	if _pivot != null:
		_pivot.rotation = Vector3.ZERO
		_pivot.scale = Vector3.ONE * _scale
	if _glow != null:
		_glow.visible = not reduce
	if _trail != null:
		_trail.restart()                             # drop any stale particles from the previous owner
		_trail.emitting = false                      # first frame only places the node; no arena-long streak
		_trail.lifetime = maxf(0.02, (_trail_life * 0.4) if reduce else _trail_life)
	set_process(true)

# The ONLY position input — the authoritative snapshot render position. No prediction, no homing.
func set_snapshot_position(world_pos: Vector3, _dt: float) -> void:
	if not _have_last:
		position = world_pos
		_last_pos = world_pos
		_have_last = true
		return
	if world_pos.distance_to(_last_pos) > _DISCONTINUITY:
		if _trail != null:
			_trail.restart()
			_trail.emitting = false
		position = world_pos
		_last_pos = world_pos
		return
	position = world_pos
	_last_pos = world_pos
	if _trail != null and not _reduce:
		_trail.emitting = true

func _process(delta: float) -> void:
	if _pivot != null:
		_pivot.rotate(_spin_axis, _spin_speed * (0.5 if _reduce else 1.0) * delta)

# Return the node cleanly to the pool.
func hide_to_pool() -> void:
	visible = false
	_have_last = false
	if _trail != null:
		_trail.emitting = false
		_trail.restart()
	set_process(false)
