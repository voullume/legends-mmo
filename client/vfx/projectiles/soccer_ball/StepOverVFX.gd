# Client-only Step Over SELF-BUFF cue, attached to the CASTER. A brief soccer feint (the shared ball at
# the feet with two quick alternating foot-path accents + a warm-gold activation ring), then a restrained
# STATUS-DRIVEN buff aura: low cyan forward chevrons while the authoritative haste (st.ms) is active, and a
# partial gold shield arc while damage-reduction (st.dr) is active. Started on an accepted `stepover`
# cooldown edge (see Client._detect_cast); the aura components each follow/hide with their status, so
# another buff can extend/replace them without replaying the feint. No dash/attack/immunity/heal/shield-
# absorb/projectile. reduce_fx: ball + one foot pass, one cyan chevron, one faint arc, tiny ring.
extends Node3D

const _BALL_SCENE := "res://client/vfx/projectiles/soccer_ball/soccer_ball.tscn"
const FEINT_DUR := 0.45         # the ball feint window (the ball must NOT persist for the whole buff)

var _ball_scale := 0.24
var _ring_scale := 1.0
var _chev_scale := 1.0
var _arc_scale := 1.0
var _cyan := Color(0.45, 0.9, 1.0)
var _gold := Color(1.0, 0.8, 0.35)

var _ball: Node3D
var _roller: Node3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _footarcs := []             # [{node, mat}] warm-gold foot-path accents (feint)
var _chevrons := []             # [{node, mat}] cyan forward chevrons (haste)
var _arc: MeshInstance3D
var _arc_mat: StandardMaterial3D
var _t := 0.0
var _active := false
var _ms := false
var _dr := false
var _reduce := false

func _add_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = col
	return m

func _ready() -> void:
	_ball = Node3D.new()
	_ball.scale = Vector3.ONE * _ball_scale
	_roller = (load(_BALL_SCENE) as PackedScene).instantiate()
	_ball.add_child(_roller)
	add_child(_ball)
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.34
	tm.outer_radius = 0.44
	_ring.mesh = tm
	_ring.rotation.x = deg_to_rad(90.0)
	_ring_mat = _add_mat(_gold)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	for s in [-1.0, 1.0]:                                # two warm-gold foot-path accents (thin flat bars, curved-ish)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.34, 0.02, 0.05)
		mi.mesh = bm
		mi.rotation.y = deg_to_rad(28.0 * s)
		mi.position = Vector3(0.22 * s, 0.05, 0.18)
		var m := _add_mat(_gold)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_footarcs.append({"node": mi, "mat": m})
	for i in range(3):                                   # cyan forward chevrons (haste), cycling along local +Z
		var pivot := Node3D.new()
		var mat := _add_mat(_cyan)
		for sgn in [1.0, -1.0]:
			var bar := MeshInstance3D.new()
			var bm2 := BoxMesh.new()
			bm2.size = Vector3(0.18, 0.02, 0.04)
			bar.mesh = bm2
			bar.material_override = mat
			bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			bar.position = Vector3(0.06 * sgn, 0.0, 0.0)
			bar.rotation.y = deg_to_rad(-34.0 * sgn)
			pivot.add_child(bar)
		add_child(pivot)
		_chevrons.append({"node": pivot, "mat": mat, "ph": float(i) / 3.0})
	_arc = MeshInstance3D.new()                          # partial gold shield arc (DR) — a thin torus, NOT a closed bubble
	var atm := TorusMesh.new()
	atm.inner_radius = 0.7
	atm.outer_radius = 0.78
	_arc.mesh = atm
	_arc.rotation.z = deg_to_rad(90.0)                   # upright hoop
	_arc_mat = _add_mat(Color(_gold.r, _gold.g, _gold.b, 0.5))
	_arc.material_override = _arc_mat
	_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arc)
	set_process(false)
	visible = false

func configure(d: Dictionary) -> void:
	_ball_scale = float(d.get("ball_scale", _ball_scale))
	_ring_scale = float(d.get("ring_scale", _ring_scale))
	_chev_scale = float(d.get("chevron_scale", _chev_scale))
	_arc_scale = float(d.get("arc_scale", _arc_scale))
	_cyan = d.get("cyan", _cyan)
	_gold = d.get("gold", _gold)
	if _ball != null:
		_ball.scale = Vector3.ONE * _ball_scale
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, _ring_mat.albedo_color.a)
	for fa in _footarcs:
		var a: float = (fa["mat"] as StandardMaterial3D).albedo_color.a
		fa["mat"].albedo_color = Color(_gold.r, _gold.g, _gold.b, a)
	for ch in _chevrons:
		var a2: float = (ch["mat"] as StandardMaterial3D).albedo_color.a
		ch["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, a2)
	if _arc_mat != null:
		_arc_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, _arc_mat.albedo_color.a)

func begin(reduce: bool) -> void:
	_reduce = reduce
	_active = true
	_t = 0.0
	_ms = false
	_dr = false
	visible = true
	_ball.visible = true
	set_process(false)

# Driven each render frame: foot world position, the caster's facing yaw (chevrons point forward), and the
# authoritative haste / DR status flags.
func follow(foot: Vector3, facing_yaw: float, ms_active: bool, dr_active: bool, dt: float) -> void:
	if not _active:
		return
	_t += dt
	_ms = ms_active
	_dr = dr_active
	global_position = foot
	rotation.y = facing_yaw
	# ── feint: ball at the feet rolling a touch side-to-side + two foot-path accents ──
	var in_feint := _t < FEINT_DUR
	_ball.visible = in_feint
	if in_feint:
		var sway := sin(_t * 22.0) * 0.06
		_ball.position = Vector3(sway, _ball_scale * 0.98, 0.2)
		_roller.rotate(Vector3.RIGHT, dt * 6.0)
		for fi in range(_footarcs.size()):
			var fa = _footarcs[fi]
			fa["node"].visible = (fi == 0) or not _reduce
			fa["mat"].albedo_color.a = (0.5 + 0.5 * sin(_t * 26.0 + fi * PI)) * (1.0 - _t / FEINT_DUR)
	else:
		for fa in _footarcs:
			fa["node"].visible = false
	# ── activation ring: appears as the ball leaves, fades quickly ──
	var rk: float = clampf((_t - FEINT_DUR * 0.7) / 0.35, 0.0, 1.0)
	var ring_on := _t >= FEINT_DUR * 0.7 and rk < 1.0 and not (_reduce and _ring_scale < 0.05)
	_ring.visible = ring_on
	if ring_on:
		_ring.position = Vector3(0.0, 0.06, 0.0)
		var rs := (0.7 + rk * 0.9) * _ring_scale * (0.5 if _reduce else 1.0)
		_ring.scale = Vector3(rs, rs, rs)
		_ring_mat.albedo_color.a = (1.0 - rk)
	# ── buff aura (status-driven) ──
	var aura := _t >= FEINT_DUR * 0.55
	# cyan forward chevrons — only while authoritative haste is active
	var n_chev: int = 1 if _reduce else _chevrons.size()
	for ci in range(_chevrons.size()):
		var ch = _chevrons[ci]
		var show := aura and _ms and ci < n_chev
		ch["node"].visible = show
		if show:
			var p: float = fmod(_t * 1.4 + float(ch["ph"]), 1.0)   # cycle forward
			ch["node"].position = Vector3(0.0, 0.16, 0.35 + p * 0.55)
			ch["node"].scale = Vector3.ONE * _chev_scale
			ch["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, (1.0 - p) * 0.9)
	# partial gold shield arc — only while damage-reduction is active
	_arc.visible = aura and _dr
	if _arc.visible:
		_arc.position = Vector3(0.0, 0.9, 0.0)
		var asx := _arc_scale * (0.85 if _reduce else 1.0)
		_arc.scale = Vector3(asx, asx, asx)
		_arc_mat.albedo_color.a = (0.45 if _reduce else 0.6) * (0.75 + 0.25 * sin(_t * 3.0))

func is_done() -> bool:
	return _t >= FEINT_DUR and not _ms and not _dr

func stop() -> void:
	_active = false
	visible = false
	set_process(false)

func is_active() -> bool:
	return _active
