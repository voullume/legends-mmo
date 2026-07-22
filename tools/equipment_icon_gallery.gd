extends Node
## Equipment-art review gallery (too_add_models/equipment_icons/
## EQUIPMENT_ICON_IMPLEMENTATION_HANDOFF.md §7). Page 1 is the 40-painting catalog wall; the
## other pages render the REAL gear surfaces (NetClient._build_inventory / _build_locker /
## _grid_tile — not mockups) on a bare NetClient with fixture items covering every rarity,
## Equipped/Upgrade/Locked badges, and the neutral-fallback named pieces, captured at the
## supported window sizes (1152×648 min / 1280×720 / 1920×1080). Runs WINDOWED (needs a rendered
## viewport; project canvas 1600×900, canvas_items stretch → window size IS the live scaling):
##   godot --path . res://tools/equipment_icon_gallery.tscn -- --out /abs/path/out
const GameData := preload("res://shared/GameData.gd")
const NetClientS := preload("res://client/NetClient.gd")
const EquipIcons := preload("res://client/ui/EquipmentIcons.gd")

const SLOT_ORDER := ["head", "chest", "legs", "hands", "feet", "main_hand", "off_hand", "neck", "ring", "trinket"]

# the bag fixture: all six rarities, equipped/upgrade/locked states, an in-slot-resolving quest
# item, and the two flavors of neutral fallback (quest name + gold-border unique)
const BAG := [
	{"name": "Epic Jersey", "slot": "chest", "rarity": "epic", "equipped": true, "item_power": 61, "ilvl": 14, "primary_stat": "END", "primary_amt": 31, "id": "g1"},
	{"name": "Rare Band", "slot": "ring", "rarity": "rare", "equipped": true, "item_power": 40, "ilvl": 12, "primary_stat": "CLU", "primary_amt": 22, "id": "g2"},
	{"name": "Head Coach's Whistle", "slot": "trinket", "rarity": "epic", "equipped": true, "item_power": 52, "ilvl": 13, "bonus_stat": "INS", "bonus_amt": 26, "id": "g3"},
	{"name": "Common Cap", "slot": "head", "rarity": "common", "item_power": 14, "ilvl": 6, "primary_stat": "END", "primary_amt": 6, "id": "g4"},
	{"name": "Uncommon Shin Guards", "slot": "legs", "rarity": "uncommon", "item_power": 26, "ilvl": 9, "primary_stat": "PRE", "primary_amt": 13, "id": "g5"},
	{"name": "Rare Sneakers", "slot": "feet", "rarity": "rare", "locked": true, "item_power": 38, "ilvl": 12, "primary_stat": "PWR", "primary_amt": 20, "id": "g6"},
	{"name": "Epic Wraps", "slot": "hands", "rarity": "epic", "item_power": 58, "ilvl": 14, "primary_stat": "PWR", "primary_amt": 30, "id": "g7"},
	{"name": "Legendary Driver", "slot": "main_hand", "rarity": "legendary", "item_power": 84, "ilvl": 16, "primary_stat": "PWR", "primary_amt": 44, "id": "g8"},
	{"name": "Mythic Amulet", "slot": "neck", "rarity": "mythic", "item_power": 108, "ilvl": 18, "primary_stat": "CLU", "primary_amt": 56, "id": "g9"},
	{"name": "Rare Catcher's Mitt", "slot": "off_hand", "rarity": "rare", "item_power": 36, "ilvl": 11, "primary_stat": "END", "primary_amt": 19, "id": "g10"},
	{"name": "Veteran's Playbook", "slot": "trinket", "rarity": "epic", "item_power": 44, "ilvl": 12, "bonus_stat": "INS", "bonus_amt": 22, "id": "g11"},
	{"name": "Embermaw", "slot": "main_hand", "rarity": "epic", "unique_id": "embermaw", "item_power": 66, "ilvl": 15, "primary_stat": "PWR", "primary_amt": 34, "id": "g12"},
]

var out_dir := "/tmp/equipment_icon_gallery"
var _stage: Control = null
var _clients := []          # bare NetClient nodes (never in the tree) — freed on exit

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
	# page 1 — the 40-painting catalog wall, keyed, grouped by slot
	_fresh_stage()
	_build_catalog_wall()
	await _shot("catalog_wall")
	# pages 2–4 — the REAL Inventory panel (bag grid + paperdoll) at every supported size
	_fresh_stage()
	_build_bag_page()
	for s in [Vector2i(1152, 648), Vector2i(1280, 720), Vector2i(1920, 1080)]:
		DisplayServer.window_set_size(s)
		await _shot("inventory_%dx%d" % [s.x, s.y])
	# pages 5–6 — the REAL Locker Loadout screen (filled + empty slots, detail, swap rows)
	_fresh_stage()
	_build_locker_page()
	for s in [Vector2i(1152, 648), Vector2i(1920, 1080)]:
		DisplayServer.window_set_size(s)
		await _shot("locker_%dx%d" % [s.x, s.y])
	# page 7 — Shop/Forge gear cards next to the art-free craft/build cards
	_fresh_stage()
	_build_cards_page()
	DisplayServer.window_set_size(Vector2i(1280, 720))
	await _shot("shop_forge_cards_1280x720")
	print("[equipment_icon_gallery] pages saved to %s" % out_dir)
	for c in _clients:
		c.free()
	get_tree().quit(0)

func _fresh_stage() -> void:
	if _stage != null:
		_stage.free()
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_stage)
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.016, 0.028, 0.05)
	_stage.add_child(bg)

func _nc() -> Node:
	var c: Node = NetClientS.new()
	_clients.append(c)
	var hud := CanvasLayer.new()               # _hud is typed CanvasLayer — panels render on it
	_stage.add_child(hud)
	c.set("_hud", hud)
	return c

func _build_catalog_wall() -> void:
	_caption("equipment icon catalog — all 40 slot-base paintings (batch_010, canonical keys)", Vector2(24, 10))
	var x := 24.0
	var y := 44.0
	for si in SLOT_ORDER.size():
		var slot: String = SLOT_ORDER[si]
		var col := si / 5          # two columns of five slot groups
		var row := si % 5
		x = 24.0 + col * 780.0
		y = 44.0 + row * 166.0
		_caption(slot.to_upper(), Vector2(x, y))
		var keys := []
		for pair in EquipIcons.ALIASES[slot]:
			if not keys.has(pair[1]):
				keys.append(pair[1])
		for ki in keys.size():
			var k: String = keys[ki]
			var tr := TextureRect.new()
			tr.texture = EquipIcons.texture(k)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			tr.position = Vector2(x + ki * 190.0, y + 18.0)
			tr.size = Vector2(112, 112)
			_stage.add_child(tr)
			_caption(k, Vector2(x + ki * 190.0, y + 132.0))

func _build_bag_page() -> void:
	var nc := _nc()
	nc.call("_build_inventory")
	nc.set("_inv_items", BAG.duplicate(true))
	nc.call("_recount_gear")
	nc.call("_rebuild_paperdoll", BAG)
	nc.call("_render_inv_tiles")
	var panel: Control = nc.get("_inv_panel")
	panel.visible = true
	_caption("REAL _build_inventory output — art+name tiles, Equipped/Upgrade/Locked badges, neutral-fallback named items (Veteran's Playbook, Embermaw)", Vector2(24, 6))

func _build_locker_page() -> void:
	var nc := _nc()
	nc.set("_state", {"self": {"classId": "batter", "level": 14, "item_power": 262,
		"equip_bonus": {"PWR": 22, "END": 14}, "set_bonus": {}, "procs": []}})
	nc.call("_build_locker")
	var items := BAG.duplicate(true)
	items.append({"name": "Legendary Breastplate", "slot": "chest", "rarity": "legendary", "item_power": 92, "ilvl": 17, "primary_stat": "END", "primary_amt": 48, "id": "g13"})
	nc.set("_locker_items", items)
	var panel: Control = nc.get("_locker_panel")
	panel.visible = true
	nc.call("_refresh_locker")
	nc.call("_select_locker_slot", "chest", 0)

func _build_cards_page() -> void:
	var nc := _nc()
	_caption("Shop/Forge gear cards (painting + name/meta header) vs untouched craft/build cards", Vector2(24, 8))
	var row := HFlowContainer.new()
	row.position = Vector2(24, 36)
	row.size = Vector2(1540, 820)
	row.add_theme_constant_override("h_separation", 10)
	row.add_theme_constant_override("v_separation", 10)
	_stage.add_child(row)
	# BUY-style gear cards (the live header bbcode shape) across rarities + slots
	var buys := [
		["Common Helmet", "head", "common", 220], ["Uncommon Chest Pad", "chest", "uncommon", 640],
		["Rare Cleats", "feet", "rare", 1600], ["Epic Racket", "main_hand", "epic", 3800],
		["Rare Shield", "off_hand", "rare", 1600], ["Epic Pendant", "neck", "epic", 3800],
		["Uncommon Signet", "ring", "uncommon", 640], ["Epic Lucky Charm", "trinket", "epic", 3800],
		["Rare Trousers", "legs", "rare", 1600], ["Epic Gauntlets", "hands", "epic", 3800],
	]
	for b in buys:
		var e := {"name": b[0], "slot": b[1], "rarity": b[2], "price": b[3], "ilvl": 13, "primary_stat": "PWR", "primary_amt": 24, "item_power": 50}
		var header := "[color=%s]%s[/color] [color=#7f8a99](%s · %s)[/color]\n[color=#9fe8a0]+24 PWR[/color]   [color=#ffd24d]%d credits[/color]" % [
			Palette.RARITY_HEX.get(b[2], "#cfd6df"), b[0], b[2], b[1], b[3]]
		row.add_child(nc.call("_grid_tile", Color.html(Palette.RARITY_HEX.get(b[2], "#cfd6df")), header, e, []))
	# a forge upgrade card (action buttons intact) + fallback named gear + art-free craft/build cards
	var fit := {"name": "Legendary Bat", "slot": "main_hand", "rarity": "legendary", "ilvl": 16, "item_power": 84, "primary_stat": "PWR", "primary_amt": 44, "id": "f1"}
	var frow := HBoxContainer.new()
	frow.add_child(nc.call("_tile_btn", "Upgrade", Color.html("#ffcf8a"), true, func() -> void: pass))
	frow.add_child(nc.call("_tile_btn", "Reforge", Color.html("#cdbcff"), true, func() -> void: pass))
	row.add_child(nc.call("_grid_tile", nc.call("_item_color", fit), "[color=#ff9d3c]Legendary Bat[/color] [color=#7f8a99](main_hand · i16 · IP 84)[/color]\n[color=#9fe8a0]Upgrade →+1: 900 credits +12sc[/color]", fit, [], frow))
	row.add_child(nc.call("_grid_tile", Color.WHITE, "[color=%s]Wildwarden's Jacket[/color] [color=#7f8a99](chest · named quest reward — neutral slot fallback)[/color]" % "#c58cff", {"name": "Wildwarden's Jacket", "slot": "chest", "rarity": "epic"}, []))
	row.add_child(nc.call("_grid_tile", Color.html("#bfe3ff"), "[color=#bfe3ff]Forge Cache[/color]\n→ [color=#c58cff]epic[/color]  [color=#9fe8a0]40 scrap[/color]   (craft — no art by design)", null, []))
	row.add_child(nc.call("_grid_tile", Color.html("#bfe3ff"), "[color=#bfe3ff]Vendor Stand[/color]  [color=#7f8a99](build prop — no art by design)[/color]", {"name": "Vendor Stand", "category": "build", "slot": ""}, []))

func _caption(text: String, pos: Vector2) -> void:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.6, 0.68, 0.78))
	_stage.add_child(l)

func _shot(name: String) -> void:
	for i in 4:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir + "/" + name + ".png")
	print("[equipment_icon_gallery] %s.png" % name)
