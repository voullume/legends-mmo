extends SceneTree
## Full-color equipment-art registry test (too_add_models/equipment_icons/
## EQUIPMENT_ICON_IMPLEMENTATION_HANDOFF.md §7). Section A sweeps the EquipmentIcons registry
## against the LIVE server item vocabulary: every LOOT_SLOTS slot×base and every ROOKIE_PIECES
## vendor piece resolves to a real 256×256 painting, the registry holds exactly those 40 keys
## (no missing, no stale extras, and a 1:1 match with the PNGs on disk), ambiguous base words
## stay slot-safe, named quest/unique items without bespoke art degrade to ""/null (the callers'
## neutral _slot_icon fallback), build-category rows never enter the resolver, and every import
## keeps mipmaps on. The §7 UI-construction assertions live in tools/equipment_ui_test.gd — run
## as a SCENE (NetClient extends Client.gd, which needs the AudioManager autoload).
##   ~/.local/bin/godot --headless --path . --script res://tools/equipment_icons_test.gd

const GameData := preload("res://shared/GameData.gd")
const Quests := preload("res://shared/Quests.gd")
const ServerS := preload("res://server/Server.gd")
const EquipIcons := preload("res://client/ui/EquipmentIcons.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

func _init() -> void:
	print("[equipment_icons_test] running")

	# ---- A1. registry holds exactly 40 keys, each a real 256×256 Texture2D ----
	var reg_ids: Array = EquipIcons.ids()
	ok(reg_ids.size() == 40, "registry holds exactly 40 ids (got %d)" % reg_ids.size())
	for id in reg_ids:
		var tex: Texture2D = EquipIcons.texture(str(id))
		ok(tex != null and tex is Texture2D, "'%s' preloads a Texture2D" % id)
		if tex != null:
			ok(tex.get_width() == 256 and tex.get_height() == 256,
				"'%s' is 256×256 (got %d×%d)" % [id, tex.get_width(), tex.get_height()])

	# ---- A2. registry ↔ PNGs on disk, both directions ----
	var disk := []
	for f in DirAccess.get_files_at("res://client/ui/equipment_icons"):
		if str(f).ends_with(".png"):
			disk.append(str(f).trim_suffix(".png"))
	ok(disk.size() == 40, "exactly 40 PNGs on disk (got %d)" % disk.size())
	for id in reg_ids:
		ok(str(id) in disk, "registry id '%s' has a PNG" % id)
	for d in disk:
		ok(d in reg_ids, "PNG '%s' has a registry entry (no orphan art)" % d)

	# ---- A3. every live procedural base (Server LOOT_SLOTS) resolves, and the resolved key set
	# is exactly the full registry (the 40 paintings ARE the procedural vocabulary) ----
	var resolved := {}
	for slot in ServerS.LOOT_SLOTS:
		for base in ServerS.LOOT_SLOTS[slot]:
			for rar in ["Common", "Epic", "Legendary"]:
				var it := {"name": "%s %s" % [rar, str(base)], "slot": str(slot)}
				var k: String = EquipIcons.key_for_item(it)
				ok(k != "", "'%s %s' (%s) resolves (got '%s')" % [rar, base, slot, k])
				ok(EquipIcons.texture_for_item(it) != null, "'%s %s' (%s) has art" % [rar, base, slot])
				if k != "":
					resolved[k] = true
	ok(resolved.size() == 40, "procedural vocabulary covers all 40 paintings (got %d)" % resolved.size())

	# ---- A4. Rookie vendor pieces resolve to their canonical keys ("Epic Rookie Helm" shape) ----
	var rookie_expect := {"head": "helmet", "chest": "chest_pad", "hands": "gloves",
		"legs": "leggings", "trinket": "whistle"}
	for slot in ServerS.ROOKIE_PIECES:
		var it2 := {"name": "Epic %s" % str(ServerS.ROOKIE_PIECES[slot]), "slot": str(slot)}
		var k2: String = EquipIcons.key_for_item(it2)
		ok(k2 == str(rookie_expect.get(slot, "?")),
			"rookie '%s' (%s) → '%s' (got '%s')" % [ServerS.ROOKIE_PIECES[slot], slot, rookie_expect.get(slot), k2])

	# ---- A5. handoff's named procedural examples ----
	ok(EquipIcons.key_for_item({"name": "Epic Helmet", "slot": "head"}) == "helmet", "Epic Helmet → helmet")
	ok(EquipIcons.key_for_item({"name": "Rare Catcher's Mitt", "slot": "off_hand"}) == "catchers_mitt", "Rare Catcher's Mitt → catchers_mitt")
	ok(EquipIcons.key_for_item({"name": "Legendary Captain's Band", "slot": "trinket"}) == "captains_band", "Legendary Captain's Band → captains_band")

	# ---- A6. ambiguous words are slot-safe ----
	ok(EquipIcons.key_for_item({"name": "Epic Band", "slot": "ring"}) == "band", "ring Band → band")
	ok(EquipIcons.key_for_item({"name": "Epic Glove", "slot": "off_hand"}) == "glove", "off_hand Glove → glove")
	ok(EquipIcons.key_for_item({"name": "Epic Gloves", "slot": "hands"}) == "gloves", "hands Gloves → gloves (no singular bleed)")
	ok(EquipIcons.key_for_item({"name": "Epic Cap", "slot": "head"}) == "cap", "head Cap → cap")
	# slot-mismatched quest names must NOT borrow another slot's art
	ok(EquipIcons.key_for_item({"name": "Gunner's Gauntlets", "slot": "main_hand"}) == "", "main_hand Gauntlets → no art (hands word)")
	ok(EquipIcons.key_for_item({"name": "Rival Playmaker's Glove", "slot": "main_hand"}) == "", "main_hand Glove → no art (off_hand word)")
	ok(EquipIcons.key_for_item({"name": "Coach's Signet", "slot": "trinket"}) == "", "trinket Signet → no art (ring word)")
	ok(EquipIcons.key_for_item({"name": "Veteran's Medal", "slot": "trinket"}) == "", "trinket Medal → no art (neck word)")

	# ---- A7. named items WITH an unambiguous in-slot word resolve naturally ----
	ok(EquipIcons.key_for_item({"name": "Head Coach's Whistle", "slot": "trinket"}) == "whistle", "Head Coach's Whistle → whistle")
	ok(EquipIcons.key_for_item({"name": "Sanguine Band", "slot": "ring"}) == "band", "Sanguine Band → band")

	# ---- A8. unknown named uniques return null → callers keep the neutral slot fallback ----
	for uid in GameData.UNIQUE_DEFS:
		var ud: Dictionary = GameData.UNIQUE_DEFS[uid]
		var uit := {"name": str(ud["name"]), "slot": str(ud["slot"])}
		var uk: String = EquipIcons.key_for_item(uit)
		if uid == "sanguine_band":
			ok(uk == "band", "unique Sanguine Band resolves in-slot (got '%s')" % uk)
		else:
			ok(uk == "" and EquipIcons.texture_for_item(uit) == null,
				"unique '%s' → neutral fallback (got '%s')" % [ud["name"], uk])

	# ---- A9. every quest reward item resolves without crashing; log the fallback set ----
	var q_fallback := []
	var q_resolved := []
	for qid in Quests.QUESTS:
		var rew: Dictionary = (Quests.QUESTS[qid] as Dictionary).get("rewards", {})
		if rew.has("item"):
			var qit: Dictionary = rew["item"]
			var qk: String = EquipIcons.key_for_item(qit)
			var qt = EquipIcons.texture_for_item(qit)
			ok((qk == "" and qt == null) or (qk != "" and qt is Texture2D),
				"quest item '%s' resolver is consistent" % str(qit.get("name", "?")))
			if qk == "":
				q_fallback.append(str(qit.get("name", "?")))
			else:
				q_resolved.append("%s→%s" % [qit.get("name", "?"), qk])
	print("  quest items w/ bespoke-less neutral fallback: %s" % [q_fallback])
	print("  quest items resolving to catalog art: %s" % [q_resolved])

	# ---- A10. build rows / malformed input degrade safely (no slot → never enters the resolver) ----
	ok(EquipIcons.key_for_item({"name": "Vendor Stand", "category": "build"}) == "", "build row (no slot) → ''")
	ok(EquipIcons.key_for_item({"name": "Vendor Stand", "category": "build", "slot": ""}) == "", "build row (empty slot) → ''")
	ok(EquipIcons.texture_for_item({}) == null, "empty dict → null (no crash)")
	ok(EquipIcons.key_for_item({"slot": "head"}) == "", "missing name → '' (no crash)")
	ok(EquipIcons.texture("does_not_exist") == null, "unknown key → null (no crash)")

	# ---- A11. imports keep mipmaps on (48px-and-under UI scales need clean minification) ----
	for id in reg_ids:
		var imp := FileAccess.get_file_as_string("res://client/ui/equipment_icons/%s.png.import" % id)
		ok(imp.contains("mipmaps/generate=true"), "'%s' import has mipmaps on" % id)

	print("[equipment_icons_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
