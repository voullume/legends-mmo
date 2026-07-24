# Client-only compact impact burst for the Striker Finesse Shot. Pooled + self-timed: it plays a fast
# gold outer ring + small cyan inner ring + a few short radial sparks, then hides itself. It carries NO
# gameplay meaning — Client._handle_events spawns it ONLY when the shared sim has already reported real
# damage to a target that a tracked finesse ball was next to (see Client._nearest_vfx_style, the keyed
# correlation that routes each hit to its style's impact). It never fires from interest filtering.
# reduce_fx shrinks/shortens it and drops the sparks.
extends Node3D

var _gold: MeshInstance3D
var _cyan: MeshInstance3D
var _sparks: GPUParticles3D
var _gold_mat: StandardMaterial3D
var _cyan_mat: StandardMaterial3D
var _t := 0.0
var _life_base := 0.28      # duration (dev-tunable); reduce_fx shortens it
var _size_mul := 1.0        # ring size multiplier (dev-tunable)
var _life := 0.28
var _reduce := false

# (Re)apply tunables — safe before or after _ready.
func configure(style: Dictionary) -> void:
	_life_base = float(style.get("impact_life", 0.28))
	_size_mul = float(style.get("impact_scale", 1.0))

func _ring(inner: float, outer: float, col: Color) -> Array:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = inner
	tm.outer_radius = outer
	mi.mesh = tm
	mi.rotation.x = deg_to_rad(90.0)                 # lay flat — an expanding shockwave disc under the elevated cam
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = col
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return [mi, m]

func _ready() -> void:
	var g := _ring(0.4, 0.5, Color(1.0, 0.78, 0.3, 1.0))
	_gold = g[0]
	_gold_mat = g[1]
	var c := _ring(0.14, 0.2, Color(0.4, 0.9, 1.0, 1.0))
	_cyan = c[0]
	_cyan_mat = c[1]
	_sparks = GPUParticles3D.new()
	_sparks.amount = 8
	_sparks.lifetime = 0.22
	_sparks.one_shot = true
	_sparks.explosiveness = 1.0
	_sparks.local_coords = false
	_sparks.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0, 1)
	pm.spread = 180.0
	pm.flatness = 1.0
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 5.0
	pm.scale_min = 0.4
	pm.scale_max = 0.8
	pm.color = Color(1.0, 0.85, 0.5)
	_sparks.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.1, 0.1)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	qm.albedo_color = Color(1.0, 0.85, 0.5)
	quad.material = qm
	_sparks.draw_pass_1 = quad
	add_child(_sparks)
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _gold_mat == null:
		return                                       # not ready yet (never happens once in the live tree)
	_reduce = reduce
	_life = maxf(0.06, _life_base * 0.57) if reduce else _life_base
	_t = 0.0
	visible = true
	_gold_mat.albedo_color.a = 1.0
	_cyan_mat.albedo_color.a = 1.0
	if _sparks != null:
		_sparks.emitting = false
		if not reduce:
			_sparks.restart()
			_sparks.emitting = true
	set_process(true)

func _process(delta: float) -> void:
	if _gold == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	var gs: float = (0.6 + k * (0.7 if _reduce else 1.1)) * _size_mul   # compact so the damage number stays legible
	_gold.scale = Vector3(gs, gs, gs)
	var cs: float = (0.5 + k * 0.7) * _size_mul
	_cyan.scale = Vector3(cs, cs, cs)
	var a: float = 1.0 - k
	_gold_mat.albedo_color.a = a
	_cyan_mat.albedo_color.a = a * 0.9
	if _t >= _life:
		visible = false                              # no lingering decal
		set_process(false)

# The pool reuses any node that has finished playing.
func is_free() -> bool:
	return not visible
