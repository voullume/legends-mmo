# Client-only PRECISION-strike impact for the Striker Clinical Finish. Pooled + self-timed. Reads as a
# hard, precise single-target hit — heavier than the Finesse basic, but compact (NOT an AoE/explosion):
# a red-orange outer ring + a smaller warm-white/gold inner ring EXPANDING, four inward-facing precision
# chevrons that converge, and a short hot centre flash, then a fast fade. No flames/smoke/scorch. Spawned
# by Client._handle_events ONLY on a real Clinical damage event near a tracked ball — never from interest
# filtering. reduce_fx → one ring + centre flash, chevrons dropped.
extends Node3D

const OUTER := Color(1.0, 0.45, 0.16)      # red-orange
const INNER := Color(1.0, 0.9, 0.62)       # warm-white / gold
const FLASH := Color(1.0, 0.95, 0.8)

var _outer: MeshInstance3D
var _inner: MeshInstance3D
var _flash: MeshInstance3D
var _outer_mat: StandardMaterial3D
var _inner_mat: StandardMaterial3D
var _flash_mat: StandardMaterial3D
var _chevrons := []          # [{node, mat}]
var _t := 0.0
var _life_base := 0.28
var _size_mul := 1.0
var _life := 0.28
var _reduce := false

func configure(style: Dictionary) -> void:
	_life_base = float(style.get("impact_life", 0.28))
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
	var o := _flat_ring(0.34, 0.44, OUTER)
	_outer = o[0]
	_outer_mat = o[1]
	var i := _flat_ring(0.14, 0.2, INNER)
	_inner = i[0]
	_inner_mat = i[1]
	# short hot centre flash — a small billboarded additive quad
	_flash = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.5, 0.5)
	_flash.mesh = q
	_flash_mat = _add_mat(FLASH)
	_flash_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash.material_override = _flash_mat
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_flash)
	# four inward-facing precision chevrons (each = a ">" of two thin bars), at N/E/S/W in the flat plane
	for k in range(4):
		var ang := deg_to_rad(90.0 * k)
		var pivot := Node3D.new()
		pivot.position = Vector3(cos(ang), 0.0, sin(ang))
		pivot.rotation.y = -ang                       # tip points inward (toward centre)
		var mat := _add_mat(OUTER)
		for s in [1.0, -1.0]:
			var bar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.22, 0.02, 0.05)
			bar.mesh = bm
			bar.material_override = mat
			bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			bar.position = Vector3(0.08, 0.0, 0.07 * s)
			bar.rotation.y = deg_to_rad(38.0 * s)
			pivot.add_child(bar)
		add_child(pivot)
		_chevrons.append({"node": pivot, "mat": mat})
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _outer_mat == null:
		return
	_reduce = reduce
	_life = maxf(0.08, _life_base * 0.7) if reduce else _life_base
	_t = 0.0
	visible = true
	_outer_mat.albedo_color.a = 1.0
	_inner_mat.albedo_color.a = 0.0 if reduce else 1.0
	_flash_mat.albedo_color.a = 1.0
	_inner.visible = not reduce
	for ch in _chevrons:
		ch["node"].visible = not reduce               # reduce_fx: drop the chevrons
		ch["mat"].albedo_color.a = 0.0 if reduce else 1.0
	set_process(true)

func _process(delta: float) -> void:
	if _outer_mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	# rings EXPAND (a hard strike burst), fading — heavier than finesse but compact (single-target)
	var os: float = (0.7 + k * 1.0) * _size_mul
	_outer.scale = Vector3(os, os, os)
	var isc: float = (0.6 + k * 0.7) * _size_mul
	_inner.scale = Vector3(isc, isc, isc)
	_outer_mat.albedo_color.a = 1.0 - k
	if not _reduce:
		_inner_mat.albedo_color.a = (1.0 - k) * 0.9
	# centre flash: bright and fast — gone by ~35% of life
	var fk: float = clampf(_t / (_life * 0.35), 0.0, 1.0)
	var fs: float = (0.8 + fk * 0.9) * _size_mul
	_flash.scale = Vector3(fs, fs, fs)
	_flash_mat.albedo_color.a = 1.0 - fk
	# chevrons converge inward (precision) and fade
	if not _reduce:
		for ci in range(_chevrons.size()):
			var ch = _chevrons[ci]
			var ang := deg_to_rad(90.0 * ci)
			var r: float = (1.05 - k * 0.55) * _size_mul
			ch["node"].position = Vector3(cos(ang) * r, 0.0, sin(ang) * r)
			ch["mat"].albedo_color.a = 1.0 - k
	if _t >= _life:
		visible = false
		set_process(false)

func is_free() -> bool:
	return not visible
