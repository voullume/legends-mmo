# Client-only CHARGE wind-up for the Striker Golden Goal (the interruptible 0.4 s cast). Pooled. The
# client positions it on a fighter the server reports as casting Golden Goal (castKey) and drives it every
# frame with the authoritative remaining/total → progress; concentric gold rings converge inward and
# brighten as the charge completes. It NEVER spawns a projectile and disappears cleanly the instant the
# cast ends (release OR stun interrupt), because the client simply stops seeing the cast. reduce_fx →
# one subdued ring.
extends Node3D

var _rings := []             # [{node, mat, base}]
var _color := Color(1.0, 0.82, 0.32)

func configure(style: Dictionary) -> void:
	_color = style.get("trail_color", _color)
	for r in _rings:
		var a: float = (r["mat"] as StandardMaterial3D).albedo_color.a
		r["mat"].albedo_color = Color(_color.r, _color.g, _color.b, a)

func _ready() -> void:
	for i in range(3):
		var mi := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.30
		tm.outer_radius = 0.38
		mi.mesh = tm
		mi.rotation.x = deg_to_rad(90.0)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_color = Color(_color.r, _color.g, _color.b, 0.0)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_rings.append({"node": mi, "mat": m, "base": 0.55 + i * 0.32})
	visible = false

# progress 0 (cast start) → 1 (about to release). Driven every frame by the client while casting.
func set_charge(progress: float, reduce: bool) -> void:
	var p: float = clampf(progress, 0.0, 1.0)
	visible = true
	for i in range(_rings.size()):
		var r = _rings[i]
		var s: float = (1.5 - p * 1.12) * float(r["base"])   # converge inward as the charge builds
		r["node"].scale = Vector3(s, s, s)
		r["node"].visible = (i == 0) or not reduce           # reduce_fx: a single subdued ring
		var a: float = (0.15 + p * 0.7) * (0.45 if reduce else 1.0)
		r["mat"].albedo_color.a = a

func hide_charge() -> void:
	visible = false
