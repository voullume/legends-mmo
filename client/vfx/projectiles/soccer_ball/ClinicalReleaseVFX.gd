# Client-only brief RELEASE compression ring for the Striker Clinical Finish — a very short warm ring at
# the kick/spawn point that CONTRACTS to a point and vanishes fast. It is a cosmetic release flourish, NOT
# a cast-time bar: Client spawns it only when a Clinical ball first APPEARS next to its striker (a genuine
# release), never on interest re-entry. reduce_fx makes it very faint. Pooled + hard-capped.
extends Node3D

var _ring: MeshInstance3D
var _mat: StandardMaterial3D
var _color := Color(1.0, 0.5, 0.2)
var _t := 0.0
var _life := 0.16
var _reduce := false

func configure(style: Dictionary) -> void:
	_color = style.get("trail_color", _color)
	if _mat != null:
		_mat.albedo_color = Color(_color.r, _color.g, _color.b, _mat.albedo_color.a)

func _ready() -> void:
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.24
	tm.outer_radius = 0.34
	_ring.mesh = tm
	_ring.rotation.x = deg_to_rad(90.0)
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_mat.albedo_color = _color
	_ring.material_override = _mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _mat == null:
		return
	_reduce = reduce
	_life = 0.16
	_t = 0.0
	visible = true
	_mat.albedo_color = Color(_color.r, _color.g, _color.b, 0.35 if reduce else 0.9)
	set_process(true)

func _process(delta: float) -> void:
	if _mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	var s: float = 1.35 - k * 1.15                    # CONTRACT to a point
	_ring.scale = Vector3(s, s, s)
	_mat.albedo_color.a = (0.35 if _reduce else 0.9) * (1.0 - k)
	if _t >= _life:
		visible = false
		set_process(false)

func is_free() -> bool:
	return not visible
