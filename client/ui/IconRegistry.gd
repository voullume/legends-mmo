class_name IconRegistry
extends RefCounted
## Permanent Hybrid-Cutout UI icon system — THE central, client-only registry (docs/ui-icon-
## integration-handoff.pdf). Owns the semantic-ID → Texture2D mapping, each icon's default
## semantic color, an accessible text fallback, a recommended size class, and aliases where one
## approved master intentionally serves more than one use. NO caller hardcodes an SVG resource
## path — everything routes through here.
##
## The neutral ice-white SVG masters (64×64 viewBox, dark cutouts, imported at svg/scale 2 with
## mipmaps) are MODULATED to a semantic color at runtime; the registry supplies the default, and
## callers with their own semantic color (StatusIcons chips, currency Palette tokens) override it.
##
## Textures are PRELOADED, so a wrong/missing path fails at parse/import time — never randomly
## mid-play. This is a PRESENTATION registry only: gameplay/status decoding, classification,
## ordering, timers and tooltips stay in StatusIcons (the authority) — see [[legends-mmo]].

# size class → artwork px (a DEFAULT hint; IconWidget callers may pass an explicit px).
# Mirrors the handoff §5 recommendations (status chips are the hardest, smallest case).
const SIZE_PX := {"status": 16, "inline": 18, "header": 24, "world": 40}

# semantic ID → {tex, color (default modulation), fallback (accessible name), size (class)}.
# Grouped by the destination hierarchy under client/ui/icons/system/.
const ICONS := {
	# ---- world states (batch 011) ----
	"shielded": {"tex": preload("res://client/ui/icons/system/world/shielded.svg"), "color": Palette.SB_CYAN, "fallback": "Shielded", "size": "world"},
	"power_core": {"tex": preload("res://client/ui/icons/system/world/power_core.svg"), "color": Palette.SB_CYAN, "fallback": "Power Core", "size": "world"},
	"elite": {"tex": preload("res://client/ui/icons/system/world/elite.svg"), "color": Palette.SB_ORANGE, "fallback": "Elite", "size": "world"},
	"resident": {"tex": preload("res://client/ui/icons/system/world/resident.svg"), "color": Palette.LAVENDER, "fallback": "Resident", "size": "world"},

	# ---- navigation & activities (batch 012 + 015) — window headers ride the cyan chrome rail ----
	"inventory": {"tex": preload("res://client/ui/icons/system/navigation/inventory.svg"), "color": Palette.SB_CYAN, "fallback": "Inventory", "size": "header"},
	"character": {"tex": preload("res://client/ui/icons/system/navigation/character.svg"), "color": Palette.SB_CYAN, "fallback": "Character", "size": "header"},
	"quest": {"tex": preload("res://client/ui/icons/system/navigation/quest.svg"), "color": Palette.SB_CYAN, "fallback": "Quest", "size": "header"},
	"shop": {"tex": preload("res://client/ui/icons/system/navigation/shop.svg"), "color": Palette.SB_CYAN, "fallback": "Shop", "size": "header"},
	"build_shop": {"tex": preload("res://client/ui/icons/system/navigation/build_shop.svg"), "color": Palette.SB_CYAN, "fallback": "Build Shop", "size": "header"},
	"settings": {"tex": preload("res://client/ui/icons/system/navigation/settings.svg"), "color": Palette.SB_CYAN, "fallback": "Settings", "size": "header"},
	"controls": {"tex": preload("res://client/ui/icons/system/navigation/controls.svg"), "color": Palette.SB_CYAN, "fallback": "Controls", "size": "header"},
	"camp_circuit": {"tex": preload("res://client/ui/icons/system/navigation/camp_circuit.svg"), "color": Palette.SB_CYAN, "fallback": "Camp Circuit", "size": "header"},
	"talents": {"tex": preload("res://client/ui/icons/system/navigation/talents.svg"), "color": Palette.SB_CYAN, "fallback": "Talents", "size": "header"},
	"paragon": {"tex": preload("res://client/ui/icons/system/navigation/paragon.svg"), "color": Palette.SB_CYAN, "fallback": "Paragon", "size": "header"},
	"leaderboards": {"tex": preload("res://client/ui/icons/system/navigation/leaderboards.svg"), "color": Palette.SB_CYAN, "fallback": "Leaderboards", "size": "header"},
	"objectives": {"tex": preload("res://client/ui/icons/system/navigation/objectives.svg"), "color": Palette.SB_CYAN, "fallback": "Objectives", "size": "header"},
	"two_minute_drill": {"tex": preload("res://client/ui/icons/system/navigation/two_minute_drill.svg"), "color": Palette.SB_CYAN, "fallback": "Two-Minute Drill", "size": "header"},
	"party": {"tex": preload("res://client/ui/icons/system/navigation/party.svg"), "color": Palette.SB_CYAN, "fallback": "Party", "size": "inline"},

	# ---- crafting & customization (batch 013) ----
	"forge": {"tex": preload("res://client/ui/icons/system/crafting/forge.svg"), "color": Palette.ACCENT, "fallback": "Forge", "size": "header"},
	"wardrobe": {"tex": preload("res://client/ui/icons/system/crafting/wardrobe.svg"), "color": Palette.LAVENDER, "fallback": "Wardrobe", "size": "header"},
	"practice_vendor": {"tex": preload("res://client/ui/icons/system/crafting/practice_vendor.svg"), "color": Palette.SB_CYAN, "fallback": "Practice Vendor", "size": "header"},
	"random_roll": {"tex": preload("res://client/ui/icons/system/crafting/random_roll.svg"), "color": Palette.ACCENT, "fallback": "Random Roll", "size": "inline"},

	# ---- item states & actions (batch 014) — semantic color preview from the batch README ----
	"locked": {"tex": preload("res://client/ui/icons/system/actions/locked.svg"), "color": Palette.SB_ORANGE, "fallback": "Locked", "size": "inline"},
	"unlocked": {"tex": preload("res://client/ui/icons/system/actions/unlocked.svg"), "color": Palette.HEAL, "fallback": "Unlocked", "size": "inline"},
	"attunement_key": {"tex": preload("res://client/ui/icons/system/actions/attunement_key.svg"), "color": Palette.ACCENT, "fallback": "Attunement Key", "size": "inline"},
	"salvage": {"tex": preload("res://client/ui/icons/system/actions/salvage.svg"), "color": Palette.LAVENDER, "fallback": "Salvage", "size": "inline"},
	"power_action": {"tex": preload("res://client/ui/icons/system/actions/power_action.svg"), "color": Palette.SB_CYAN, "fallback": "Power Action", "size": "inline"},

	# ---- currencies & rewards (batch 016) — keep the existing Palette currency colors ----
	"credits": {"tex": preload("res://client/ui/icons/system/resources/credits.svg"), "color": Palette.CREDITS, "fallback": "Credits", "size": "inline"},
	"scrap": {"tex": preload("res://client/ui/icons/system/resources/scrap.svg"), "color": Palette.SCRAP, "fallback": "Scrap", "size": "inline"},
	"tokens": {"tex": preload("res://client/ui/icons/system/resources/tokens.svg"), "color": Palette.TOKENS, "fallback": "Tokens", "size": "inline"},
	"playbook_pages": {"tex": preload("res://client/ui/icons/system/resources/playbook_pages.svg"), "color": Palette.LAVENDER, "fallback": "Playbook Pages", "size": "inline"},
	"item_power": {"tex": preload("res://client/ui/icons/system/resources/item_power.svg"), "color": Palette.ACCENT, "fallback": "Item Power", "size": "inline"},
	"bounty": {"tex": preload("res://client/ui/icons/system/resources/bounty.svg"), "color": Palette.SB_ORANGE, "fallback": "Bounty", "size": "inline"},
	"loot": {"tex": preload("res://client/ui/icons/system/resources/loot.svg"), "color": Palette.ACCENT, "fallback": "Loot", "size": "inline"},

	# ---- alerts & feedback (batch 017) ----
	"warning": {"tex": preload("res://client/ui/icons/system/feedback/warning.svg"), "color": Palette.SB_ORANGE, "fallback": "Warning", "size": "inline"},
	"inventory_full": {"tex": preload("res://client/ui/icons/system/feedback/inventory_full.svg"), "color": Palette.DANGER, "fallback": "Inventory Full", "size": "inline"},
	"delete": {"tex": preload("res://client/ui/icons/system/feedback/delete.svg"), "color": Palette.DANGER, "fallback": "Delete", "size": "inline"},
	"equipped": {"tex": preload("res://client/ui/icons/system/feedback/equipped.svg"), "color": Palette.SUCCESS, "fallback": "Equipped", "size": "inline"},
	"upgrade": {"tex": preload("res://client/ui/icons/system/feedback/upgrade.svg"), "color": Palette.SUCCESS, "fallback": "Upgrade", "size": "inline"},
	"quest_complete": {"tex": preload("res://client/ui/icons/system/feedback/quest_complete.svg"), "color": Palette.SUCCESS, "fallback": "Quest Complete", "size": "inline"},
	"information": {"tex": preload("res://client/ui/icons/system/feedback/information.svg"), "color": Palette.SB_CYAN, "fallback": "Information", "size": "inline"},

	# ---- status debuffs/defenses (batch 018, minus block.svg) + offense/mobility (batch 019).
	# defaults mirror StatusIcons.DEFS colors for standalone use; StatusRow overrides per-chip at runtime.
	"stunned": {"tex": preload("res://client/ui/icons/system/status/stunned.svg"), "color": Palette.DANGER, "fallback": "Stunned", "size": "status"},
	"slowed": {"tex": preload("res://client/ui/icons/system/status/slowed.svg"), "color": Palette.SB_ORANGE, "fallback": "Slowed", "size": "status"},
	"burning": {"tex": preload("res://client/ui/icons/system/status/burning.svg"), "color": Palette.DANGER, "fallback": "Burning", "size": "status"},
	"shield": {"tex": preload("res://client/ui/icons/system/status/shield.svg"), "color": Palette.SHIELD, "fallback": "Shield", "size": "status"},
	"barrier": {"tex": preload("res://client/ui/icons/system/status/barrier.svg"), "color": Palette.LAVENDER, "fallback": "Barrier", "size": "status"},
	"damage_reduction": {"tex": preload("res://client/ui/icons/system/status/damage_reduction.svg"), "color": Palette.SB_CYAN, "fallback": "Damage Reduction", "size": "status"},
	"guard": {"tex": preload("res://client/ui/icons/system/status/guard.svg"), "color": Palette.SB_CYAN, "fallback": "Guard", "size": "status"},
	"reflect": {"tex": preload("res://client/ui/icons/system/status/reflect.svg"), "color": Palette.SB_CYAN, "fallback": "Reflect", "size": "status"},
	"shield_pierce": {"tex": preload("res://client/ui/icons/system/status/shield_pierce.svg"), "color": Palette.ACCENT, "fallback": "Shield Pierce", "size": "status"},
	"empowered": {"tex": preload("res://client/ui/icons/system/status/empowered.svg"), "color": Palette.ACCENT, "fallback": "Empowered", "size": "status"},
	"critical_chance": {"tex": preload("res://client/ui/icons/system/status/critical_chance.svg"), "color": Palette.ACCENT, "fallback": "Critical Chance", "size": "status"},
	"attack_speed": {"tex": preload("res://client/ui/icons/system/status/attack_speed.svg"), "color": Palette.ACCENT, "fallback": "Attack Speed", "size": "status"},
	"move_speed": {"tex": preload("res://client/ui/icons/system/status/move_speed.svg"), "color": Palette.HEAL, "fallback": "Move Speed", "size": "status"},
	"evasion": {"tex": preload("res://client/ui/icons/system/status/evasion.svg"), "color": Palette.HEAL, "fallback": "Evasion", "size": "status"},
	"untargetable": {"tex": preload("res://client/ui/icons/system/status/untargetable.svg"), "color": Palette.HEAL, "fallback": "Untargetable", "size": "status"},
}

# aliases — one approved master intentionally serving more than one use (handoff §4). The alias
# resolves to a canonical ID; its default color/size/fallback come from that canonical entry unless
# the caller overrides. NOTE: Salvage is deliberately NOT aliased to Delete (convert vs destroy),
# and Elite/Paragon/Item Power/Equipped stay separate concepts.
const ALIASES := {
	"quest_giver": "quest",          # the vendor that hands out quests shares the Quest playbook art
	"quest_journal": "quest",        # the journal window shares it too
	"top_tier_protected": "shielded",# protected/top-tier reuses Shielded (no new protection metaphor)
	"party_invite": "party",         # invite reuses Party
	"party_loot": "random_roll",     # party-loot roll reuses Random Roll (context may instead use "loot")
	"haste": "move_speed",           # Move Speed asset is shared: haste …
	"self_slow": "move_speed",       # … and self-slow (runtime color + tooltip distinguish them)
}

# resolve an id or alias to a canonical id ("" if unknown)
static func resolve(id: String) -> String:
	if ICONS.has(id):
		return id
	if ALIASES.has(id):
		return str(ALIASES[id])
	return ""

static func has(id: String) -> bool:
	return resolve(id) != ""

# the modulatable Texture2D for an id/alias (null if unknown — IconWidget then shows a text fallback)
static func texture(id: String) -> Texture2D:
	var cid := resolve(id)
	if cid == "":
		push_warning("IconRegistry: unknown icon id '%s'" % id)
		return null
	return ICONS[cid]["tex"]

# the default semantic modulation color for an id/alias
static func color(id: String) -> Color:
	var cid := resolve(id)
	return ICONS[cid]["color"] if cid != "" else Palette.TEXT_BRIGHT

# the accessible text fallback (screen-reader / missing-texture word) for an id/alias
static func fallback(id: String) -> String:
	var cid := resolve(id)
	return str(ICONS[cid]["fallback"]) if cid != "" else id

# the recommended size class ("status" | "inline" | "header" | "world")
static func size_class(id: String) -> String:
	var cid := resolve(id)
	return str(ICONS[cid]["size"]) if cid != "" else "inline"

# the recommended artwork px for an id/alias (from its size class)
static func size_px(id: String) -> int:
	return int(SIZE_PX.get(size_class(id), 18))

# every canonical id (used by the registry test to sweep all production icons)
static func ids() -> Array:
	return ICONS.keys()

# every alias name (registry test asserts each resolves)
static func alias_ids() -> Array:
	return ALIASES.keys()
