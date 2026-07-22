extends Node
## Equipment-art UI-construction test (too_add_models/equipment_icons/
## EQUIPMENT_ICON_IMPLEMENTATION_HANDOFF.md §7). Builds the REAL gear surfaces on a bare NetClient
## (never added to the tree — the hotbar_icons_test pattern) and pins the §5/§6 contract: the bag
## tile / paperdoll / locker slot / locker detail / swap row / shop-forge card all carry the item
## painting, resolved paintings render WHITE with mipmapped filtering, Equipped/Upgrade/Locked are
## independent overlay badges that never replace art, unresolved named items keep the neutral
## rarity-tinted slot icon, non-gear cards gain no art, and every click/hover callback survives.
## Runs as a SCENE (NetClient extends Client.gd → AudioManager autoload):
##   ~/.local/bin/godot --headless --path . res://tools/equipment_ui_test.tscn

const NetClientS := preload("res://client/NetClient.gd")
const EquipIcons := preload("res://client/ui/EquipmentIcons.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

# every TextureRect child of a control (the overlay badges — art itself is Button.icon)
func _badges(c: Control) -> Array:
	var out := []
	for ch in c.get_children():
		if ch is TextureRect:
			out.append(ch)
	return out

func _find_rects(n: Node, out: Array) -> void:
	for ch in n.get_children():
		if ch is TextureRect:
			out.append(ch)
		_find_rects(ch, out)

func _ready() -> void:
	print("[equipment_ui_test] running")
	var nc: Node = NetClientS.new()
	var white := Color.WHITE

	# ---- 1. bag tile: art on Button.icon, white, mipmapped; no badge on a plain item ----
	var plain := {"name": "Epic Helmet", "slot": "head", "rarity": "epic", "item_power": 0}
	var t1: Button = nc.call("_inv_tile", plain)
	ok(t1.icon == EquipIcons.texture("helmet"), "bag tile: icon is the helmet painting")
	ok(t1.get_theme_color("icon_normal_color") == white, "bag tile: painting renders WHITE")
	ok(t1.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, "bag tile: mipmapped filtering")
	ok(t1.custom_minimum_size.y >= 64.0, "bag tile: tall enough for 46px art (got %s)" % t1.custom_minimum_size)
	ok(_badges(t1).is_empty(), "bag tile: plain item has no overlay badges")
	ok(t1.text.contains("Epic Helmet"), "bag tile: readable item name kept")

	# ---- 2. equipped + locked: TWO independent badges, art untouched ----
	var eq := {"name": "Rare Catcher's Mitt", "slot": "off_hand", "rarity": "rare", "equipped": true, "locked": true, "item_power": 40}
	var t2: Button = nc.call("_inv_tile", eq)
	ok(t2.icon == EquipIcons.texture("catchers_mitt"), "equipped tile: art NOT replaced by the state icon")
	ok(_badges(t2).size() == 2, "equipped+locked tile: two overlay badges (got %d)" % _badges(t2).size())
	ok(t2.get_theme_color("icon_normal_color") == white, "equipped tile: painting stays WHITE (no state tint)")
	for bd in _badges(t2):                       # regression: the 128px SVG master must never leak into an
		ok((bd as TextureRect).size.x <= 16.0 and (bd as TextureRect).size.y <= 16.0,   # anchored badge (IconWidget
			"badge stays chip-sized (got %s)" % (bd as TextureRect).size)               # size-before-expand bug)

	# ---- 3. upgrade state: badge appears, art still the painting ----
	nc.set("_inv_items", [])                    # empty bag → any IP>0 unequipped piece reads as an upgrade
	var up := {"name": "Legendary Captain's Band", "slot": "trinket", "rarity": "legendary", "item_power": 80}
	var t3: Button = nc.call("_inv_tile", up)
	ok(t3.icon == EquipIcons.texture("captains_band"), "upgrade tile: art NOT replaced by the upgrade icon")
	ok(_badges(t3).size() == 1, "upgrade tile: exactly one overlay badge")

	# ---- 4. unresolved named item: neutral slot icon + rarity tint preserved across EVERY state ----
	# (regression: the default theme paints icon_focus/hover_pressed WHITE, which would flash a tinted
	# fallback to white on focus/hover-press — every art button must pin all five icon states)
	var uniq := {"name": "Veteran's Playbook", "slot": "trinket", "rarity": "epic", "item_power": 0}
	var t4: Button = nc.call("_inv_tile", uniq)
	ok(t4.icon == nc.call("_slot_icon", "trinket"), "named fallback tile: neutral trinket icon")
	for st in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		ok(t4.get_theme_color(st) != white, "named fallback tile: keeps the rarity tint in %s" % st)

	# ---- 5. callbacks preserved on the bag tile ----
	ok(t1.pressed.get_connections().size() == 1, "bag tile: click-to-equip connected")
	ok(t1.mouse_entered.get_connections().size() == 1, "bag tile: hover tooltip connected")
	ok(t1.gui_input.get_connections().size() == 1, "bag tile: right-click context connected")

	# ---- 6. paperdoll: filled = painting white; empty = untouched disabled label ----
	var p1: Button = nc.call("_paperdoll_slot", "Head", plain)
	ok(p1.icon == EquipIcons.texture("helmet"), "paperdoll: filled slot carries the painting")
	ok(p1.get_theme_color("icon_normal_color") == white, "paperdoll: painting renders WHITE")
	ok(p1.pressed.get_connections().size() == 1, "paperdoll: click-to-unequip connected")
	var p0: Button = nc.call("_paperdoll_slot", "Head", null)
	ok(p0.icon == null and p0.disabled, "paperdoll: empty slot keeps the plain disabled label")
	# paperdoll fallback tint holds across all interaction states too (same regression as the bag tile)
	var pf: Button = nc.call("_paperdoll_slot", "Trinket", uniq)
	for st in ["icon_normal_color", "icon_hover_pressed_color", "icon_focus_color"]:
		ok(pf.get_theme_color(st) != white, "paperdoll fallback: keeps the rarity tint in %s" % st)

	# ---- 7. locker slot: filled = painting white; emptied = neutral silhouette restored ----
	nc.set("_locker_panel", Control.new())
	var cell: PanelContainer = nc.call("_locker_slot", "chest", "Chest", 0)
	var entry: Dictionary = (nc.get("_locker_slots") as Array)[0]
	var chest := {"name": "Epic Jersey", "slot": "chest", "rarity": "epic", "equipped": true, "item_power": 50, "id": "a"}
	nc.set("_locker_items", [chest])
	nc.call("_refresh_locker")
	ok((entry["icon"] as TextureRect).texture == EquipIcons.texture("jersey"), "locker slot: filled shows the painting")
	ok((entry["icon"] as TextureRect).modulate == white, "locker slot: painting modulate WHITE")
	nc.set("_locker_items", [])
	nc.call("_refresh_locker")
	ok((entry["icon"] as TextureRect).texture == nc.call("_slot_icon", "chest"), "locker slot: emptied → neutral silhouette restored")
	ok((entry["icon"] as TextureRect).modulate != white, "locker slot: empty keeps the faint tint")

	# ---- 8. locker detail: 96px art = the same painting; swap row = art icon + upgrade badge ----
	var detail := VBoxContainer.new()
	nc.set("_locker_detail", detail)
	nc.set("_locker_sel", {"key": "chest", "idx": 0})
	var spare := {"name": "Legendary Breastplate", "slot": "chest", "rarity": "legendary", "item_power": 90, "id": "b"}
	nc.set("_locker_items", [chest, spare])
	nc.call("_render_locker_detail")
	var big: TextureRect = null
	var rects := []
	_find_rects(detail, rects)
	for r in rects:
		if (r as TextureRect).custom_minimum_size == Vector2(96, 96):
			big = r
	ok(big != null and big.texture == EquipIcons.texture("jersey"), "locker detail: 96px art is the equipped painting")
	ok(big != null and big.modulate == white, "locker detail: 96px painting modulate WHITE")
	var swap: Button = null
	var stack := [detail as Node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
			if ch is Button and (ch as Button).text.begins_with("Legendary Breastplate"):
				swap = ch
	ok(swap != null, "locker detail: swap row built for the bag alternative")
	if swap != null:
		ok(swap.icon == EquipIcons.texture("breastplate"), "swap row: item painting on the button icon")
		ok(_badges(swap).size() == 1, "swap row: upgrade mark is an overlay badge (art not replaced)")
		ok(swap.pressed.get_connections().size() == 1, "swap row: click-to-equip connected")

	# ---- 9. shop/forge card: gear gets an art header; craft/build cards stay art-free ----
	var gear_card: PanelContainer = nc.call("_grid_tile", Color.WHITE, "x", {"name": "Epic Bat", "slot": "main_hand", "rarity": "epic"}, [])
	var gr := []
	_find_rects(gear_card, gr)
	ok(gr.size() == 1 and (gr[0] as TextureRect).texture == EquipIcons.texture("bat"), "gear card: exactly one art node, the bat painting")
	ok(gr.size() == 1 and (gr[0] as TextureRect).modulate == white, "gear card: painting modulate WHITE")
	var craft_card: PanelContainer = nc.call("_grid_tile", Color.WHITE, "x", null, [])
	var cr := []
	_find_rects(craft_card, cr)
	ok(cr.is_empty(), "craft card (tip_item null): no art node")
	var build_card: PanelContainer = nc.call("_grid_tile", Color.WHITE, "x", {"name": "Vendor Stand", "category": "build", "slot": ""}, [])
	var br := []
	_find_rects(build_card, br)
	ok(br.is_empty(), "build card: never enters the equipment resolver")
	# a shop-catalog entry (name+slot dict, extra price keys) resolves like the live BUY grid
	var buy_card: PanelContainer = nc.call("_grid_tile", Color.WHITE, "x", {"name": "Uncommon Chest Pad", "slot": "chest", "rarity": "uncommon", "price": 640}, [])
	var byr := []
	_find_rects(buy_card, byr)
	ok(byr.size() == 1 and (byr[0] as TextureRect).texture == EquipIcons.texture("chest_pad"), "shop BUY card: catalog entry carries its painting")

	# ---- 10. unresolved gear on a card keeps the tinted neutral icon ----
	var fb_card: PanelContainer = nc.call("_grid_tile", Color.WHITE, "x", {"name": "Wildwarden's Jacket", "slot": "chest", "rarity": "epic"}, [])
	var fbr := []
	_find_rects(fb_card, fbr)
	ok(fbr.size() == 1 and (fbr[0] as TextureRect).texture == nc.call("_slot_icon", "chest"), "fallback card: neutral chest icon")
	ok(fbr.size() == 1 and (fbr[0] as TextureRect).modulate != white, "fallback card: rarity tint preserved")

	nc.free()
	print("[equipment_ui_test] %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
