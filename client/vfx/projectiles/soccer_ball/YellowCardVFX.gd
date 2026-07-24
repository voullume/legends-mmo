# Client-only Yellow Card melee-stun cue, attached to the TARGET (follows its rendered body). A compact
# warm-yellow contact star + flattened ring at the feet, a brief whistle mark, a raised yellow CARD
# billboard, and a 3-star stun orbit at the head that fades with the AUTHORITATIVE remaining stun. Spawned
# ONLY on a confirmed Yellow Card hit (Client correlates the Striker's yellowcard cast edge with a real
# damage event — see Client._handle_events). No AOE/knockback/loot/silence/slow/extended-stun. The card is
# a brief identity window; the orbit follows st.stn. reduce_fx: one contact flash + a still card + one star,
# no whistle. configure() applies the owner-tunable values (F3 → striker/yellowcard).
extends Node3D

const CARD_DUR := 0.75          # card identity window (independent of the full stun)
const CONTACT_DUR := 0.3        # contact star + ring + whistle window
const HEAD_Y := 1.7             # head height above the feet (world)

var _card_scale := 1.0
var _star_scale := 1.0
var _contact_scale := 1.0
var _orbit_r := 0.5
var _card_height := 3.4         # world height of the raised card above the target's feet (tunable)
var _card_col := Color(1.0, 0.85, 0.1)
var _star_col := Color(1.0, 0.9, 0.2)

var _card: Node3D
var _card_mats := []            # [face, edge, mark] StandardMaterial3D (alpha animated together)
var _contact: MeshInstance3D
var _contact_mat: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _whistle := []              # [{node, mat}]
var _stars := []                # [{node, mat, ang}]
var _orbit: MeshInstance3D
var _orbit_mat: StandardMaterial3D
var _t := 0.0
var _stun := 0.0
var _active := false
var _reduce := false

func _mat(col: Color, billboard := true, additive := true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD   # glows (contact/stars/ring); the card stays SOLID (mix)
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = col
	return m

func _quad(size: Vector2, col: Color, z := 0.0, additive := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	mi.position.z = z
	var m := _mat(col, true, additive)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _ready() -> void:
	# raised card: bright yellow face + warm-white edge behind + one dark marking in front
	_card = Node3D.new()
	var edge := _quad(Vector2(0.76, 1.06), Color(1.0, 0.98, 0.85), -0.02, false)   # SOLID card (mix blend)
	var face := _quad(Vector2(0.62, 0.88), _card_col, 0.0, false)
	var mark := _quad(Vector2(0.3, 0.08), Color(0.15, 0.12, 0.02), 0.02, false)
	mark.position.y = -0.14
	_card.add_child(edge)
	_card.add_child(face)
	_card.add_child(mark)
	_card_mats = [face.material_override, edge.material_override, mark.material_override]
	add_child(_card)
	# feet: contact star (billboard) + flattened ring
	_contact = _quad(Vector2(0.5, 0.5), Color(1.0, 0.92, 0.4))
	_contact_mat = _contact.material_override
	add_child(_contact)
	_ring = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.28
	tm.outer_radius = 0.36
	_ring.mesh = tm
	_ring.rotation.x = deg_to_rad(90.0)
	_ring_mat = _mat(Color(1.0, 0.88, 0.3), false)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)
	for i in range(2):                                   # brief whistle marks
		var mi := _quad(Vector2(0.16, 0.05), Color(1.0, 0.98, 0.7))
		add_child(mi)
		_whistle.append({"node": mi, "mat": mi.material_override})
	# stun orbit: three small yellow stars + a faint orbit ring
	for i in range(3):
		var mi := _quad(Vector2(0.22, 0.22), _star_col)
		add_child(mi)
		_stars.append({"node": mi, "mat": mi.material_override, "ang": deg_to_rad(120.0 * i)})
	_orbit = MeshInstance3D.new()
	var otm := TorusMesh.new()
	otm.inner_radius = 0.02
	otm.outer_radius = 0.06
	_orbit.mesh = otm
	_orbit.rotation.x = deg_to_rad(90.0)
	_orbit_mat = _mat(Color(1.0, 0.9, 0.3, 0.4), false)
	_orbit.material_override = _orbit_mat
	_orbit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_orbit)
	set_process(false)
	visible = false

func configure(d: Dictionary) -> void:
	_card_scale = float(d.get("card_scale", _card_scale))
	_star_scale = float(d.get("star_scale", _star_scale))
	_contact_scale = float(d.get("contact_scale", _contact_scale))
	_orbit_r = float(d.get("orbit_r", _orbit_r))
	_card_height = float(d.get("card_height", _card_height))
	_card_col = d.get("card_col", _card_col)
	_star_col = d.get("star_col", _star_col)
	if not _card_mats.is_empty():
		(_card_mats[0] as StandardMaterial3D).albedo_color = Color(_card_col.r, _card_col.g, _card_col.b, (_card_mats[0] as StandardMaterial3D).albedo_color.a)
	for st in _stars:
		var a: float = (st["mat"] as StandardMaterial3D).albedo_color.a
		st["mat"].albedo_color = Color(_star_col.r, _star_col.g, _star_col.b, a)

func begin(reduce: bool) -> void:
	_reduce = reduce
	_active = true
	_t = 0.0
	_stun = 0.0
	visible = true
	for m in _card_mats:
		(m as StandardMaterial3D).albedo_color.a = 1.0
	_card.visible = true
	_contact.visible = true
	_ring.visible = true
	_contact_mat.albedo_color.a = 1.0
	_ring_mat.albedo_color.a = 1.0
	for w in _whistle:
		w["node"].visible = not reduce
		w["mat"].albedo_color.a = 0.0 if reduce else 1.0
	set_process(false)

# Driven each render frame by the client from the target's rendered FEET position + authoritative
# remaining stun (seconds). Returns nothing; the client stops it via is_done()/stop().
func follow(foot: Vector3, stun_secs: float, dt: float) -> void:
	if not _active:
		return
	_t += dt
	_stun = maxf(0.0, stun_secs)
	var head := Vector3(foot.x, foot.y + HEAD_Y, foot.z)
	# card: rise + hover above the head, brief identity window, then fade
	var rise: float = clampf(_t / 0.14, 0.0, 1.0)
	_card.global_position = Vector3(foot.x, foot.y + _card_height + rise * 0.28, foot.z)   # raised well ABOVE the target
	_card.scale = Vector3.ONE * _card_scale
	if not _reduce:
		_card.position.x += sin(_t * 7.0) * 0.006          # slight sway (billboard can't tilt)
	var ca: float = 1.0 - clampf((_t - CARD_DUR) / 0.2, 0.0, 1.0)
	for m in _card_mats:
		(m as StandardMaterial3D).albedo_color.a = ca
	if ca <= 0.0:
		_card.visible = false
	# contact star + ring at the feet: quick pop then fade
	var ck: float = clampf(_t / CONTACT_DUR, 0.0, 1.0)
	_contact.global_position = Vector3(foot.x, foot.y + 0.3, foot.z)
	var cs: float = (0.6 + ck * 0.7) * _contact_scale
	_contact.scale = Vector3(cs, cs, cs)
	_contact_mat.albedo_color.a = 1.0 - ck
	_ring.global_position = Vector3(foot.x, foot.y + 0.06, foot.z)
	var rs: float = (0.7 + ck * 0.9) * _contact_scale
	_ring.scale = Vector3(rs, rs, rs)
	_ring_mat.albedo_color.a = 1.0 - ck
	if ck >= 1.0:
		_contact.visible = false
		_ring.visible = false
	# whistle marks: brief, above the head, fade before the card settles
	if not _reduce:
		var wk: float = clampf(_t / 0.22, 0.0, 1.0)
		for wi in range(_whistle.size()):
			var w = _whistle[wi]
			w["node"].global_position = head + Vector3(0.28 + wi * 0.12, 0.5, 0.0)
			w["mat"].albedo_color.a = 1.0 - wk
			if wk >= 1.0:
				w["node"].visible = false
	# stun orbit: three stars circling the head while the authoritative stun runs
	var show_orbit := _stun > 0.01
	_orbit.visible = show_orbit and not _reduce
	if show_orbit:
		_orbit.global_position = head
		_orbit.scale = Vector3(_orbit_r / 0.06, 1.0, _orbit_r / 0.06)
	var n_stars: int = 1 if _reduce else _stars.size()
	for si in range(_stars.size()):
		var st = _stars[si]
		if si >= n_stars or not show_orbit:
			st["node"].visible = false
			continue
		st["node"].visible = true
		var a: float = float(st["ang"]) + _t * 4.0
		st["node"].global_position = head + Vector3(cos(a) * _orbit_r, 0.12 + sin(a * 1.3) * 0.05, sin(a) * _orbit_r)
		st["node"].scale = Vector3.ONE * _star_scale
		st["mat"].albedo_color = Color(_star_col.r, _star_col.g, _star_col.b, clampf(_stun / 0.3, 0.0, 1.0))

# Done when the identity window is over AND the authoritative stun has expired.
func is_done() -> bool:
	return _t > CARD_DUR and _stun <= 0.01

func stop() -> void:
	_active = false
	visible = false
	set_process(false)

func is_active() -> bool:
	return _active
