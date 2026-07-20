extends Node
## Full-color ability-art review gallery (too_add_models/ABILITY_ICON_IMPLEMENTATION_HANDOFF.md
## §10). Renders all eight REAL class hotbars (via Client._build_hotbar — not mockups) as a
## 64-icon wall in ready, cooldown, and locked states, plus one bar across the HudLayout scale
## range, saving one PNG per page. Runs as a SCENE (Client.gd needs the AudioManager autoload)
## and WINDOWED (needs a rendered viewport; project canvas 1600×900):
##   godot --path . res://tools/ability_icon_gallery.tscn -- --out /abs/path/out
const GameData := preload("res://shared/GameData.gd")
const ClientS := preload("res://client/Client.gd")

const PLAYABLE := ["pitcher", "batter", "quarterback", "linebacker", "setter", "spiker", "striker", "goalkeeper"]

var out_dir := "/tmp/ability_icon_gallery"
var _stage: Control = null
var _clients := []          # bare Client nodes (never in the tree) — freed on exit
var _bars := {}             # class_id → {bar, slots}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	get_tree().root.theme = UITheme.get_theme()
	_run()

func _run() -> void:
	await get_tree().process_frame
	_build_wall()
	# page 1 — every slot ready (empty cooldowns)
	for cls in PLAYABLE:
		_update(cls, {})
	await _shot("wall_ready")
	# page 2 — staggered live cooldowns (wipe + centered numeral; slot 1 left ready on purpose)
	var fracs := [0.0, 0.85, 0.5, 0.25, 0.7, 0.4, 0.95, 0.6]
	for cls in PLAYABLE:
		var cds := {}
		var abs_: Array = GameData.CLASSES[cls]["abilities"]
		for s in abs_.size():
			var total: float = float(abs_[s].get("cd", 0.0))
			if fracs[s] > 0.0 and total > 0.0:
				cds[str(abs_[s]["key"])] = total * float(fracs[s])
		_update(cls, cds)
	await _shot("wall_cooldown")
	# page 3 — locked overlays above the art (slots 2–8, mirroring a fresh level-1 kit)
	for cls in PLAYABLE:
		_update(cls, {})
		var slots: Array = _bars[cls]["slots"]
		for s in range(1, slots.size()):
			(slots[s]["lock"] as ColorRect).visible = true
			(slots[s]["ready"] as ColorRect).visible = false
	await _shot("wall_locked")
	# page 4 — one bar across the HudLayout scale range (art ≈ 36 / 43 / 54 / 81 px)
	_fresh_stage()
	var y := 60.0
	for sc in [0.67, 0.8, 1.0, 1.5]:
		var cid := _build_bar("pitcher")
		_update_for(cid, "pitcher", {})
		var wrap := Control.new()
		wrap.position = Vector2(60, y)
		wrap.scale = Vector2(sc, sc)
		_stage.add_child(wrap)
		wrap.add_child(_bars[cid]["bar"])
		_caption("hotbar scale %d%% (art %d px)" % [int(sc * 100.0), int(round(54.0 * sc))], Vector2(60, y - 18.0))
		y += 60.0 * sc + 40.0
	await _shot("hotbar_scales")
	print("[ability_icon_gallery] pages saved to %s" % out_dir)
	for c in _clients:
		c.free()
	get_tree().quit(0)

func _fresh_stage() -> void:
	if _stage != null:
		_stage.free()
		_bars.clear()
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_stage)
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.028, 0.05)
	_stage.add_child(bg)

# one REAL hotbar via Client._build_hotbar on a fresh bare Client (its own instance, so earlier
# bars are never queue_freed by a rebuild). Returns the _bars id used to address it.
func _build_bar(cls: String) -> String:
	var c: Node = ClientS.new()
	_clients.append(c)
	var bar := HBoxContainer.new()
	c.set("_hotbar", bar)
	c.call("_build_hotbar", cls)
	var cid := "%s#%d" % [cls, _bars.size()]
	_bars[cid] = {"bar": bar, "client": c, "slots": (c.get("_slots") as Array).duplicate()}
	return cid

func _build_wall() -> void:
	_fresh_stage()
	var y := 44.0
	for cls in PLAYABLE:
		var cid := _build_bar(cls)
		_bars[cls] = _bars[cid]        # wall pages address by plain class id
		var bar: HBoxContainer = _bars[cid]["bar"]
		bar.position = Vector2(200, y)
		_stage.add_child(bar)
		_caption("%s — %s" % [GameData.CLASSES[cls]["name"], str(GameData.CLASSES[cls]["sport"])], Vector2(36, y + 22.0))
		y += 96.0
	_caption("all 8 playable hotbars — real _build_hotbar output, slots 1–8 in GameData order", Vector2(200, 12))

func _update_for(cid: String, cls: String, cds: Dictionary) -> void:
	var pf := {"classId": cls, "cds": cds, "dmgMult": 1.0, "maxHP": 1000.0}
	(_bars[cid]["client"] as Node).call("_update_hotbar", pf)

func _update(cls: String, cds: Dictionary) -> void:
	_update_for(cls, cls, cds)

func _caption(text: String, pos: Vector2) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
	_stage.add_child(l)

func _shot(name: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + "/" + name + ".png")
	print("[ability_icon_gallery] %s.png" % name)
