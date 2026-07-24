# Client-only compact impact for the Striker Bicycle Kick — a warm-gold contact STAR + a small cyan ring +
# a warm-white core, fast fade, kept within the struck silhouette (no broad ground shockwave). Pooled +
# self-timed. It carries NO gameplay meaning: Client._handle_events spawns it ONLY on a CONFIRMED damage
# event from a Striker whose bicyclekick cast-edge armed a same-tick window and who teleported adjacent to
# this target (see Client._leap_windows correlation). Single-target — never fired from proximity/animation
# alone. reduce_fx → one small gold flash, no cyan ring, no star rays.
extends Node3D

var _gold := Color(1.0, 0.78, 0.3)
var _cyan := Color(0.4, 0.9, 1.0)
var _rays := []                 # [{node, mat}] radiating gold bars (the "star")
var _ring: MeshInstance3D       # small cyan ring
var _ring_mat: StandardMaterial3D
var _core: MeshInstance3D       # warm-white core flash
var _core_mat: StandardMaterial3D
var _t := 0.0
var _life_base := 0.26
var _size_mul := 1.0
var _life := 0.26
var _reduce := false

func configure(style: Dictionary) -> void:
	_life_base = float(style.get("impact_life", 0.26))
	_size_mul = float(style.get("impact_scale", 1.0))
	_gold = style.get("gold", _gold)
	_cyan = style.get("cyan", _cyan)
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, _ring_mat.albedo_color.a)
	for r in _rays:
		(r["mat"] as StandardMaterial3D).albedo_color = Color(_gold.r, _gold.g, _gold.b, (r["mat"] as StandardMaterial3D).albedo_color.a)

func _add_mat(col: Color, billboard := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = col
	return m

func _ready() -> void:
	for i in range(6):                              # gold star = 6 thin radiating bars in the vertical plane
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.5, 0.05, 0.05)
		bar.mesh = bm
		bar.rotation.z = deg_to_rad(30.0 * i)
		var m := _add_mat(_gold)
		bar.material_override = m
		bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(bar)
		_rays.append({"node": bar, "mat": m})
	_ring = MeshInstance3D.new()                    # small cyan ring, billboarded toward the elevated cam
	var tm := TorusMesh.new()
	tm.inner_radius = 0.16
	tm.outer_radius = 0.22
	_ring.mesh = tm
	_ring.rotation.x = deg_to_rad(90.0)
	_ring_mat = _add_mat(_cyan)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	_core = MeshInstance3D.new()                     # warm-white core flash
	var qm := QuadMesh.new()
	qm.size = Vector2(0.32, 0.32)
	_core.mesh = qm
	_core_mat = _add_mat(Color(1.0, 0.95, 0.8), true)
	_core.material_override = _core_mat
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _core_mat == null:
		return
	_reduce = reduce
	_life = maxf(0.06, _life_base * 0.55) if reduce else _life_base
	_t = 0.0
	visible = true
	for r in _rays:
		(r["node"] as Node3D).visible = not reduce   # reduce_fx: drop the star rays, keep the core flash
	_ring.visible = not reduce                       # reduce_fx: no cyan inner ring
	set_process(true)

func _process(delta: float) -> void:
	if _core_mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	var a: float = 1.0 - k
	var rs: float = (0.45 + k * 0.8) * _size_mul     # compact so the damage number stays legible
	for r in _rays:
		(r["node"] as Node3D).scale = Vector3(rs, 1.0, 1.0)
		(r["mat"] as StandardMaterial3D).albedo_color.a = a
	var cr: float = (0.6 + k * 0.9) * _size_mul
	_ring.scale = Vector3(cr, cr, cr)
	_ring_mat.albedo_color.a = a * 0.9
	var cs: float = (1.3 - k * 0.7) * _size_mul      # core punches bright then shrinks
	_core.scale = Vector3(cs, cs, cs)
	_core_mat.albedo_color.a = a
	if _t >= _life:
		visible = false
		set_process(false)

func is_free() -> bool:
	return not visible
