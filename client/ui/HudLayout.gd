class_name HudLayout
extends RefCounted
## Configurable-HUD P2 — the module registry + layout store. Composition, not inheritance: an
## existing HUD node (vitals stack, hotbar, quest tracker, …) is wrapped in a plain Control that
## owns PLAYER-facing layout (anchored position, scale, opacity, visibility, lock) while the
## legacy node keeps all game behavior (its own visibility rules, data updates, input). Layouts
## persist to the shared user://settings.cfg ([hud] + [hud_modules] sections — every writer here
## load-then-saves so [audio]/[fx]/[build]/[windows] survive untouched). The HUD never touches
## authoritative data: this is presentation state only, saved locally, never in Supabase.

const VERSION := 1
const SCALE_MIN := 0.6
const SCALE_MAX := 1.6
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.5
const OPACITY_MIN := 0.25
const SAFE := 4.0                      # px kept between a module and the viewport edge

# 9-way anchor grid: module positions are stored relative to one of these normalized points, so
# a saved layout keeps its INTENT (e.g. "just above bottom-center") across resolutions.
const ANCHORS := {
	"top_left": Vector2(0.0, 0.0), "top_center": Vector2(0.5, 0.0), "top_right": Vector2(1.0, 0.0),
	"center_left": Vector2(0.0, 0.5), "center": Vector2(0.5, 0.5), "center_right": Vector2(1.0, 0.5),
	"bottom_left": Vector2(0.0, 1.0), "bottom_center": Vector2(0.5, 1.0), "bottom_right": Vector2(1.0, 1.0),
}

const LAYOUT_DEFAULTS := {"anchor": "top_left", "nx": 0.0, "ny": 0.0, "ox": 0.0, "oy": 0.0,
	"scale": 1.0, "opacity": 1.0, "visible": true, "locked": false, "variant": "standard"}

# Built-in profiles = per-module overrides on top of each module's registered defaults. Data
# only — same module system, no duplicated HUD implementations. "custom" = whatever the player
# saved (never reseeded). New modules picked up by later phases just add entries here.
const PROFILES := {
	"default": {},
	"minimal": {
		"player_frame": {"scale": 0.85, "opacity": 0.85, "variant": "bars"},
		"hotbar": {"scale": 0.9, "opacity": 0.9},
		"quest_tracker": {"visible": false},
	},
	"combat": {
		"player_frame": {"scale": 1.1},
		"hotbar": {"scale": 1.15},
		"quest_tracker": {"scale": 0.8, "opacity": 0.8},
	},
	"exploration": {
		"player_frame": {"scale": 0.9, "variant": "compact"},
		"hotbar": {"scale": 0.85},
		"quest_tracker": {"scale": 1.15},
	},
	"compact": {
		"player_frame": {"scale": 0.75, "ox": 8.0, "oy": 6.0, "variant": "compact"},
		"hotbar": {"scale": 0.8, "oy": -64.0},
		"quest_tracker": {"scale": 0.8, "ox": -8.0, "oy": 120.0},
	},
}

static var cfg_path := "user://settings.cfg"   # redirectable so the test harness never touches real settings
static var _modules := {}                      # id -> {wrapper, node, label, defaults, min_s, max_s, ref_size, preview, layout}
static var _order := []                        # registration order (stable edit-mode listing)
static var _profile := "default"
static var _vp: Viewport = null
static var _vp_cb := Callable()                # the size_changed hook (disconnected on registry reset)
static var _loaded := false

# ---------------------------------------------------------------- lifecycle

# A fresh Client (_build_hud) starts a clean registry — the previous session's wrappers died
# with the old scene tree (same pruning problem Widgets._windows has; we reset instead). The
# root viewport SURVIVES reload_current_scene, so the resize hook must be detached explicitly
# or relogins would stack one stale connection per session.
static func reset_registry() -> void:
	if _vp != null and _vp_cb.is_valid() and _vp.size_changed.is_connected(_vp_cb):
		_vp.size_changed.disconnect(_vp_cb)
	_modules = {}
	_order = []
	_vp = null
	_vp_cb = Callable()
	_loaded = false

static func register(id: String, node: Control, opts: Dictionary = {}) -> Control:
	if _modules.has(id) or node == null or node.get_parent() == null:
		push_warning("HudLayout: bad register '%s'" % id)
		return null
	_load_cfg_state()
	var parent := node.get_parent()
	var wrapper := Control.new()
	wrapper.name = "HudMod_" + id
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(wrapper)
	# keep the node's stacking slot so z-order vs its z=0 siblings doesn't change
	if node is CanvasItem and parent is Node:
		parent.move_child(wrapper, node.get_index())
	node.reparent(wrapper)
	node.position = Vector2.ZERO
	var m := {
		"wrapper": wrapper, "node": node,
		"label": str(opts.get("label", id.capitalize())),
		"defaults": LAYOUT_DEFAULTS.merged(opts.get("defaults", {}), true),
		"min_s": float(opts.get("min_scale", SCALE_MIN)),
		"max_s": float(opts.get("max_scale", SCALE_MAX)),
		"ref_size": opts.get("ref_size", Vector2(160, 60)),
		"preview": opts.get("preview", Callable()),
		"variants": opts.get("variants", []),      # e.g. ["standard","compact","bars"]
		"on_variant": opts.get("on_variant", Callable()),   # rebuilds module content for a variant
		"last_variant": "",                        # "" → the stored variant is applied on register
		"layout": {},
	}
	_modules[id] = m
	_order.append(id)
	m["layout"] = _stored_layout(id)
	node.resized.connect(func() -> void: _sync(id))
	if _vp == null:
		_vp = wrapper.get_viewport()
		if _vp != null:
			_vp_cb = apply_all      # first-class static func → a disconnectable Callable
			_vp.size_changed.connect(_vp_cb)
	_sync(id)
	return wrapper

static func ids() -> Array:
	return _order.duplicate()

static func has(id: String) -> bool:
	return _modules.has(id)

static func info(id: String) -> Dictionary:
	return _modules.get(id, {})

static func layout(id: String) -> Dictionary:
	if not _modules.has(id):
		return {}
	return (_modules[id]["layout"] as Dictionary).duplicate()

static func profile() -> String:
	_load_cfg_state()
	return _profile

# ---------------------------------------------------------------- placement math

static func _viewport_size() -> Vector2:
	if _vp != null:
		return _vp.get_visible_rect().size
	return Vector2(1600, 900)

# The stored layout pins the module's anchor-matching corner to:
#   anchor_point + (nx,ny)·viewport + (ox,oy)
static func _sync(id: String) -> void:
	if not _modules.has(id):
		return
	var m: Dictionary = _modules[id]
	var wrapper: Control = m["wrapper"]
	var node: Control = m["node"]
	if not is_instance_valid(wrapper) or not is_instance_valid(node):
		return
	var lay: Dictionary = m["layout"]
	var vname := str(lay["variant"])
	if str(m.get("last_variant", "")) != vname:    # variant changed → let the module rebuild its
		m["last_variant"] = vname                  # content (size settles via node.resized → re-sync)
		var vcb: Callable = m.get("on_variant", Callable())
		if vcb.is_valid():
			vcb.call(vname)
	wrapper.size = node.size
	var s := clampf(float(lay["scale"]), float(m["min_s"]), float(m["max_s"]))
	wrapper.scale = Vector2(s, s)
	var vp := _viewport_size()
	var an: Vector2 = ANCHORS.get(str(lay["anchor"]), Vector2.ZERO)
	var target := Vector2(an.x * vp.x + float(lay["nx"]) * vp.x + float(lay["ox"]),
		an.y * vp.y + float(lay["ny"]) * vp.y + float(lay["oy"]))
	wrapper.position = target - an * (node.size * s)
	wrapper.modulate.a = clampf(float(lay["opacity"]), OPACITY_MIN, 1.0)
	wrapper.visible = bool(lay["visible"])

static func apply_all() -> void:
	for id in _order:
		_sync(id)

# The module's on-screen rect (scaled) — edit-mode handles, clamping and overlap checks use this.
static func rect(id: String) -> Rect2:
	if not _modules.has(id):
		return Rect2()
	var m: Dictionary = _modules[id]
	var wrapper: Control = m["wrapper"]
	var node: Control = m["node"]
	var sz: Vector2 = node.size
	if sz.x < 2.0 or sz.y < 2.0:
		sz = m["ref_size"]
	return Rect2(wrapper.position, sz * wrapper.scale.x)

# Re-derive (anchor-relative) storage from a desired top-left screen position (drag end).
# Movement is stored normalized (nx/ny) with zeroed pixel offsets, so a dragged layout keeps its
# proportional position across resolutions (defaults ship pixel offsets instead — hand-tuned).
static func set_position_from_rect(id: String, top_left: Vector2) -> void:
	if not _modules.has(id):
		return
	var m: Dictionary = _modules[id]
	var lay: Dictionary = m["layout"]
	var vp := _viewport_size()
	var an: Vector2 = ANCHORS.get(str(lay["anchor"]), Vector2.ZERO)
	var r := rect(id)
	var anchor_pt := top_left + an * r.size
	lay["nx"] = (anchor_pt.x - an.x * vp.x) / maxf(1.0, vp.x)
	lay["ny"] = (anchor_pt.y - an.y * vp.y) / maxf(1.0, vp.y)
	lay["ox"] = 0.0
	lay["oy"] = 0.0
	_sync(id)

static func set_field(id: String, field: String, value: Variant) -> void:
	if not _modules.has(id):
		return
	var m: Dictionary = _modules[id]
	(m["layout"] as Dictionary)[field] = value
	m["layout"] = _sanitize(m["layout"], m)
	_sync(id)

static func reset_module(id: String) -> void:
	if not _modules.has(id):
		return
	var m: Dictionary = _modules[id]
	m["layout"] = (m["defaults"] as Dictionary).duplicate()
	_sync(id)

static func reset_all() -> void:
	for id in _order:
		reset_module(id)
	_profile = "default"

# Snap a module flush to its stored anchor point (small edge inset) — the edit-mode anchor
# picker's visible action. Offsets reset to the inset so the intent survives resolution changes.
static func snap_to_anchor(id: String) -> void:
	if not _modules.has(id):
		return
	var lay: Dictionary = (_modules[id]["layout"] as Dictionary)
	var an: Vector2 = ANCHORS.get(str(lay["anchor"]), Vector2.ZERO)
	var inset := 12.0
	lay["nx"] = 0.0
	lay["ny"] = 0.0
	lay["ox"] = inset if an.x == 0.0 else (-inset if an.x == 1.0 else 0.0)
	lay["oy"] = inset if an.y == 0.0 else (-inset if an.y == 1.0 else 0.0)
	_sync(id)

# Clamp a module fully on screen (never lose a module off-screen; oversized modules pin to 0).
static func clamp_module(id: String) -> void:
	if not _modules.has(id):
		return
	var r := rect(id)
	var vp := _viewport_size()
	var p := Vector2(clampf(r.position.x, SAFE, maxf(SAFE, vp.x - r.size.x - SAFE)),
		clampf(r.position.y, SAFE, maxf(SAFE, vp.y - r.size.y - SAFE)))
	if not p.is_equal_approx(r.position):
		set_position_from_rect(id, p)

static func fit_all_to_screen() -> void:
	for id in _order:
		clamp_module(id)

# ---------------------------------------------------------------- profiles

static func profile_names() -> Array:
	var names := PROFILES.keys()
	names.append("custom")
	return names

static func apply_profile(name: String) -> void:
	_profile = name
	if name == "custom" or not PROFILES.has(name):
		return
	var over: Dictionary = PROFILES[name]
	for id in _order:
		var m: Dictionary = _modules[id]
		m["layout"] = _sanitize((m["defaults"] as Dictionary).merged(over.get(id, {}), true), m)
		_sync(id)

static func mark_custom() -> void:
	_profile = "custom"

static func set_profile_label(name: String) -> void:
	_profile = name

# Restore an externally-held layout snapshot (edit-mode Cancel) — sanitized, never reseeded.
static func restore_layout(id: String, lay: Dictionary) -> void:
	if not _modules.has(id):
		return
	var m: Dictionary = _modules[id]
	m["layout"] = _sanitize(lay, m)
	_sync(id)

# ---------------------------------------------------------------- persistence

static func _sanitize(raw: Variant, m: Dictionary) -> Dictionary:
	var d: Dictionary = (m["defaults"] as Dictionary)
	var out := d.duplicate()
	if raw is Dictionary:
		for k in LAYOUT_DEFAULTS:
			if not (raw as Dictionary).has(k):
				continue
			var v: Variant = raw[k]
			match k:
				"anchor":
					if ANCHORS.has(str(v)):
						out[k] = str(v)
				"variant":
					var vl: Array = m.get("variants", [])
					if vl.is_empty() or vl.has(str(v)):   # unknown variant → module default
						out[k] = str(v)
				"visible", "locked":
					if v is bool:            # bool(<String>) is a nonexistent constructor — guard
						out[k] = v           # typed like the numeric fields so corrupt entries
					elif v is int or v is float:   # default instead of aborting _sanitize
						out[k] = (float(v) != 0.0)
				"scale":
					if v is float or v is int:
						out[k] = clampf(float(v), float(m["min_s"]), float(m["max_s"]))
				"opacity":
					if v is float or v is int:
						out[k] = clampf(float(v), OPACITY_MIN, 1.0)
				"nx", "ny":
					if v is float or v is int:
						out[k] = clampf(float(v), -1.5, 1.5)
				"ox", "oy":
					if v is float or v is int:
						out[k] = clampf(float(v), -8192.0, 8192.0)
	return out

static func _stored_layout(id: String) -> Dictionary:
	var m: Dictionary = _modules[id]
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return (m["defaults"] as Dictionary).duplicate()
	var base: Dictionary = (m["defaults"] as Dictionary).merged(
		(PROFILES.get(_profile, {}) as Dictionary).get(id, {}), true)
	if not cfg.has_section_key("hud_modules", id):
		return _sanitize(base, m)
	# stored layout wins over the profile seed; _sanitize defaults any missing/corrupt field
	return _sanitize(cfg.get_value("hud_modules", id), m)

static func _load_cfg_state() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return
	var ver := int(cfg.get_value("hud", "layout_version", VERSION))
	if ver > VERSION:
		push_warning("HudLayout: layout_version %d is newer than supported %d — reading defensively" % [ver, VERSION])
	var p := str(cfg.get_value("hud", "profile", "default"))
	if PROFILES.has(p) or p == "custom":
		_profile = p

# Save current layouts. Called on Apply / edit-mode exit ONLY — never per mouse-motion.
static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)                 # keep [audio]/[fx]/[build]/[windows] + unknown module keys
	cfg.set_value("hud", "layout_version", VERSION)
	cfg.set_value("hud", "profile", _profile)
	for id in _order:
		cfg.set_value("hud_modules", id, (_modules[id]["layout"] as Dictionary).duplicate())
	cfg.save(cfg_path)

# Wipe ONLY the HUD layout store (Settings "Reset HUD Layout") — audio/fx/windows survive.
static func erase_saved() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) == OK:
		if cfg.has_section("hud_modules"):
			cfg.erase_section("hud_modules")
		if cfg.has_section("hud"):
			cfg.set_value("hud", "profile", "default")
		cfg.save(cfg_path)
	reset_all()

# ---------------------------------------------------------------- global UI scale

static func load_ui_scale() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return 1.0
	return clampf(float(cfg.get_value("hud", "ui_scale", 1.0)), UI_SCALE_MIN, UI_SCALE_MAX)

static func set_ui_scale(f: float, window: Window) -> float:
	f = clampf(snappedf(f, 0.05), UI_SCALE_MIN, UI_SCALE_MAX)
	if window != null:
		window.content_scale_factor = f
	var cfg := ConfigFile.new()
	cfg.load(cfg_path)
	cfg.set_value("hud", "layout_version", VERSION)
	cfg.set_value("hud", "ui_scale", f)
	cfg.save(cfg_path)
	return f

# Edit-mode preview hook: modules with sparse/empty live data (quest tracker with no quests)
# inject placeholder content so the player can still see and place the frame.
static func set_preview(on: bool) -> void:
	for id in _order:
		var cb: Callable = _modules[id]["preview"]
		if cb.is_valid():
			cb.call(on)
