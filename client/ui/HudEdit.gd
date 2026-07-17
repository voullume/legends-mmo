class_name HudEdit
extends Control
## Configurable-HUD P3 — the HUD edit-mode overlay. Full-rect MOUSE_FILTER_STOP so editing
## clicks never reach gameplay (the paired keyboard gate lives in Client/NetClient: intent is
## zeroed like chat, panel keybinds swallowed). Modules show outlines + name tags; click
## selects, drag moves (with snap guides), the corner grip scales; a toolbar (built on the P1
## HudFrame pattern) offers profile presets, per-module scale/opacity/visible/lock/anchor and
## Apply / Cancel / Reset / Fit. Layout persists ONLY on apply/exit — never per mouse-motion.

const SNAP := 7.0
const GRIP := 18.0

var client: Node = null            # owning Client/NetClient (for hud_edit_on + toasts)

var _selected := ""
var _dragging := false
var _drag_off := Vector2.ZERO
var _scaling := false
var _scale_base := 1.0
var _scale_ref := 1.0
var _scale_origin := Vector2.ZERO   # rect origin FROZEN at grip-press: for non-top_left anchors the
									# live origin shifts as scale changes → measuring from it feeds back
var _pre_edit := {}                # id -> layout snapshot for Cancel
var _pre_profile := "default"
var _dirty := false
var _guides: Array = []            # active snap guide lines [[a,b], ...]

var _toolbar: Control = null
var _profile_opt: OptionButton = null
var _mod_row: HBoxContainer = null
var _mod_name: Label = null
var _scale_slider: HSlider = null
var _scale_val: Label = null
var _op_slider: HSlider = null
var _vis_check: CheckBox = null
var _lock_check: CheckBox = null
var _anchor_opt: OptionButton = null
var _variant_opt: OptionButton = null
var _status: Label = null

func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 3000                 # above panels/toasts, below the tooltip + disconnect overlay (4096)
	visible = false
	_build_toolbar()
	resized.connect(_center_toolbar)

func _ready() -> void:
	set_process(false)

# ---------------------------------------------------------------- open/close

func open() -> void:
	_pre_edit = {}
	for id in HudLayout.ids():
		_pre_edit[id] = HudLayout.layout(id)
	_pre_profile = HudLayout.profile()
	_dirty = false
	_selected = ""
	_sync_profile_opt()
	_sync_mod_row()
	HudLayout.set_preview(true)
	# GUI mouse picking is tree-order, not z_index — become the LAST _hud child so later-added
	# siblings (transient popups, lazily-registered module wrappers) can't steal edit clicks.
	if get_parent() != null:
		get_parent().move_child(self, get_parent().get_child_count() - 1)
	visible = true
	set_process(true)
	_center_toolbar()
	if client != null:
		client.set("hud_edit_on", true)

# save=true → persist current layouts; save=false → restore the pre-edit snapshot.
func close(save: bool) -> void:
	_end_ops()
	if save:
		HudLayout.save()
	else:
		for id in _pre_edit:
			HudLayout.restore_layout(id, _pre_edit[id])
		HudLayout.set_profile_label(_pre_profile)
	HudLayout.set_preview(false)
	visible = false
	set_process(false)
	if client != null:
		client.set("hud_edit_on", false)

# Esc: cancel an in-flight drag/scale first (returns true = consumed); else let the caller close.
func handle_escape() -> bool:
	if _dragging or _scaling:
		_end_ops()
		return true
	return false

func _end_ops() -> void:
	if _dragging and _selected != "":
		HudLayout.clamp_module(_selected)
	_dragging = false
	_scaling = false
	_guides = []

func _process(_dt: float) -> void:
	queue_redraw()                 # rects track live module sizes; edit mode only, bounded work

# ---------------------------------------------------------------- interaction

func _hit_module(p: Vector2) -> String:
	var idlist: Array = HudLayout.ids()
	idlist.reverse()
	for id in idlist:
		if HudLayout.rect(id).grow(2.0).has_point(p):
			return id
	return ""

func _grip_rect(id: String) -> Rect2:
	var r := HudLayout.rect(id)
	return Rect2(r.end - Vector2(GRIP, GRIP), Vector2(GRIP + 4.0, GRIP + 4.0))

func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			if ev.pressed:
				var p: Vector2 = ev.position
				if _selected != "" and _grip_rect(_selected).has_point(p) and not _locked(_selected):
					_scaling = true
					_scale_base = float(HudLayout.layout(_selected)["scale"])
					_scale_origin = HudLayout.rect(_selected).position
					_scale_ref = maxf(24.0, (p - _scale_origin).length())
				else:
					var hit := _hit_module(p)
					_selected = hit
					_sync_mod_row()
					if hit != "" and not _locked(hit):
						_dragging = true
						_drag_off = p - HudLayout.rect(hit).position
			else:
				_end_ops()
		accept_event()                 # ALL buttons (RMB, wheel) die here — no camera input mid-edit
	elif ev is InputEventMouseMotion:
		if _dragging and _selected != "":
			var target: Vector2 = ev.position - _drag_off
			target = _snap(target, HudLayout.rect(_selected).size)
			HudLayout.set_position_from_rect(_selected, target)
			_mark_dirty()
		elif _scaling and _selected != "":
			var d: float = maxf(24.0, ((ev.position as Vector2) - _scale_origin).length())
			var m: Dictionary = HudLayout.info(_selected)
			var s := clampf(_scale_base * d / _scale_ref, float(m["min_s"]), float(m["max_s"]))
			HudLayout.set_field(_selected, "scale", snappedf(s, 0.05))
			_sync_mod_row()
			_mark_dirty()
		accept_event()

func _locked(id: String) -> bool:
	return bool(HudLayout.layout(id).get("locked", false))

func _mark_dirty() -> void:
	_dirty = true
	HudLayout.mark_custom()
	_sync_profile_opt()

# Snap the dragged rect to viewport center lines, safe-area edges and other modules' edges.
func _snap(pos: Vector2, sz: Vector2) -> Vector2:
	_guides = []
	var vp := size
	var xs := [HudLayout.SAFE, vp.x * 0.5 - sz.x * 0.5, vp.x - sz.x - HudLayout.SAFE]
	var ys := [HudLayout.SAFE, vp.y * 0.5 - sz.y * 0.5, vp.y - sz.y - HudLayout.SAFE]
	for id in HudLayout.ids():
		if id == _selected:
			continue
		var r := HudLayout.rect(id)
		xs.append_array([r.position.x, r.end.x - sz.x, r.end.x, r.position.x - sz.x])
		ys.append_array([r.position.y, r.end.y - sz.y, r.end.y, r.position.y - sz.y])
	for x in xs:
		if absf(pos.x - float(x)) <= SNAP:
			pos.x = float(x)
			_guides.append([Vector2(pos.x, 0), Vector2(pos.x, vp.y)])
			break
	for y in ys:
		if absf(pos.y - float(y)) <= SNAP:
			pos.y = float(y)
			_guides.append([Vector2(0, pos.y), Vector2(vp.x, pos.y)])
			break
	return pos

# ---------------------------------------------------------------- drawing

func _draw() -> void:
	var vp := size
	# dim veil + safe area + center guides
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.0, 0.02, 0.05, 0.25))
	var safe := Rect2(Vector2(HudLayout.SAFE, HudLayout.SAFE), vp - Vector2(HudLayout.SAFE * 2.0, HudLayout.SAFE * 2.0))
	draw_rect(safe, Color(Palette.SB_CYAN, 0.22), false, 1.0)
	draw_dashed_line(Vector2(vp.x * 0.5, 0), Vector2(vp.x * 0.5, vp.y), Color(Palette.SB_CYAN, 0.12), 1.0, 8.0)
	draw_dashed_line(Vector2(0, vp.y * 0.5), Vector2(vp.x, vp.y * 0.5), Color(Palette.SB_CYAN, 0.12), 1.0, 8.0)
	# active snap guides
	for g in _guides:
		draw_line(g[0], g[1], Color(Palette.SB_LIME, 0.5), 1.0)
	# overlap detection (visible modules only)
	var overlapping := {}
	var idlist: Array = HudLayout.ids()
	for i in idlist.size():
		for j in range(i + 1, idlist.size()):
			var la: Dictionary = HudLayout.layout(idlist[i])
			var lb: Dictionary = HudLayout.layout(idlist[j])
			if bool(la.get("visible", true)) and bool(lb.get("visible", true)) \
					and HudLayout.rect(idlist[i]).intersects(HudLayout.rect(idlist[j])):
				overlapping[idlist[i]] = true
				overlapping[idlist[j]] = true
	var font := get_theme_default_font()
	for id in idlist:
		var r := HudLayout.rect(id)
		var lay := HudLayout.layout(id)
		var hidden := not bool(lay.get("visible", true))
		var col: Color = Palette.SB_LIME if id == _selected else Palette.SB_CYAN
		if overlapping.has(id):
			col = Palette.SB_ORANGE
		if bool(lay.get("locked", false)):
			col = Color(0.55, 0.6, 0.68)
		if hidden:
			for side in 4:
				var a := r.position
				var b := r.position
				match side:
					0: b = Vector2(r.end.x, r.position.y)
					1:
						a = Vector2(r.end.x, r.position.y)
						b = r.end
					2:
						a = r.end
						b = Vector2(r.position.x, r.end.y)
					3:
						a = Vector2(r.position.x, r.end.y)
						b = r.position
				draw_dashed_line(a, b, Color(col, 0.5), 1.0, 6.0)
		else:
			draw_rect(r, Color(col, 0.10))
			draw_rect(r, Color(col, 0.9), false, 2.0)
		# name tag
		var m: Dictionary = HudLayout.info(id)
		var tag: String = str(m.get("label", id)) + (" (hidden)" if hidden else "") \
			+ (" (locked)" if bool(lay.get("locked", false)) else "") + ("  %d%%" % int(round(float(lay["scale"]) * 100.0)))
		var ts := font.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		var tp := Vector2(r.position.x, maxf(16.0, r.position.y - 6.0))
		draw_rect(Rect2(tp - Vector2(3, 13), ts + Vector2(6, 4)), Color(Palette.SB_INK, 0.85))
		draw_string(font, tp, tag, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(col, 1.0))
		# scale grip on the selected module
		if id == _selected and not bool(lay.get("locked", false)):
			var gr := _grip_rect(id)
			var tri := PackedVector2Array([gr.end, gr.end - Vector2(GRIP, 0), gr.end - Vector2(0, GRIP)])
			draw_colored_polygon(tri, Color(Palette.SB_LIME, 0.85))

# ---------------------------------------------------------------- toolbar

func _build_toolbar() -> void:
	# a STOP wrapper sized to the VISIBLE frame only — a full-width strip would silently eat
	# clicks on modules parked along the top edge (the default player frame lives there)
	_toolbar = Control.new()
	_toolbar.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_toolbar)
	var frame_d: Dictionary = HudFrame.boxed(HudFrame.Tier.PANEL, {"header": true})
	var frame: Control = frame_d["frame"]
	_toolbar.add_child(frame)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	(frame_d["body"] as MarginContainer).add_child(vb)
	# keep the frame sized to its content, the hit-wrapper hugging the frame, both centered
	vb.resized.connect(func() -> void:
		var mg: Dictionary = (frame as HudFrame).margins()
		frame.size = vb.size + Vector2(float(mg["l"]) + float(mg["r"]), float(mg["t"]) + float(mg["b"]))
		frame.position = Vector2.ZERO
		_toolbar.size = frame.size
		_center_toolbar())

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	vb.add_child(top)
	var title := HudFonts.display_label("HUD Layout", 15, Palette.SB_CYAN, 0.16)
	top.add_child(title)
	_profile_opt = OptionButton.new()
	_profile_opt.focus_mode = Control.FOCUS_NONE
	for p in HudLayout.profile_names():
		_profile_opt.add_item(str(p).capitalize())
	_profile_opt.item_selected.connect(func(idx: int) -> void:
		var name := str(HudLayout.profile_names()[idx])
		HudLayout.apply_profile(name)
		_dirty = true
		_sync_mod_row())
	top.add_child(_profile_opt)
	top.add_child(_tb_btn("Apply", func() -> void:
		HudLayout.save()
		_pre_edit = {}
		for id in HudLayout.ids():
			_pre_edit[id] = HudLayout.layout(id)
		_pre_profile = HudLayout.profile()
		_dirty = false
		_status.text = "Saved."))
	top.add_child(_tb_btn("Cancel", func() -> void: close(false)))
	top.add_child(_tb_btn("Reset All", func() -> void:
		HudLayout.reset_all()
		_mark_dirty()
		_sync_profile_opt()
		_sync_mod_row()))
	var fit_btn := _tb_btn("Rescue Off-Screen", func() -> void:
		var moved := 0
		for id in HudLayout.ids():
			var before := HudLayout.rect(id).position
			HudLayout.clamp_module(id)
			if not HudLayout.rect(id).position.is_equal_approx(before):
				moved += 1
		if moved > 0:
			_mark_dirty()
			_status.text = "%d module%s pulled back on-screen." % [moved, "" if moved == 1 else "s"]
		else:
			_status.text = "Nothing was off-screen.")
	fit_btn.tooltip_text = "Pull any module that ended up outside the window back into view"
	top.add_child(fit_btn)
	_status = Label.new()
	_status.text = "Drag modules · corner grip scales · Esc saves + exits"
	_status.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_status.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(_status)

	_mod_row = HBoxContainer.new()
	_mod_row.add_theme_constant_override("separation", 8)
	_mod_row.visible = false
	vb.add_child(_mod_row)
	_mod_name = Label.new()
	_mod_name.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	_mod_name.add_theme_color_override("font_color", Palette.SB_LIME)
	_mod_row.add_child(_mod_name)
	_scale_slider = HSlider.new()
	_scale_slider.min_value = HudLayout.SCALE_MIN
	_scale_slider.max_value = HudLayout.SCALE_MAX
	_scale_slider.step = 0.05
	_scale_slider.custom_minimum_size = Vector2(120, 0)
	_scale_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_scale_slider.focus_mode = Control.FOCUS_NONE
	_scale_slider.value_changed.connect(func(v: float) -> void:
		if _selected != "":
			HudLayout.set_field(_selected, "scale", v)
			_scale_val.text = "%d%%" % int(round(v * 100.0))
			_mark_dirty())
	_mod_row.add_child(_scale_slider)
	_scale_val = Label.new()
	_scale_val.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_mod_row.add_child(_scale_val)
	for preset in [["S", 0.8], ["M", 1.0], ["L", 1.25]]:
		var pv: float = preset[1]
		_mod_row.add_child(_tb_btn(str(preset[0]), func() -> void:
			if _selected != "":
				HudLayout.set_field(_selected, "scale", pv)
				_sync_mod_row()
				_mark_dirty()))
	var oplbl := Label.new()
	oplbl.text = "Opacity"
	oplbl.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	oplbl.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_mod_row.add_child(oplbl)
	_op_slider = HSlider.new()
	_op_slider.min_value = HudLayout.OPACITY_MIN
	_op_slider.max_value = 1.0
	_op_slider.step = 0.05
	_op_slider.custom_minimum_size = Vector2(80, 0)
	_op_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_op_slider.focus_mode = Control.FOCUS_NONE
	_op_slider.value_changed.connect(func(v: float) -> void:
		if _selected != "":
			HudLayout.set_field(_selected, "opacity", v)
			_mark_dirty())
	_mod_row.add_child(_op_slider)
	_vis_check = CheckBox.new()
	_vis_check.text = "Visible"
	_vis_check.focus_mode = Control.FOCUS_NONE
	_vis_check.toggled.connect(func(on: bool) -> void:
		if _selected != "":
			HudLayout.set_field(_selected, "visible", on)
			_mark_dirty())
	_mod_row.add_child(_vis_check)
	_lock_check = CheckBox.new()
	_lock_check.text = "Lock"
	_lock_check.focus_mode = Control.FOCUS_NONE
	_lock_check.toggled.connect(func(on: bool) -> void:
		if _selected != "":
			HudLayout.set_field(_selected, "locked", on)
			_mark_dirty())
	_mod_row.add_child(_lock_check)
	_anchor_opt = OptionButton.new()
	_anchor_opt.focus_mode = Control.FOCUS_NONE
	_anchor_opt.tooltip_text = "Snap the module to a screen corner/edge/center (drag afterwards to fine-tune)"
	for a in HudLayout.ANCHORS:
		_anchor_opt.add_item(str(a))
	_anchor_opt.item_selected.connect(func(idx: int) -> void:
		if _selected != "":
			# snap TO the picked anchor (visible, what players expect) — dragging afterwards
			# stores the offset relative to it, which is what survives resolution changes
			var aname := str(HudLayout.ANCHORS.keys()[idx])
			HudLayout.set_field(_selected, "anchor", aname)
			HudLayout.snap_to_anchor(_selected)
			_mark_dirty())
	_mod_row.add_child(_anchor_opt)
	_variant_opt = OptionButton.new()             # layout variant (only for modules that declare them)
	_variant_opt.focus_mode = Control.FOCUS_NONE
	_variant_opt.item_selected.connect(func(idx: int) -> void:
		if _selected == "":
			return
		var vl: Array = HudLayout.info(_selected).get("variants", [])
		if idx >= 0 and idx < vl.size():
			HudLayout.set_field(_selected, "variant", str(vl[idx]))
			_mark_dirty())
	_mod_row.add_child(_variant_opt)
	_mod_row.add_child(_tb_btn("Reset", func() -> void:
		if _selected != "":
			HudLayout.reset_module(_selected)
			_sync_mod_row()
			_mark_dirty()))

func _center_toolbar() -> void:
	if _toolbar != null:
		_toolbar.position = Vector2(maxf(0.0, (size.x - _toolbar.size.x) * 0.5), 8.0)

func _tb_btn(text: String, fn: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(fn)
	return b

func _sync_profile_opt() -> void:
	var names: Array = HudLayout.profile_names()
	var idx := names.find(HudLayout.profile())
	if idx >= 0:
		_profile_opt.select(idx)

func _sync_mod_row() -> void:
	if _selected == "" or not HudLayout.has(_selected):
		_mod_row.visible = false
		return
	_mod_row.visible = true
	var m: Dictionary = HudLayout.info(_selected)
	var lay: Dictionary = HudLayout.layout(_selected)
	_mod_name.text = str(m["label"])
	_scale_slider.min_value = float(m["min_s"])
	_scale_slider.max_value = float(m["max_s"])
	_scale_slider.set_value_no_signal(float(lay["scale"]))
	_scale_val.text = "%d%%" % int(round(float(lay["scale"]) * 100.0))
	_op_slider.set_value_no_signal(float(lay["opacity"]))
	_vis_check.set_pressed_no_signal(bool(lay["visible"]))
	_lock_check.set_pressed_no_signal(bool(lay["locked"]))
	var aidx: int = HudLayout.ANCHORS.keys().find(str(lay["anchor"]))
	if aidx >= 0:
		_anchor_opt.select(aidx)
	var vl: Array = m.get("variants", [])
	_variant_opt.visible = not vl.is_empty()
	if not vl.is_empty():
		_variant_opt.clear()
		for vv in vl:
			_variant_opt.add_item(str(vv).capitalize())
		var vidx: int = vl.find(str(lay["variant"]))
		if vidx >= 0:
			_variant_opt.select(vidx)
