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

# The Glitchyard chain — one or two quests per subzone (glitchyard_1..5), climbing the level gradient.
const QUESTS := {
	"gy1_intro": {
		"name": "Boot Camp",
		"desc": "Report to Rookie Intake (Glitchyard 1) and take down 5 of the training mobs.",
		"min_level": 1, "prereq": "",
		"objective": {"type": "kill", "match": {"map": "glitchyard_1"}, "count": 5},
		"rewards": {"xp": 120, "credits": 60, "tokens": 15},
	},
	"gy2_push": {
		"name": "Hit the Grid",
		"desc": "Push into the Agility Grid (Glitchyard 2) and clear 6 of its denizens.",
		"min_level": 2, "prereq": "gy1_intro",
		"objective": {"type": "kill", "match": {"map": "glitchyard_2"}, "count": 6},
		"rewards": {"xp": 220, "credits": 120, "tokens": 18},
	},
	"gy2_brute": {
		"name": "Camp Breaker",
		"desc": "The Agility Grid's Tackle Brute holds the east end. Put it down.",
		"min_level": 3, "prereq": "gy2_push",
		"objective": {"type": "kill", "match": {"map": "glitchyard_2", "tier": "elite"}, "count": 1},
		"rewards": {"xp": 320, "credits": 160, "tokens": 25,
			"item": {"name": "Veteran's Medal", "rarity": "rare", "slot": "trinket", "bonus_stat": "END", "bonus_amt": 12}},
	},
	"gy3_clear": {
		"name": "Impact Lanes",
		"desc": "Brave the Impact Lanes (Glitchyard 3) and clear 6 of its denizens.",
		"min_level": 3, "prereq": "gy2_brute",
		"objective": {"type": "kill", "match": {"map": "glitchyard_3"}, "count": 6},
		"rewards": {"xp": 460, "credits": 200, "tokens": 22},
	},
	"gy3_sled": {
		"name": "Breaking the Sled",
		"desc": "Bring down the Sled Juggernaut that rules the Impact Lanes.",
		"min_level": 5, "prereq": "gy3_clear",
		"objective": {"type": "kill", "match": {"map": "glitchyard_3", "tier": "elite"}, "count": 1},
		"rewards": {"xp": 600, "credits": 280, "tokens": 30,
			"item": {"name": "Impact Sigil", "rarity": "epic", "slot": "trinket", "bonus_stat": "INS", "bonus_amt": 16}},
	},
	"gy4_clear": {
		"name": "Target Court",
		"desc": "Cross into the Target Court (Glitchyard 4) and clear 6 of its denizens.",
		"min_level": 5, "prereq": "gy3_sled",
		"objective": {"type": "kill", "match": {"map": "glitchyard_4"}, "count": 6},
		"rewards": {"xp": 760, "credits": 360, "tokens": 28,
			"item": {"name": "Command Charm", "rarity": "epic", "slot": "trinket", "bonus_stat": "CLU", "bonus_amt": 24}},
	},
	"gy4_elites": {
		"name": "Counterfire",
		"desc": "The Target Court's elites — the Sled and the Ball Machine — guard the lanes. Bring down 2.",
		"min_level": 6, "prereq": "gy4_clear",
		"objective": {"type": "kill", "match": {"map": "glitchyard_4", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 980, "credits": 460, "tokens": 38,
			"item": {"name": "Gunner's Gauntlets", "rarity": "epic", "slot": "main_hand", "bonus_stat": "PWR", "bonus_amt": 20}},
	},
	"gy5_command": {
		"name": "Command Tower",
		"desc": "Storm the Command Tower (Glitchyard 5) and put down 2 of its elites — the Ball Machine and the Drill Sergeant.",
		"min_level": 6, "prereq": "gy4_elites",
		"objective": {"type": "kill", "match": {"map": "glitchyard_5", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 1400, "credits": 660, "tokens": 50,
			"item": {"name": "Drillmaster's Bulwark", "rarity": "epic", "slot": "chest", "bonus_stat": "END", "bonus_amt": 28}},
	},
	# CAPSTONE — beat Boss1 (the Head Coach, in the arena past Command Tower). Completing it is the last gate
	# on the SECRET boss: once EVERY quest (this included) is done, the gated portal to Head Coach PRIME reveals.
	"headcoach_down": {
		"name": "The Head Coach",
		"desc": "Enter the Head Coach Arena (the pad past the Command Tower) and defeat the Head Coach Prototype.",
		"min_level": 7, "prereq": "gy5_command",
		"objective": {"type": "kill", "match": {"map": "glitchyard_boss", "tier": "boss"}, "count": 1},
		"rewards": {"xp": 2000, "credits": 800, "tokens": 80,
			"item": {"name": "Head Coach's Whistle", "rarity": "epic", "slot": "trinket", "bonus_stat": "INS", "bonus_amt": 26}},
	},
}

# stable display/iteration order (also the chain order)
const ORDER := ["gy1_intro", "gy2_push", "gy2_brute", "gy3_clear", "gy3_sled",
	"gy4_clear", "gy4_elites", "gy5_command", "headcoach_down"]

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
