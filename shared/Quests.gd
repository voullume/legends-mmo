extends RefCounted
## Quest content — the source of truth for the (kill-based) quest chain. Declarative data only,
## in the same const-dict style as GameData.CLASSES / World.MAPS. The server owns all progress +
## reward logic (server-authoritative); this file just defines WHAT the quests are.
##
## A quest:
##   name/desc      — display text.
##   min_level      — the character level required to accept it.
##   prereq         — a quest_id that must be COMPLETED first ("" = none).
##   objective      — {type:"kill", match:{...}, count:int}. `match` fields are ALL optional and
##                    AND-combined against the slain mob: tier (minion/elite/boss), map (zone id),
##                    class (class id), min_level (mob level ≥). Empty match = any mob.
##   rewards        — {xp, credits, item?}. item is a full inventory row {name,rarity,slot,
##                    bonus_stat,bonus_amt} (the equipped bonus is still RARITY_CAP-capped on equip).

const QUESTS := {
	"combat_intro": {
		"name": "Boot Camp",
		"desc": "Cut your teeth in the Combat Zone — take down 5 mobs.",
		"min_level": 1, "prereq": "",
		"objective": {"type": "kill", "match": {"map": "combat"}, "count": 5},
		"rewards": {"xp": 120, "credits": 60},
	},
	"combat_elite": {
		"name": "Camp Breaker",
		"desc": "The Combat Zone's elite holds the east camp. Put it down twice.",
		"min_level": 2, "prereq": "combat_intro",
		"objective": {"type": "kill", "match": {"map": "combat", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 220, "credits": 120,
			"item": {"name": "Veteran's Medal", "rarity": "rare", "slot": "trinket", "bonus_stat": "END", "bonus_amt": 12}},
	},
	"frontier_access": {
		"name": "Into the Frontier",
		"desc": "Push past the Combat camps into the Frontier and clear 6 of its denizens.",
		"min_level": 3, "prereq": "combat_elite",
		"objective": {"type": "kill", "match": {"map": "frontier"}, "count": 6},
		"rewards": {"xp": 420, "credits": 180},
	},
	"frontier_elites": {
		"name": "Thinning the Herd",
		"desc": "Frontier elites are no joke. Bring down 2 of them.",
		"min_level": 4, "prereq": "frontier_access",
		"objective": {"type": "kill", "match": {"map": "frontier", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 520, "credits": 240,
			"item": {"name": "Frontier Sigil", "rarity": "epic", "slot": "trinket", "bonus_stat": "INS", "bonus_amt": 16}},
	},
	"frontier_boss": {
		"name": "The Keeper Falls",
		"desc": "Slay the Frontier boss — the Keeper — and claim its prize.",
		"min_level": 5, "prereq": "frontier_access",
		"objective": {"type": "kill", "match": {"map": "frontier", "tier": "boss"}, "count": 1},
		"rewards": {"xp": 700, "credits": 350,
			"item": {"name": "Keeper's Gauntlets", "rarity": "epic", "slot": "weapon", "bonus_stat": "PWR", "bonus_amt": 20}},
	},
}

# stable display/iteration order (also the chain order)
const ORDER := ["combat_intro", "combat_elite", "frontier_access", "frontier_elites", "frontier_boss"]

static func order() -> Array:
	return ORDER

static func get_quest(qid: String) -> Variant:
	return QUESTS.get(qid, null)

# does this slain-mob descriptor satisfy a quest's kill objective? v = {tier, map, class, level}.
static func kill_matches(quest: Dictionary, v: Dictionary) -> bool:
	var obj: Dictionary = quest.get("objective", {})
	if str(obj.get("type", "")) != "kill":
		return false
	var m: Dictionary = obj.get("match", {})
	if m.has("tier") and str(v.get("tier", "")) != str(m["tier"]):
		return false
	if m.has("map") and str(v.get("map", "")) != str(m["map"]):
		return false
	if m.has("class") and str(v.get("class", "")) != str(m["class"]):
		return false
	if m.has("min_level") and int(v.get("level", 1)) < int(m["min_level"]):
		return false
	return true
