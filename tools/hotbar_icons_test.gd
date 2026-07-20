extends Node
## Full-color ability-art HOTBAR test (too_add_models/ABILITY_ICON_IMPLEMENTATION_HANDOFF.md §9.2).
## Builds the REAL hotbar via Client._build_hotbar (bare Client node, never added to the tree, so
## no world/HUD boot) for every playable class and pins the §8 contract: exactly one art
## TextureRect per slot, drawn above the background but below cooldown/keycap/ready/lock, keycaps
## still read 1–8, art renders unmodulated white, the tiny name label only appears when art is
## missing (mob-kit fallback), cooldown/ready state updates still work, and the hover tooltip
## still carries name + description. Runs as a SCENE (not --script) because Client.gd references
## the AudioManager autoload, which only exists in a normal scene run:
##   ~/.local/bin/godot --headless --path . res://tools/hotbar_icons_test.tscn
## Exits non-zero on any failure (greppable "FAIL").

const GameData := preload("res://shared/GameData.gd")
const AbilityIconsS := preload("res://client/ui/AbilityIcons.gd")
const ClientS := preload("res://client/Client.gd")

const PLAYABLE := ["pitcher", "batter", "quarterback", "linebacker", "setter", "spiker", "striker", "goalkeeper"]

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

func _ready() -> void:
	print("[hotbar_icons_test] running")
	var c: Node = ClientS.new()
	var bar := HBoxContainer.new()
	c.set("_hotbar", bar)

	# ---- 1. every playable class builds 8 slots with correctly layered art ----
	for cls in PLAYABLE:
		c.call("_build_hotbar", cls)
		var slots: Array = c.get("_slots")
		var abs_: Array = GameData.CLASSES[cls]["abilities"]
		ok(slots.size() == 8, "%s: 8 slots built (got %d)" % [cls, slots.size()])
		for i in slots.size():
			var slot: Control = slots[i]["root"]
			ok(str(slots[i]["key"]) == str(abs_[i]["key"]), "%s slot %d stores key '%s'" % [cls, i + 1, abs_[i]["key"]])
			var arts := []
			var labels := []
			for ch in slot.get_children():
				if ch is TextureRect:
					arts.append(ch)
				elif ch is Label:
					labels.append(ch)
			ok(arts.size() == 1, "%s slot %d has one art TextureRect (got %d)" % [cls, i + 1, arts.size()])
			if arts.size() == 1:
				var art: TextureRect = arts[0]
				ok(art.texture == AbilityIconsS.texture(cls, str(abs_[i]["key"])),
					"%s slot %d shows the %s/%s painting" % [cls, i + 1, cls, abs_[i]["key"]])
				ok(art.get_index() == 1, "%s slot %d art sits directly above bg (idx 1, got %d)" % [cls, i + 1, art.get_index()])
				var cd_i: int = (slots[i]["cd"] as ColorRect).get_index()
				var lock_i: int = (slots[i]["lock"] as ColorRect).get_index()
				var ready_i: int = (slots[i]["ready"] as ColorRect).get_index()
				ok(art.get_index() < cd_i and art.get_index() < lock_i and art.get_index() < ready_i,
					"%s slot %d art draws below cooldown/lock/ready" % [cls, i + 1])
				ok(art.modulate == Color.WHITE and art.self_modulate == Color.WHITE,
					"%s slot %d art is unmodulated white" % [cls, i + 1])
				ok(art.mouse_filter == Control.MOUSE_FILTER_IGNORE, "%s slot %d art ignores the mouse" % [cls, i + 1])
				ok(art.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
					and art.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED
					and art.texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS,
					"%s slot %d art expand/stretch/filter contract" % [cls, i + 1])
				# regression pin: expand_mode must be set BEFORE size, or the 256px texture
				# minimum inflates the rect to full art size and floods the whole hotbar
				ok(art.position == Vector2(3, 3) and art.size == Vector2(54, 54),
					"%s slot %d art stays a 54×54 inset (got pos %s size %s)" % [cls, i + 1, art.position, art.size])
			var cap: PanelContainer = null
			for ch in slot.get_children():
				if ch is PanelContainer:
					cap = ch
			ok(cap != null and (cap.get_child(0) as Label).text == str(i + 1), "%s slot %d keycap reads %d" % [cls, i + 1, i + 1])
			var name_labels := 0
			for l in labels:
				if str(l.text) == str(abs_[i]["name"]):
					name_labels += 1
			ok(name_labels == 0, "%s slot %d has no on-slot name label when art resolves" % [cls, i + 1])

	# ---- 2. cooldown/ready state still updates on the real slots ----
	var pf := {"classId": "pitcher", "cds": {}, "dmgMult": 1.0, "maxHP": 1000.0}
	c.call("_update_hotbar", pf)
	var s0: Dictionary = (c.get("_slots") as Array)[0]
	ok((s0["ready"] as ColorRect).visible, "no cooldown → ready tick visible")
	ok((s0["cd"] as ColorRect).size.y == 0.0, "no cooldown → zero wipe")
	pf["cds"] = {"fastball": 0.7}
	c.call("_update_hotbar", pf)
	s0 = (c.get("_slots") as Array)[0]
	ok(not (s0["ready"] as ColorRect).visible, "cooling → ready tick hidden")
	ok((s0["cd"] as ColorRect).size.y > 0.0, "cooling → wipe covers a fraction of the art")
	ok(str((s0["cs"] as Label).text) == "1", "cooling → centered seconds numeral")

	# ---- 3. tooltip content is untouched (name + description still come from hover) ----
	var tip: String = c.call("_ability_tooltip", GameData.CLASSES["pitcher"]["abilities"][0], pf)
	ok(tip.contains("Fastball"), "tooltip still carries the display name")
	ok(tip.contains("quick pitch"), "tooltip still carries the description")

	# ---- 4. a kit with NO registered art (mob kit) falls back to readable name labels ----
	c.call("_build_hotbar", "cone_swarmer")
	var mslots: Array = c.get("_slots")
	ok(mslots.size() == 2, "mob kit builds its slots (got %d)" % mslots.size())
	for i in mslots.size():
		var slot2: Control = mslots[i]["root"]
		var m_arts := 0
		var m_named := 0
		for ch in slot2.get_children():
			if ch is TextureRect:
				m_arts += 1
			elif ch is Label and str(ch.text) == str(GameData.CLASSES["cone_swarmer"]["abilities"][i]["name"]):
				m_named += 1
		ok(m_arts == 0, "missing art slot %d gets no TextureRect" % (i + 1))
		ok(m_named == 1, "missing art slot %d falls back to the readable name label" % (i + 1))

	bar.free()
	c.free()
	print("[hotbar_icons_test] %d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
