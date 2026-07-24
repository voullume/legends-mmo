# Client-only compact SLOW-CUE impact for the Striker Through Ball. Pooled + self-timed. Reads as
# "reduced movement / placement", NOT ice/freeze/root/stun: an ankle-height cyan ground ellipse + a
# smaller pale inner ellipse that CONTRACT (not expand), plus three short horizontal drag ticks, then a
# quick fade (shorter than the real 1.2 s slow). No snowflakes/frost/shards/chains/persistent decal.
# Spawned by Client._handle_events ONLY on a real Through Ball damage event near a tracked ball — never
# from interest filtering. reduce_fx → one subdued ring, ticks dropped.
extends Node3D

const CYAN := Color(0.42, 0.86, 1.0)
const PALE := Color(0.80, 0.95, 1.0)

var _outer: MeshInstance3D
var _inner: MeshInstance3D
var _outer_mat: StandardMaterial3D
var _inner_mat: StandardMaterial3D
var _ticks := []            # [{node, mat, x0}]
var _t := 0.0
var _life_base := 0.45
var _size_mul := 1.0
var _life := 0.45
var _reduce := false

# (Re)apply tunables — safe before or after _ready.
func configure(style: Dictionary) -> void:
	_life_base = float(style.get("impact_life", 0.45))
	_size_mul = float(style.get("impact_scale", 1.0))

func _flat_ring(inner_r: float, outer_r: float, col: Color) -> Array:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = inner_r
	tm.outer_radius = outer_r
	mi.mesh = tm
	mi.rotation.x = deg_to_rad(90.0)                 # flat on the ground → reads as an ellipse from the cam
	mi.scale = Vector3(1.35, 1.0, 0.85)              # slightly elliptical
	var m := _add_mat(col)
	mi.material_override = m
	add_child(mi)
	return [mi, m]

func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = col
	return m

func _ready() -> void:
	var o := _flat_ring(0.36, 0.46, CYAN)
	_outer = o[0]
	_outer_mat = o[1]
	var i := _flat_ring(0.16, 0.22, PALE)
	_inner = i[0]
	_inner_mat = i[1]
	# three short horizontal drag ticks (thin flat dashes) at ankle height
	for zi in [-0.28, 0.0, 0.28]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.34, 0.02, 0.05)
		mi.mesh = bm
		mi.position = Vector3(0.0, 0.01, zi)
		var m := _add_mat(CYAN)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_ticks.append({"node": mi, "mat": m, "x0": -0.18})
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _outer_mat == null:
		return
	_reduce = reduce
	_life = maxf(0.08, _life_base * 0.6) if reduce else _life_base
	_t = 0.0
	visible = true
	_outer_mat.albedo_color.a = 1.0
	_inner_mat.albedo_color.a = 0.0 if reduce else 1.0
	_inner.visible = not reduce
	for tk in _ticks:
		tk["node"].visible = not reduce                  # reduce_fx: drop the drag ticks
	set_process(true)

func _process(delta: float) -> void:
	if _outer_mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	# CONTRACT: rings start wide and pull in (movement being reined in), fading out
	var os: float = (1.25 - k * 0.7) * _size_mul
	_outer.scale = Vector3(1.35 * os, 1.0, 0.85 * os)
	var isc: float = (1.1 - k * 0.6) * _size_mul
	_inner.scale = Vector3(1.35 * isc, 1.0, 0.85 * isc)
	var a: float = 1.0 - k
	_outer_mat.albedo_color.a = a
	if not _reduce:
		_inner_mat.albedo_color.a = a * 0.85
	# drag ticks: slide inward a touch and fade fast
	for tk in _ticks:
		if not tk["node"].visible:
			continue
		tk["node"].position.x = float(tk["x0"]) * _size_mul * (1.0 - k * 0.5)
		tk["mat"].albedo_color.a = (1.0 - k) * 0.9
	if _t >= _life:
		visible = false                                  # no lingering decal
		set_process(false)

# The pool reuses any node that has finished playing.
func is_free() -> bool:
	return not visible
