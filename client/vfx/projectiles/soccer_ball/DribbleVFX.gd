# Client-only CHARACTER-ATTACHED dribble for the Striker Dribble DASH. NOT a projectile: the shared
# soccer ball appears as a small prop at the Striker's feet and is driven every frame from the fighter's
# RENDERED/reconciled body position (never an invented 155-unit path), so it can't arrive separately or
# linger after a correction. ~3 alternating controlled touches, the ball rolls with travel, warm-gold
# contact ticks, short cyan ground speed-marks behind, then one gold arrival ring at the lead foot. No
# damage/impact/target language. reduce_fx: one side shift, no arcs, minimal marks, one faint ring.
# Started only from an accepted `dribble` cooldown edge (see Client._detect_cast). configure() applies the
# owner-tunable values (F3 → striker/dribble); the ranges live in Client.DEFAULT_VFX_TUNE.
extends Node3D

const _BALL_SCENE := "res://client/vfx/projectiles/soccer_ball/soccer_ball.tscn"
const DUR := 0.5             # hard visual window (ends earlier if the body settles)
const FWD := 0.55            # ball offset ahead of the foot (world units)
const MARK_BASE := 0.5       # base speed-streak mesh length (scaled to the tunable mark_len)

# tunables (defaults; overridden by configure())
var _side_off := 0.3
var _ball_scale := 0.28
var _mark_len := 0.5
var _mark_life := 0.22
var _arrival_scale := 1.0
var _gold := Color(1.0, 0.78, 0.35)
var _cyan := Color(0.45, 0.9, 1.0)

var _ball: Node3D
var _roller: Node3D
var _arrival: MeshInstance3D
var _arrival_mat: StandardMaterial3D
var _ticks := []             # [{node, mat, t, life}] warm-gold contact flashes
var _marks := []             # [{node, mat, t, life}] cyan ground speed-marks
var _active := false
var _t := 0.0
var _touch_t := 0.0
var _mark_t := 0.0
var _side := 1.0
var _reduce := false
var _have_last := false
var _last_foot := Vector3.ZERO
var _still := 0.0            # time the body has been ~stationary (for early arrival)
var _moved_any := false

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
	_arrival = MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.3
	tm.outer_radius = 0.4
	_arrival.mesh = tm
	_arrival.rotation.x = deg_to_rad(90.0)
	_arrival_mat = _add_mat(_gold)
	_arrival.material_override = _arrival_mat
	_arrival.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_arrival)
	for i in range(5):                                   # pooled contact ticks (small gold billboards)
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.28, 0.28)
		mi.mesh = q
		var m := _add_mat(_gold)
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_ticks.append({"node": mi, "mat": m, "t": 0.0, "life": 0.0})
	for i in range(6):                                   # pooled cyan ground speed-marks (short streaks along travel)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(MARK_BASE, 0.02, 0.04)
		mi.mesh = bm
		var m := _add_mat(_cyan)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_marks.append({"node": mi, "mat": m, "t": 0.0, "life": 0.0})
	set_process(false)
	visible = false

# Apply owner-tunable values (F3 → striker/dribble). Safe before or after _ready; live-reconfigures colours.
func configure(d: Dictionary) -> void:
	_side_off = float(d.get("side", _side_off))
	_ball_scale = float(d.get("ball_scale", _ball_scale))
	_mark_len = float(d.get("mark_len", _mark_len))
	_mark_life = float(d.get("mark_life", _mark_life))
	_arrival_scale = float(d.get("arrival_scale", _arrival_scale))
	_gold = d.get("gold", _gold)
	_cyan = d.get("cyan", _cyan)
	if _ball != null:
		_ball.scale = Vector3.ONE * _ball_scale
	if _arrival_mat != null:
		_arrival_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, _arrival_mat.albedo_color.a)
	for tk in _ticks:
		var a: float = (tk["mat"] as StandardMaterial3D).albedo_color.a
		tk["mat"].albedo_color = Color(_gold.r, _gold.g, _gold.b, a)
	for mk in _marks:
		var a2: float = (mk["mat"] as StandardMaterial3D).albedo_color.a
		mk["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, a2)

# Start a dribble (accepted activation). The client then calls follow() each render frame.
func begin(reduce: bool) -> void:
	_reduce = reduce
	_active = true
	_t = 0.0
	_touch_t = 0.0
	_mark_t = 0.0
	_side = 1.0
	_have_last = false
	_still = 0.0
	_moved_any = false
	visible = true
	_ball.visible = true
	_arrival.visible = false
	set_process(true)                                    # ticks/marks/arrival fades run in _process

# Drive from the fighter's rendered foot position + smoothed travel dir. dt is the render delta.
func follow(foot: Vector3, dir: Vector3, dt: float) -> void:
	if not _active:
		return
	_t += dt
	var d2 := Vector3(dir.x, 0.0, dir.z)
	var moving := d2.length() > 0.003
	var fdir := d2.normalized() if moving else Vector3(0.0, 0.0, 1.0)
	var side_vec := Vector3(fdir.z, 0.0, -fdir.x)        # perpendicular, ground plane
	var touches: int = 1 if _reduce else 3
	var interval := DUR / float(touches + 1)
	_touch_t += dt
	if _touch_t >= interval:
		_touch_t -= interval
		_side = -_side
		if not _reduce:
			_spawn_tick(foot + fdir * FWD)               # warm-gold contact tick at the touch point
	var side_off := _side_off * _side * (0.5 if _reduce else 1.0)
	var bpos := foot + fdir * FWD + side_vec * side_off
	bpos.y = _ball_scale * 0.98                          # rest the small ball on the ground
	_ball.global_position = bpos
	if _have_last:
		var moved := Vector3(foot.x - _last_foot.x, 0.0, foot.z - _last_foot.z).length()
		if moved > 0.004:
			_moved_any = true
			_still = 0.0
			_roller.rotate(side_vec.normalized(), moved / maxf(0.06, _ball_scale))   # roll with travel
			_mark_t += dt
			if not _reduce and _mark_t >= 0.09 and _mark_len > 0.02:
				_mark_t = 0.0
				_spawn_mark(foot - fdir * 0.4, fdir)     # short cyan streak just BEHIND the body
		else:
			_still += dt
	_last_foot = foot
	_have_last = true
	# end: hard window, or the body clearly arrived (moved then went still), or never displaced (snap)
	if _t >= DUR or (_moved_any and _still >= 0.09) or (not _moved_any and _t >= 0.18):
		_finish(foot)

func _finish(foot: Vector3) -> void:
	_active = false
	_ball.visible = false
	_arrival.global_position = Vector3(foot.x, 0.14, foot.z)
	_arrival.scale = Vector3.ONE * _arrival_scale
	_arrival_mat.albedo_color = Color(_gold.r, _gold.g, _gold.b, 0.5 if _reduce else 0.9)
	_arrival.visible = true

# Immediate cleanup (fighter death/despawn/map change/reject) — no arrival ring.
func stop() -> void:
	_active = false
	_ball.visible = false
	_arrival.visible = false
	for tk in _ticks:
		tk["node"].visible = false
		tk["life"] = 0.0
	for mk in _marks:
		mk["node"].visible = false
		mk["life"] = 0.0
	visible = false
	set_process(false)

func is_active() -> bool:
	return _active

func _process(dt: float) -> void:
	var any := _active or _arrival.visible
	if _arrival.visible:                                 # arrival ring: brief expand + fade
		var s: float = _arrival.scale.x + dt * 2.2
		_arrival.scale = Vector3(s, s, s)
		var a: float = _arrival_mat.albedo_color.a - dt * 3.2
		if a <= 0.0:
			_arrival.visible = false
		else:
			_arrival_mat.albedo_color.a = a
	for tk in _ticks:                                    # contact ticks: quick pop + fade
		if tk["life"] > 0.0:
			any = true
			tk["t"] += dt
			var k: float = tk["t"] / tk["life"]
			if k >= 1.0:
				tk["node"].visible = false
				tk["life"] = 0.0
			else:
				var sc: float = 0.5 + k * 0.7
				tk["node"].scale = Vector3(sc, sc, sc)
				tk["mat"].albedo_color.a = 1.0 - k
	for mk in _marks:                                    # speed-marks: fade in place
		if mk["life"] > 0.0:
			any = true
			mk["t"] += dt
			var k2: float = mk["t"] / mk["life"]
			if k2 >= 1.0:
				mk["node"].visible = false
				mk["life"] = 0.0
			else:
				mk["mat"].albedo_color.a = (1.0 - k2) * 0.85
	if not any:
		visible = false
		set_process(false)

func _spawn_tick(at: Vector3) -> void:
	for tk in _ticks:
		if tk["life"] <= 0.0:
			tk["node"].global_position = Vector3(at.x, 0.25, at.z)
			tk["node"].scale = Vector3.ONE * 0.5
			tk["mat"].albedo_color = Color(_gold.r, _gold.g, _gold.b, 1.0)
			tk["node"].visible = true
			tk["t"] = 0.0
			tk["life"] = 0.16
			return

func _spawn_mark(at: Vector3, fdir: Vector3) -> void:
	for mk in _marks:
		if mk["life"] <= 0.0:
			mk["node"].global_position = Vector3(at.x, 0.03, at.z)
			mk["node"].scale = Vector3(_mark_len / MARK_BASE, 1.0, 1.0)   # tunable streak length
			mk["node"].rotation.y = atan2(-fdir.z, fdir.x)   # align the streak ALONG travel (bar long-axis = local +X)
			mk["mat"].albedo_color = Color(_cyan.r, _cyan.g, _cyan.b, 0.85)
			mk["node"].visible = true
			mk["t"] = 0.0
			mk["life"] = _mark_life
			return
