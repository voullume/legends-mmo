extends SceneTree
## Permanent Hybrid-Cutout UI icon system — the focused registry test (handoff §14). Sweeps EVERY
## production icon id and asserts: the id exists, its texture is non-null, its accessible fallback is
## non-empty, its size class is valid, and every alias resolves. Also pins the presentation contract:
## all 15 status wire-keys map to a texture, the block.svg revision was NOT imported, and the
## IconWidget factory builds a filtered/modulated TextureRect (with a text fallback for a missing id).
## Headless-safe; exits non-zero on any failure.
##   ~/.local/bin/godot --headless --path . --script res://tools/icon_registry_test.gd

const IconReg := preload("res://client/ui/IconRegistry.gd")
const IconWid := preload("res://client/ui/IconWidget.gd")
const StatusIconsS := preload("res://client/ui/StatusIcons.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

const VALID_SIZES := ["status", "inline", "header", "world"]

# the 15 status wire-keys (Server.status_st / StatusIcons.DEFS) → their canonical status icon ids.
const STATUS_KEY_ICON := {
	"stn": "stunned", "slw": "slowed", "dot": "burning", "sh": "shield", "ba": "barrier",
	"dr": "damage_reduction", "gd": "guard", "rf": "reflect", "by": "shield_pierce",
	"nx": "empowered", "cr": "critical_chance", "as": "attack_speed", "ms": "move_speed",
	"ev": "evasion", "ut": "untargetable",
}

func _init() -> void:
	print("[icon_registry_test] running")

	# ---- 1. every production id resolves to a real, labelled, correctly-classed texture ----
	var ids: Array = IconReg.ids()
	ok(ids.size() == 56, "exactly 56 production icons (got %d)" % ids.size())
	for id in ids:
		ok(IconReg.resolve(id) == id, "'%s' resolves to itself" % id)
		ok(IconReg.texture(id) != null, "'%s' has a non-null texture" % id)
		ok(str(IconReg.fallback(id)).strip_edges() != "", "'%s' has a non-empty accessible fallback" % id)
		ok(str(IconReg.size_class(id)) in VALID_SIZES, "'%s' has a valid size class (%s)" % [id, IconReg.size_class(id)])
		ok(IconReg.size_px(id) >= 12, "'%s' size px is sane (%d)" % [id, IconReg.size_px(id)])

	# ---- 2. every alias resolves to a canonical id with a texture (handoff §4) ----
	for a in IconReg.alias_ids():
		var cid := IconReg.resolve(a)
		ok(cid != "" and IconReg.ICONS.has(cid), "alias '%s' resolves to canonical '%s'" % [a, cid])
		ok(IconReg.texture(a) != null, "alias '%s' yields a texture" % a)
	# the documented aliases specifically
	ok(IconReg.resolve("quest_giver") == "quest", "quest_giver → quest")
	ok(IconReg.resolve("quest_journal") == "quest", "quest_journal → quest")
	ok(IconReg.resolve("top_tier_protected") == "shielded", "top_tier_protected → shielded")
	ok(IconReg.resolve("party_invite") == "party", "party_invite → party")
	ok(IconReg.resolve("haste") == "move_speed", "haste → move_speed")
	ok(IconReg.resolve("self_slow") == "move_speed", "self_slow → move_speed (shared asset)")

	# ---- 3. all 15 status wire-keys map to a texture; each canonical status icon is size 'status' ----
	for wk in STATUS_KEY_ICON:
		var iid: String = STATUS_KEY_ICON[wk]
		ok(IconReg.texture(iid) != null, "status key '%s' → '%s' has a texture" % [wk, iid])
		ok(IconReg.size_class(iid) == "status", "'%s' is size class 'status'" % iid)
	# and StatusIcons.DEFS itself, once each entry carries an 'icon' id, must resolve (Phase 2 wiring)
	for k in StatusIconsS.DEFS:
		var d: Dictionary = StatusIconsS.DEFS[k]
		if d.has("icon"):
			ok(IconReg.texture(str(d["icon"])) != null, "StatusIcons.DEFS['%s'].icon '%s' resolves" % [k, d["icon"]])

	# ---- 4. deliberate exclusions / distinctions ----
	ok(not IconReg.has("block"), "block.svg revision was NOT registered (owner-deferred)")
	ok(IconReg.resolve("salvage") == "salvage" and IconReg.resolve("delete") == "delete", "Salvage and Delete stay separate")
	ok(IconReg.has("elite") and IconReg.has("paragon") and IconReg.has("item_power") and IconReg.has("equipped"),
		"Elite / Paragon / Item Power / Equipped remain distinct concepts")
	ok(IconReg.has("warning") and IconReg.has("inventory_full"),
		"Warning (nearly-full) and Inventory Full (suitcase-X) are distinct")

	# ---- 5. unknown id is graceful (null texture, echoes the id as its own fallback) ----
	ok(IconReg.texture("does_not_exist") == null, "unknown id → null texture (no crash)")
	ok(IconReg.fallback("does_not_exist") == "does_not_exist", "unknown id → fallback echoes the id")

	# ---- 6. IconWidget factory contract ----
	var tr := IconWid.make("inventory", {"px": 24, "color": Color(1, 0, 0)})
	ok(tr is TextureRect, "IconWidget.make returns a TextureRect")
	ok((tr as TextureRect).texture == IconReg.texture("inventory"), "make wires the registry texture")
	ok((tr as TextureRect).expand_mode == TextureRect.EXPAND_IGNORE_SIZE, "make ignores texture size for layout")
	ok((tr as TextureRect).stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "make keeps aspect centered")
	ok((tr as TextureRect).texture_filter == CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, "make uses the mipmapped filter")
	ok((tr as TextureRect).modulate == Color(1, 0, 0), "make honors the color override")
	ok((tr as TextureRect).mouse_filter == Control.MOUSE_FILTER_IGNORE, "decorative icon ignores the mouse")
	tr.free()
	var itr := IconWid.make("guard", {"interactive": true})
	ok((itr as TextureRect).mouse_filter == Control.MOUSE_FILTER_STOP, "interactive icon stops the mouse")
	ok(str((itr as TextureRect).tooltip_text) != "", "interactive icon-only control auto-gets a tooltip")
	itr.free()
	var lbl := IconWid.make_or_label("does_not_exist", {})
	ok(lbl is Label and str((lbl as Label).text) != "", "missing id → plain-text Label fallback (not an emoji)")
	lbl.free()
	var rw := IconWid.row("credits", "1,240", {})
	ok(rw is HBoxContainer and rw.get_child_count() == 2, "row() = HBox{icon,label}")
	ok(rw.has_meta("label") and rw.has_meta("icon"), "row() exposes icon/label metas")
	rw.free()

	print("[icon_registry_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
