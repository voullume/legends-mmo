class_name EquipmentIcons
extends RefCounted
## Full-color equipment-art registry — the painterly item illustrations (too_add_models/
## equipment_icons/EQUIPMENT_ICON_IMPLEMENTATION_HANDOFF.md). A COMPANION to [[AbilityIcons]]
## (same contract: opaque authored paintings rendered Color.WHITE, never tinted/modulated) and
## deliberately NOT part of [[IconRegistry]] (that registry owns neutral SVG symbols meant to be
## modulated). Identity is the canonical BASE key, resolved from an inventory item's name + slot —
## never from a resource path built out of display text.
##
## All 40 slot-base paintings are PRELOADED explicitly, so a wrong/missing path fails at
## parse/import time — never mid-hover. Unknown named/unique items (Embermaw, Veteran's Playbook…)
## resolve to "" / null so callers keep the neutral _slot_icon fallback; a named item that carries
## an unambiguous in-slot base word ("Head Coach's Whistle", "Sanguine Band") resolves naturally.

const ICONS := {
	# ---- head ----
	"helmet": preload("res://client/ui/equipment_icons/helmet.png"),
	"cap": preload("res://client/ui/equipment_icons/cap.png"),
	"visor": preload("res://client/ui/equipment_icons/visor.png"),
	"headguard": preload("res://client/ui/equipment_icons/headguard.png"),

	# ---- chest ----
	"jersey": preload("res://client/ui/equipment_icons/jersey.png"),
	"chest_pad": preload("res://client/ui/equipment_icons/chest_pad.png"),
	"vest": preload("res://client/ui/equipment_icons/vest.png"),
	"breastplate": preload("res://client/ui/equipment_icons/breastplate.png"),

	# ---- legs ----
	"leggings": preload("res://client/ui/equipment_icons/leggings.png"),
	"shin_guards": preload("res://client/ui/equipment_icons/shin_guards.png"),
	"trousers": preload("res://client/ui/equipment_icons/trousers.png"),
	"greaves": preload("res://client/ui/equipment_icons/greaves.png"),

	# ---- hands ----
	"gauntlets": preload("res://client/ui/equipment_icons/gauntlets.png"),
	"gloves": preload("res://client/ui/equipment_icons/gloves.png"),
	"wraps": preload("res://client/ui/equipment_icons/wraps.png"),
	"mitts": preload("res://client/ui/equipment_icons/mitts.png"),

	# ---- feet ----
	"cleats": preload("res://client/ui/equipment_icons/cleats.png"),
	"boots": preload("res://client/ui/equipment_icons/boots.png"),
	"sneakers": preload("res://client/ui/equipment_icons/sneakers.png"),
	"treads": preload("res://client/ui/equipment_icons/treads.png"),

	# ---- main_hand ----
	"bat": preload("res://client/ui/equipment_icons/bat.png"),
	"racket": preload("res://client/ui/equipment_icons/racket.png"),
	"club": preload("res://client/ui/equipment_icons/club.png"),
	"driver": preload("res://client/ui/equipment_icons/driver.png"),

	# ---- off_hand ----
	"glove": preload("res://client/ui/equipment_icons/glove.png"),
	"shield": preload("res://client/ui/equipment_icons/shield.png"),
	"buckler": preload("res://client/ui/equipment_icons/buckler.png"),
	"catchers_mitt": preload("res://client/ui/equipment_icons/catchers_mitt.png"),

	# ---- neck ----
	"medal": preload("res://client/ui/equipment_icons/medal.png"),
	"chain": preload("res://client/ui/equipment_icons/chain.png"),
	"pendant": preload("res://client/ui/equipment_icons/pendant.png"),
	"amulet": preload("res://client/ui/equipment_icons/amulet.png"),

	# ---- ring ----
	"ring": preload("res://client/ui/equipment_icons/ring.png"),
	"band": preload("res://client/ui/equipment_icons/band.png"),
	"signet": preload("res://client/ui/equipment_icons/signet.png"),
	"loop": preload("res://client/ui/equipment_icons/loop.png"),

	# ---- trinket ----
	"lucky_charm": preload("res://client/ui/equipment_icons/lucky_charm.png"),
	"whistle": preload("res://client/ui/equipment_icons/whistle.png"),
	"captains_band": preload("res://client/ui/equipment_icons/captains_band.png"),
	"token": preload("res://client/ui/equipment_icons/token.png"),

	# ---- unique items (batch 011) — keyed by GameData UNIQUE_DEFS id, resolved via item.unique_id (NOT
	# the display name, which shares no in-slot base word). sanguine_band has no bespoke art → it keeps
	# resolving through the ring "band" alias below. Keys are disjoint from the 40 slot bases above. ----
	"embermaw": preload("res://client/ui/equipment_icons/embermaw.png"),
	"skullcleaver": preload("res://client/ui/equipment_icons/skullcleaver.png"),
	"aegis_core": preload("res://client/ui/equipment_icons/aegis_core.png"),
	"reapers_edge": preload("res://client/ui/equipment_icons/reapers_edge.png"),
	"trailblazers": preload("res://client/ui/equipment_icons/trailblazers.png"),
	"ironhide_gorget": preload("res://client/ui/equipment_icons/ironhide_gorget.png"),
}

# the unique_id → art keys (subset of ICONS): item.unique_id resolves straight to bespoke art, ahead of
# any slot-alias match. Kept explicit so a future slot-base painting can never be mistaken for a unique.
const UNIQUE_ART := {
	"embermaw": true, "skullcleaver": true, "aegis_core": true,
	"reapers_edge": true, "trailblazers": true, "ironhide_gorget": true,
}

# Fixed per-slot alias tables (display words → canonical key), mirroring Server LOOT_SLOTS +
# the Practice Vendor ROOKIE_PIECES. Matching is whole-word within the item's OWN slot only,
# longest alias first — so trinket "Captain's Band" can never fall through to ring "Band", and
# off_hand "Glove" never collides with hands "Gloves". A slot-mismatched word (main_hand
# "Gunner's Gauntlets", "Rival Playmaker's Glove") deliberately resolves to nothing.
const ALIASES := {
	"head": [["rookie helm", "helmet"], ["headguard", "headguard"], ["helmet", "helmet"], ["visor", "visor"], ["cap", "cap"]],
	"chest": [["breastplate", "breastplate"], ["rookie pads", "chest_pad"], ["chest pad", "chest_pad"], ["jersey", "jersey"], ["vest", "vest"]],
	"legs": [["rookie leggings", "leggings"], ["shin guards", "shin_guards"], ["leggings", "leggings"], ["trousers", "trousers"], ["greaves", "greaves"]],
	"hands": [["rookie gloves", "gloves"], ["gauntlets", "gauntlets"], ["gloves", "gloves"], ["wraps", "wraps"], ["mitts", "mitts"]],
	"feet": [["sneakers", "sneakers"], ["cleats", "cleats"], ["treads", "treads"], ["boots", "boots"]],
	"main_hand": [["racket", "racket"], ["driver", "driver"], ["club", "club"], ["bat", "bat"]],
	"off_hand": [["catcher's mitt", "catchers_mitt"], ["buckler", "buckler"], ["shield", "shield"], ["glove", "glove"]],
	"neck": [["pendant", "pendant"], ["amulet", "amulet"], ["medal", "medal"], ["chain", "chain"]],
	"ring": [["signet", "signet"], ["band", "band"], ["ring", "ring"], ["loop", "loop"]],
	"trinket": [["rookie whistle", "whistle"], ["captain's band", "captains_band"], ["lucky charm", "lucky_charm"], ["whistle", "whistle"], ["token", "token"]],
}

static var _warned := {}                     # slot|name pairs already warned about — once, not per refresh

# normalized display text: lowercase, unified apostrophes, single-spaced, trimmed
static func _norm(name: String) -> String:
	var n := name.to_lower().replace("’", "'").replace("‘", "'")
	return " ".join(n.split(" ", false))

# the canonical art key for an inventory item dictionary, or "" when nothing in the item's own
# slot vocabulary matches (named quest/unique art doesn't exist yet → neutral slot fallback)
static func key_for_item(item: Dictionary) -> String:
	# unique items resolve by their canonical unique_id (never display text) → bespoke art if it exists;
	# a unique WITHOUT bespoke art (sanguine_band) falls through to the slot-alias table below.
	var uidv = item.get("unique_id")
	var uid: String = "" if uidv == null else str(uidv)
	if uid != "" and UNIQUE_ART.has(uid):
		return uid
	var slot := str(item.get("slot", ""))
	if not ALIASES.has(slot):                # build props / malformed rows never enter the resolver
		return ""
	var padded := " " + _norm(str(item.get("name", ""))) + " "
	for pair in ALIASES[slot]:
		if padded.contains(" " + str(pair[0]) + " "):
			return str(pair[1])
	var wk := "%s|%s" % [slot, str(item.get("name", ""))]
	if not _warned.has(wk):
		_warned[wk] = true
		push_warning("EquipmentIcons: no art for '%s' — using neutral %s slot icon" % [wk, slot])
	return ""

# the full-color Texture2D for an item, or null (caller supplies the neutral _slot_icon fallback)
static func texture_for_item(item: Dictionary) -> Texture2D:
	var k := key_for_item(item)
	return ICONS[k] if k != "" else null

static func texture(key: String) -> Texture2D:
	return ICONS.get(key)

# every registered id (the registry test sweeps completeness both directions)
static func ids() -> Array:
	return ICONS.keys()
