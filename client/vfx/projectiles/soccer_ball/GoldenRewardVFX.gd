# Client-only ON-KILL reward pulse for the Striker Golden Goal, played AT THE CASTER (not the victim) and
# ONLY when Golden Goal is authoritatively confirmed as the killing blow (Client correlates the kill event
# with a Golden Goal ball having been next to the victim — see Client._handle_events kill branch). It is a
# brief cue for the +45% move-speed / 15% DR buff; the real 2 s buff is shown by normal status. A quick
# gold protective ring + restrained cyan forward chevrons (speed) + a faint shield outline (DR). It must
# NOT look like immunity/heal/permanent barrier. reduce_fx → small gold ring + one cyan chevron.
extends Node3D

const GOLD := Color(1.0, 0.82, 0.34)
const CYAN := Color(0.45, 0.9, 1.0)

var _ring: MeshInstance3D
var _shield: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _shield_mat: StandardMaterial3D
var _chevrons := []          # [{node, mat}]
var _t := 0.0
var _life := 0.5
var _reduce := false

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
	var r := _flat_ring(0.36, 0.46, GOLD)         # gold protective ring
	_ring = r[0]
	_ring_mat = r[1]
	var s := _flat_ring(0.5, 0.56, CYAN)          # faint shield outline (upright, around the caster)
	_shield = s[0]
	_shield.rotation.x = 0.0                        # vertical hoop, not flat
	_shield_mat = s[1]
	# three restrained cyan forward chevrons (speed), fanned to one side
	for k in range(3):
		var ang := deg_to_rad(-32.0 + k * 32.0)
		var pivot := Node3D.new()
		pivot.position = Vector3(cos(ang) * 0.5, 0.15 + k * 0.18, sin(ang) * 0.5)
		pivot.rotation.y = -ang + PI                # tips point outward (forward speed)
		var mat := _add_mat(CYAN)
		for sgn in [1.0, -1.0]:
			var bar := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.2, 0.02, 0.045)
			bar.mesh = bm
			bar.material_override = mat
			bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			bar.position = Vector3(0.07, 0.0, 0.06 * sgn)
			bar.rotation.y = deg_to_rad(36.0 * sgn)
			pivot.add_child(bar)
		add_child(pivot)
		_chevrons.append({"node": pivot, "mat": mat})
	set_process(false)
	visible = false

func play(reduce: bool) -> void:
	if _ring_mat == null:
		return
	_reduce = reduce
	_life = maxf(0.2, 0.5)
	_t = 0.0
	visible = true
	_ring_mat.albedo_color.a = 1.0
	_shield_mat.albedo_color.a = 0.0 if reduce else 0.6
	_shield.visible = not reduce
	for ci in range(_chevrons.size()):
		var ch = _chevrons[ci]
		ch["node"].visible = (ci == 0) or not reduce   # reduce_fx: one cyan chevron
		ch["mat"].albedo_color.a = 1.0
	set_process(true)

func _process(delta: float) -> void:
	if _ring_mat == null:
		return
	_t += delta
	var k: float = clampf(_t / _life, 0.0, 1.0)
	var rs: float = 0.7 + k * 0.8
	_ring.scale = Vector3(rs, rs, rs)
	_ring_mat.albedo_color.a = 1.0 - k
	if not _reduce:
		_shield_mat.albedo_color.a = (1.0 - k) * 0.6
	# chevrons rise/fade (a quick speed flourish)
	for ci in range(_chevrons.size()):
		var ch = _chevrons[ci]
		if not ch["node"].visible:
			continue
		ch["node"].position.y = (0.15 + ci * 0.18) + k * 0.25
		ch["mat"].albedo_color.a = 1.0 - k
	if _t >= _life:
		visible = false
		set_process(false)

func is_free() -> bool:
	return not visible
