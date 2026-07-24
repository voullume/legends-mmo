# Client-only ULTIMATE single-target impact for the Striker Golden Goal. Pooled + self-timed. Powerful
# but COMPACT (not AoE): a heavy gold outer ring + warm-white inner ring + centre flash EXPANDING, plus
# eight short radial match-winner rays, then a fast fade. No shockwave across bystanders, no persistent
# decal. Spawned by Client._handle_events ONLY on a real Golden Goal damage event near a tracked ball —
# never from interest filtering. reduce_fx → one ring + centre flash, rays dropped.
extends Node3D

const GOLD := Color(1.0, 0.82, 0.32)
const WHITE := Color(1.0, 0.96, 0.85)

var _outer: MeshInstance3D
var _inner: MeshInstance3D
var _flash: MeshInstance3D
var _outer_mat: StandardMaterial3D
var _inner_mat: StandardMaterial3D
var _flash_mat: StandardMaterial3D
var _rays := []              # [{node, mat}]
var _t := 0.0
var _life_base := 0.4
var _size_mul := 1.0
var _life := 0.4
var _reduce := false

func configure(style: Dictionary) -> void:
	_life_base = float(style.get("impact_life", 0.4))
	_size_mul = float(style.get("impact_scale", 1.0))

func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = col
	return m

func _flat_ring(inner_r: float, outer_r: float, col: Color) -> Array:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = inner_r
	tm.outer_radius = outer_r
	mi.mesh = tm
	mi.rotation.x = deg_to_rad(90.0)
	var m := _add_mat(col)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return [mi, m]

func _ready() -> void:
	var o := _flat_ring(0.4, 0.54, GOLD)
	_outer = o[0]
	_outer_mat = o[1]
	var i := _flat_ring(0.16, 0.24, WHITE)
	_inner = i[0]
	_inner_mat = i[1]
	_flash = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.62, 0.62)
	_flash.mesh = q
	_flash_mat = _add_mat(WHITE)
	_flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash.material_override = _flash_mat
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flash)
	# eight short radial match-winner rays (thin flat bars pointing OUTWARD)
	for k in range(8):
		var ang := deg_to_rad(45.0 * k)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.26, 0.02, 0.045)
		mi.mesh = bm
		mi.rotation.y = -ang
		var m := _add_mat(GOLD)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_rays.append({"node": mi, "mat": m})
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _outer_mat == null:
		return
	_reduce = reduce
	_life = maxf(0.1, _life_base * 0.7) if reduce else _life_base
	_t = 0.0
	visible = true
	_outer_mat.albedo_color.a = 1.0
	_inner_mat.albedo_color.a = 0.0 if reduce else 1.0
	_flash_mat.albedo_color.a = 1.0
	_inner.visible = not reduce
	for r in _rays:
		r["node"].visible = not reduce                # reduce_fx: drop the rays
	set_process(true)

func _process(delta: float) -> void:
	if _outer_mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	var os: float = (0.7 + k * 1.15) * _size_mul
	_outer.scale = Vector3(os, os, os)
	var isc: float = (0.55 + k * 0.85) * _size_mul
	_inner.scale = Vector3(isc, isc, isc)
	_outer_mat.albedo_color.a = 1.0 - k
	if not _reduce:
		_inner_mat.albedo_color.a = (1.0 - k) * 0.9
	var fk: float = clampf(_t / (_life * 0.35), 0.0, 1.0)
	var fs: float = (0.9 + fk * 1.0) * _size_mul
	_flash.scale = Vector3(fs, fs, fs)
	_flash_mat.albedo_color.a = 1.0 - fk
	# rays shoot outward and fade
	if not _reduce:
		for ri in range(_rays.size()):
			var r = _rays[ri]
			var ang := deg_to_rad(45.0 * ri)
			var rad: float = (0.4 + k * 0.7) * _size_mul
			r["node"].position = Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
			r["mat"].albedo_color.a = 1.0 - k
	if _t >= _life:
		visible = false
		set_process(false)

func is_free() -> bool:
	return not visible
