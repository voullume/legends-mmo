extends PanelContainer
## Dev-only LIVE tuner for the keyed skill VFX (toggle: F3 in dev/practice, or --vfxtune). Client-only,
## zero gameplay effect. A style dropdown lists EVERY tunable skill (Client._vfx_tune) — projectiles AND
## the Dribble dash — and shows the slider set for that skill's KIND (projectiles share one set; the dash
## has its own). Each slider writes into Client._vfx_tune[style], reconfigures the live VFX of that style,
## and persists to user://settings.cfg [vfx_<class>_<key>]. Bake a value into Client.DEFAULT_VFX_TUNE to
## ship it. Values print to the console on every change so they're easy to copy back.
const AudioManager := preload("res://client/AudioManager.gd")

const SPECS := {
	"projectile": [
		{"key": "scale",        "min": 0.20, "max": 0.90, "step": 0.01, "name": "Ball size"},
		{"key": "spin_speed",   "min": 0.0,  "max": 30.0, "step": 0.5,  "name": "Spin speed"},
		{"key": "trail_life",   "min": 0.0,  "max": 0.50, "step": 0.01, "name": "Trail length"},
		{"key": "trail_width",  "min": 0.04, "max": 0.40, "step": 0.01, "name": "Trail width"},
		{"key": "trail_r",      "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Trail R"},
		{"key": "trail_g",      "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Trail G"},
		{"key": "trail_b",      "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Trail B"},
		{"key": "impact_scale", "min": 0.30, "max": 2.50, "step": 0.05, "name": "Impact size"},
		{"key": "impact_life",  "min": 0.10, "max": 0.60, "step": 0.02, "name": "Impact life"},
	],
	"dash": [
		{"key": "ball_scale",    "min": 0.12, "max": 0.50, "step": 0.01, "name": "Ball size"},
		{"key": "side",          "min": 0.0,  "max": 0.60, "step": 0.02, "name": "Touch offset"},
		{"key": "mark_len",      "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Streak length"},
		{"key": "mark_life",     "min": 0.05, "max": 0.50, "step": 0.02, "name": "Streak fade"},
		{"key": "arrival_scale", "min": 0.30, "max": 2.0,  "step": 0.05, "name": "Arrival ring"},
		{"key": "gold_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ring R"},
		{"key": "gold_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ring G"},
		{"key": "gold_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ring B"},
		{"key": "cyan_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Streak R"},
		{"key": "cyan_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Streak G"},
		{"key": "cyan_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Streak B"},
	],
	"melee": [
		{"key": "card_scale",    "min": 0.40, "max": 2.5,  "step": 0.05, "name": "Card size"},
		{"key": "star_scale",    "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Star size"},
		{"key": "contact_scale", "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Contact size"},
		{"key": "orbit_r",       "min": 0.20, "max": 1.2,  "step": 0.02, "name": "Orbit radius"},
		{"key": "card_height",   "min": 1.0,  "max": 6.0,  "step": 0.1,  "name": "Card height"},
		{"key": "card_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Card R"},
		{"key": "card_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Card G"},
		{"key": "card_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Card B"},
		{"key": "star_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Star R"},
		{"key": "star_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Star G"},
		{"key": "star_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Star B"},
	],
	"selfbuff": [
		{"key": "ball_scale",    "min": 0.12, "max": 0.50, "step": 0.01, "name": "Ball size"},
		{"key": "ring_scale",    "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Ring size"},
		{"key": "chevron_scale", "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Chevron size"},
		{"key": "arc_scale",     "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Shield arc"},
		{"key": "cyan_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Speed R"},
		{"key": "cyan_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Speed G"},
		{"key": "cyan_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Speed B"},
		{"key": "gold_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Shield R"},
		{"key": "gold_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Shield G"},
		{"key": "gold_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Shield B"},
	],
	"leap": [
		{"key": "arc_height",    "min": 0.5,  "max": 5.0,  "step": 0.1,  "name": "Arc height"},
		{"key": "arc_pitch",     "min": 0.0,  "max": 6.3,  "step": 0.1,  "name": "Backflip"},
		{"key": "ribbon_width",  "min": 0.04, "max": 0.40, "step": 0.01, "name": "Ribbon width"},
		{"key": "ball_scale",    "min": 0.12, "max": 0.50, "step": 0.01, "name": "Ball size"},
		{"key": "land_scale",    "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Landing ring"},
		{"key": "impact_scale",  "min": 0.30, "max": 2.5,  "step": 0.05, "name": "Impact size"},
		{"key": "impact_life",   "min": 0.10, "max": 0.60, "step": 0.02, "name": "Impact life"},
		{"key": "cyan_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ribbon R"},
		{"key": "cyan_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ribbon G"},
		{"key": "cyan_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Ribbon B"},
		{"key": "gold_r",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Contact R"},
		{"key": "gold_g",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Contact G"},
		{"key": "gold_b",        "min": 0.0,  "max": 1.0,  "step": 0.02, "name": "Contact B"},
	],
}

var _client
var _style := ""
var _styles := []
var _rows: VBoxContainer
var _sliders := {}
var _val_labels := {}

func _kind_of(style: String) -> String:
	if (_client.DASH_VFX as Dictionary).has(style):
		return "dash"
	if (_client.MELEE_VFX as Dictionary).has(style):
		return "melee"
	if (_client.SELFBUFF_VFX as Dictionary).has(style):
		return "selfbuff"
	if (_client.LEAP_VFX as Dictionary).has(style):
		return "leap"
	return "projectile"

func setup(client) -> void:
	_client = client
	_styles = _client._vfx_tune.keys()
	_styles.sort()
	_style = str(_styles[0]) if not _styles.is_empty() else ""

	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(14, 90)
	custom_minimum_size = Vector2(310, 0)
	var mg := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		mg.add_theme_constant_override("margin_" + s, 10)
	add_child(mg)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	mg.add_child(vb)

	var title := Label.new()
	title.text = "Skill VFX  ·  F3  ·  dev-only"
	vb.add_child(title)
	var hint := Label.new()
	hint.text = "live + saved to settings · bake into DEFAULT_VFX_TUNE to ship"
	hint.add_theme_font_size_override("font_size", 10)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	var opt := OptionButton.new()
	for i in range(_styles.size()):
		opt.add_item(str(_styles[i]), i)
	opt.selected = 0
	opt.item_selected.connect(_on_style_selected)
	vb.add_child(opt)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	vb.add_child(_rows)
	_rebuild()

func _spec() -> Array:
	return SPECS[_kind_of(_style)]

func _rebuild() -> void:
	for c in _rows.get_children():
		c.queue_free()
	_sliders.clear()
	_val_labels.clear()
	for spec in _spec():
		var key: String = spec["key"]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var name_lbl := Label.new()
		name_lbl.text = str(spec["name"])
		name_lbl.custom_minimum_size = Vector2(84, 0)
		row.add_child(name_lbl)
		var sl := HSlider.new()
		sl.min_value = float(spec["min"])
		sl.max_value = float(spec["max"])
		sl.step = float(spec["step"])
		sl.value = _cur(key)
		sl.custom_minimum_size = Vector2(150, 0)
		sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sl.value_changed.connect(_on_changed.bind(key))
		row.add_child(sl)
		var val_lbl := Label.new()
		val_lbl.text = "%.2f" % sl.value
		val_lbl.custom_minimum_size = Vector2(42, 0)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(val_lbl)
		_sliders[key] = sl
		_val_labels[key] = val_lbl
		_rows.add_child(row)

func _cur(key: String) -> float:
	return float((_client._vfx_tune.get(_style, {}) as Dictionary).get(key, 0.0))

func _on_style_selected(idx: int) -> void:
	_style = str(_styles[idx])
	_rebuild()                                           # kinds differ → rebuild the slider set for this skill

func _on_changed(value: float, key: String) -> void:
	(_client._vfx_tune[_style] as Dictionary)[key] = value
	if _val_labels.has(key):
		_val_labels[key].text = "%.2f" % value
	_client._apply_vfx_tune(_style)
	_save()
	print("[vfx_tune] %s %s" % [_style, _tune_line()])

func _tune_line() -> String:
	var parts := []
	for spec in _spec():
		parts.append('"%s": %s' % [spec["key"], String.num(_cur(spec["key"]), 2)])
	return "{" + ", ".join(parts) + "}"

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(AudioManager.SETTINGS_PATH)                 # keep audio/fx and other styles' sections
	var sect := "vfx_" + _style.replace("/", "_")
	for spec in _spec():
		cfg.set_value(sect, spec["key"], _cur(spec["key"]))
	cfg.save(AudioManager.SETTINGS_PATH)
