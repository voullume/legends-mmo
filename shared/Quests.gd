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
##   rewards        — {xp, credits, tokens?, pages?, dye?, item?}. tokens = Practice Tokens; pages =
##                    Playbook Pages (attunement, toward the Master Key); dye = a cosmetic dye id
##                    (GameData.DYE_IDS). item is a full inventory row {name,rarity,slot,bonus_stat,
##                    bonus_amt} (the equipped bonus is still RARITY_CAP-capped on equip).
##
## Two chains live here: the original Glitchyard story (ORDER, min_level 1-7) and the mid-level spine
## (MIDGAME_ORDER, min_level 8-27) that fills the L8-30 questless stretch. ORDER is ALSO the secret-boss
## gate (server _all_quests_done iterates it), so the mid-level chain is a SEPARATE list — never fold it
## into ORDER or completing the secret boss would suddenly require all ~18 quests.

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

	# --- Mid-level spine (gameplay-length P6a): fills the L8-30 questless stretch. Objectives use ONLY
	# tier/map matches (open-world & Glitchyard mobs cap at level ~8, so a mob min_level filter above 8
	# would be uncompletable); the character accept-gate is min_level. Chains off headcoach_down. All
	# targets are farmable: elites in the Camp Circuit (re-enter for a fresh set) + respawning GY mobs;
	# the lone boss objective is count 1 (the Head Coach is a 30-min world event).
	"mid1_proving": {
		"name": "Proving Ground",
		"desc": "You beat the Head Coach — now prove it wasn't a fluke. Take down 20 opponents anywhere in the Yard.",
		"min_level": 8, "prereq": "headcoach_down",
		"objective": {"type": "kill", "match": {}, "count": 20},
		"rewards": {"xp": 600, "credits": 900, "pages": 20},
	},
	"mid2_circuit": {
		"name": "Circuit Regular",
		"desc": "The Camp Circuit is where veterans sharpen up. Defeat 12 elite opponents.",
		"min_level": 10, "prereq": "mid1_proving",
		"objective": {"type": "kill", "match": {"tier": "elite"}, "count": 12},
		"rewards": {"xp": 900, "tokens": 30, "pages": 20},
	},
	"mid3_command": {
		"name": "Return to Command",
		"desc": "Sweep the Command Tower (Glitchyard 5) again — 20 of its denizens, this time on your terms.",
		"min_level": 12, "prereq": "mid2_circuit",
		"objective": {"type": "kill", "match": {"map": "glitchyard_5"}, "count": 20},
		"rewards": {"xp": 1200, "credits": 1400,
			"item": {"name": "Veteran's Playbook", "rarity": "epic", "slot": "trinket", "bonus_stat": "INS", "bonus_amt": 22}},
	},
	"mid4_detail": {
		"name": "Elite Detail",
		"desc": "Command wants the tough ones handled. Bring down 20 elite opponents.",
		"min_level": 14, "prereq": "mid3_command",
		"objective": {"type": "kill", "match": {"tier": "elite"}, "count": 20},
		"rewards": {"xp": 1600, "pages": 25, "dye": "azure"},
	},
	"mid5_respec": {
		"name": "Back to the Drawing Board",
		"desc": "Rack up 30 takedowns and Command will front you the credits to rework your whole build.",
		"min_level": 16, "prereq": "mid4_detail",
		"objective": {"type": "kill", "match": {}, "count": 30},
		"rewards": {"xp": 2000, "credits": 50000},
	},
	"mid6_tower": {
		"name": "Tower Assault",
		"desc": "The Command Tower's elites keep re-forming. Put down 6 of Glitchyard 5's elites.",
		"min_level": 18, "prereq": "mid5_respec",
		"objective": {"type": "kill", "match": {"map": "glitchyard_5", "tier": "elite"}, "count": 6},
		"rewards": {"xp": 2600, "tokens": 40, "pages": 30},
	},
	"mid7_grind": {
		"name": "The Long Grind",
		"desc": "No shortcuts left — 40 opponents, wherever you find them.",
		"min_level": 21, "prereq": "mid6_tower",
		"objective": {"type": "kill", "match": {}, "count": 40},
		"rewards": {"xp": 3600, "credits": 3000, "pages": 25},
	},
	"mid8_veteran": {
		"name": "Command Veteran",
		"desc": "Elites don't scare a veteran. Defeat 30 of them and earn the Yard's colors.",
		"min_level": 24, "prereq": "mid7_grind",
		"objective": {"type": "kill", "match": {"tier": "elite"}, "count": 30},
		"rewards": {"xp": 4800, "pages": 25, "dye": "gold",
			"item": {"name": "Coach's Signet", "rarity": "epic", "slot": "trinket", "bonus_stat": "CLU", "bonus_amt": 26}},
	},
	"mid9_legend": {
		"name": "Legend of the Yard",
		"desc": "One last statement. Return to the Head Coach Arena and put the Prototype down again.",
		"min_level": 27, "prereq": "mid8_veteran",
		"objective": {"type": "kill", "match": {"map": "glitchyard_boss", "tier": "boss"}, "count": 1},
		"rewards": {"xp": 6500, "credits": 5000, "pages": 35, "dye": "obsidian"},
	},

	# --- Phase 8: the Away Circuit chain (docs/phase8-away-circuit-plan.md). The FIRST quest deliberately has
	# prereq "" — before this, every mid-game quest chained off headcoach_down (L16+IP800-locked), which is
	# exactly why the 9-16 band was a questless desert. XP is sized to ~35-40% of the 8→13 band (the required
	# kills' own XP carries the rest) — deliberately UNDER the GY chain's overshoot so zones aren't skipped
	# (the stab_away numeric pass computes and pins this). No gear items yet: quest gear enters in S2 with the
	# IP800 numeric pass (explicit ilvl, not the legacy shape that _grant_quest_item normalizes to ~IP 27).
	"away1_roadgame": {
		"name": "Road Game",
		"desc": "The away fields have gone wild. Beat the Command Tower, then take the wilds gate past it (or the Home shortcut, north side) and put down 12 of the creatures overrunning the old practice field.",
		"min_level": 8, "prereq": "",
		"objective": {"type": "kill", "match": {"map": "away_1"}, "count": 12},
		"rewards": {"xp": 420, "credits": 260, "tokens": 20},
	},
	"away1_blocker": {
		"name": "The Old Bull",
		"desc": "An old bull grazer has claimed the east lot — twice the size of the herd and twice as mean. Put it down.",
		"min_level": 9, "prereq": "away1_roadgame",
		"objective": {"type": "kill", "match": {"map": "away_1", "tier": "elite", "class": "tacklehorn_grazer"}, "count": 1},  # P3: class-keyed — the Nest Broodmother (2nd away_1 elite) must not cross-credit the Bull
		"rewards": {"xp": 520, "credits": 320, "tokens": 25},
	},
	"away2_gauntlet": {
		"name": "The Overrun Gauntlet",
		"desc": "Push into the Overrun Gauntlet and cull 15 of the wildlife pack — watch for the Rallywing shields.",
		"min_level": 10, "prereq": "away1_blocker",
		"objective": {"type": "kill", "match": {"map": "away_2"}, "count": 15},
		"rewards": {"xp": 650, "credits": 420, "tokens": 25},
	},
	"away2_medics": {
		"name": "Cut the Support",
		"desc": "An Elder Rallywing shields the Gauntlet's packs from above while the massive Emerald Warfrog anchors the east. Bring down 2 elites — the support first.",
		"min_level": 11, "prereq": "away2_gauntlet",
		"objective": {"type": "kill", "match": {"map": "away_2", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 800, "credits": 500, "tokens": 35},
	},
	# --- S2: the chain's back half. The two quest epics carry EXPLICIT ilvl + item_power (the
	# _grant_quest_item legacy shape would normalize them to ~IP 27) — they are the deliberate IP-800 push
	# toward the Head Coach gate (bonus_amt matches _make_item's epic budget at ilvl 20: 8×(3+0.4·20)=88).
	"away3_stadium": {
		"name": "Silence the Stadium",
		"desc": "The wilds have reclaimed the stadium floor. Clear it — take down 18 of the pack before the sideline door. Somewhere out there lies a past challenger's badge: the wilds keep what they take.",
		"min_level": 13, "prereq": "away2_medics",
		"objective": {"type": "kill", "match": {"map": "away_3"}, "count": 18},
		"rewards": {"xp": 1000, "credits": 600, "tokens": 30,
			"item": {"name": "Away Captain's Badge", "rarity": "epic", "slot": "trinket", "bonus_stat": "CLU", "bonus_amt": 88, "ilvl": 20, "item_power": 108}},
	},
	"away3_elites": {
		"name": "Clear the Door",
		"desc": "A quill-backed Splinterback prowls the floor and a hulking Warfrog guards the sideline door. Bring down 2 of the Stadium's elites — one of them still carries a fallen challenger's glove.",
		"min_level": 14, "prereq": "away3_stadium",
		"objective": {"type": "kill", "match": {"map": "away_3", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 1200, "credits": 700, "tokens": 35,
			"item": {"name": "Rival Playmaker's Glove", "rarity": "epic", "slot": "main_hand", "bonus_stat": "PWR", "bonus_amt": 88, "ilvl": 20, "item_power": 108}},
	},
	# CAPSTONE — beat the Rival Coach. Completion text routes the player at the existing Head Coach raid
	# gate (L16 + gear 800): the away chain "graduates" into the shipped raid. Repeat kills also pay Pages
	# via the server's RIVAL_PAGES hook; this quest is the once-only dye + credits.
	# --- W7: the Base Camp side chain (WILD_ORDER — same governance as AWAY_ORDER: append-only, never
	# gated on in aggregate). Accepted/turned in at ANY quest giver (Home or the Base Camp's). Matchers
	# target the wildlife BY CLASS — the roster-swap-proof pattern the map matchers can't give us here.
	"wild1_stake": {
		"name": "Stake the Camp",
		"desc": "The Base Camp needs breathing room. Cull 10 of the pack prowling the Reclaimed Stadium.",
		"min_level": 13, "prereq": "",
		"objective": {"type": "kill", "match": {"map": "away_3"}, "count": 10},
		"rewards": {"xp": 900, "credits": 500, "tokens": 25},
	},
	"wild2_grazers": {
		"name": "Thin the Herd",
		"desc": "Tacklehorn Grazers trample every trail we cut. Put down 6 — mind the charge, bait it into walls.",
		"min_level": 13, "prereq": "wild1_stake",
		"objective": {"type": "kill", "match": {"class": "tacklehorn_grazer"}, "count": 6},
		"rewards": {"xp": 1000, "credits": 550, "pages": 20},
	},
	"wild3_rallywings": {
		"name": "Ground the Rallywings",
		"desc": "Their shrieking shield-birds keep the packs standing. Ground 4 Rallywing Magpies — kill the support FIRST.",
		"min_level": 14, "prereq": "wild2_grazers",
		"objective": {"type": "kill", "match": {"class": "rallywing_magpie"}, "count": 4},
		"rewards": {"xp": 1100, "credits": 600, "tokens": 30},
	},
	# the epic carries EXPLICIT ilvl + item_power (the away3/S2 rule — the legacy shape would normalize
	# it to ~IP 27); bonus_amt follows _make_item's epic budget at ilvl 22: 8×(3+0.4·22) = 94.
	"wild4_splinter": {
		"name": "Pull the Quills",
		"desc": "The Splinterback's quills shred our tarps from across the field. Bring it down.",
		"min_level": 15, "prereq": "wild3_rallywings",
		"objective": {"type": "kill", "match": {"class": "splinterback_elite"}, "count": 1},
		"rewards": {"xp": 1300, "credits": 700, "tokens": 35,
			"item": {"name": "Wildwarden's Jacket", "rarity": "epic", "slot": "chest", "bonus_stat": "END", "bonus_amt": 94, "ilvl": 22, "item_power": 116}},
	},
	"wild5_alpha": {
		"name": "The Alpha's Challenge",
		"desc": "The camp will never be safe while the Arrowbound Howler holds the sideline. Fell the alpha and wear the wilds' colors.",
		"min_level": 15, "prereq": "wild4_splinter",
		"objective": {"type": "kill", "match": {"map": "away_boss", "tier": "boss"}, "count": 1},
		"rewards": {"xp": 1600, "credits": 900, "dye": "wildveil"},
	},

	"rival_down": {
		"name": "Fell the Howler",
		"desc": "The Arrowbound Howler leads its pack on the old sideline — break the pack, watch for its shield-bird, and fell the alpha. Then gear up on that sideline until you hit gear score 800, and report to the Head Coach Arena for the real thing.",
		"min_level": 15, "prereq": "away3_elites",
		"objective": {"type": "kill", "match": {"map": "away_boss", "tier": "boss"}, "count": 1},
		"rewards": {"xp": 1600, "credits": 1000, "dye": "rival_crimson"},
	},

	# --- Phase 8 S3: the Finals district chain (18-25 capstone band). The FIRST quest has prereq "" —
	# like finals_gate itself, the chain keys on level+gear, NEVER on the Head Coach kill (a stalled raid
	# must not block the capstone branch). Quest epics again carry EXPLICIT ilvl/item_power (the IP push
	# toward the S4 commissioner_ready gate; amounts match _make_item's epic budget at their ilvls).
	"finals1_contenders": {
		"name": "The Contenders' Quarter",
		"desc": "The championship city is full of contenders warming up. Announce yourself — take down 20 in the Contenders' Quarter.",
		"min_level": 17, "prereq": "",
		"objective": {"type": "kill", "match": {"map": "finals_1"}, "count": 20},
		"rewards": {"xp": 1800, "credits": 900, "tokens": 35},
	},
	"finals1_machines": {
		"name": "Machine Section",
		"desc": "An Iron Sled and a Gatling Ball Machine hold the Quarter's east end. Scrap 2 of its elites.",
		"min_level": 18, "prereq": "finals1_contenders",
		"objective": {"type": "kill", "match": {"map": "finals_1", "tier": "elite"}, "count": 2},
		"rewards": {"xp": 2200, "credits": 1100, "tokens": 40,
			"item": {"name": "Contender's Plate", "rarity": "epic", "slot": "chest", "bonus_stat": "END", "bonus_amt": 101, "ilvl": 24, "item_power": 125}},
	},
	"finals2_gate": {
		"name": "Champions' Gate",
		"desc": "Past the gate, the champions' escort drills at full strength. Put down 20 at the Champions' Gate.",
		"min_level": 20, "prereq": "finals1_machines",
		"objective": {"type": "kill", "match": {"map": "finals_2"}, "count": 20},
		"rewards": {"xp": 2600, "credits": 1400, "tokens": 40},
	},
	"finals2_gallery": {
		"name": "Break the Gallery",
		"desc": "The Grand Gallery — a gilded cannon behind its power cores — rakes the east approach. Drop its cores to break the shield, then bring it down.",
		"min_level": 21, "prereq": "finals2_gate",
		"objective": {"type": "kill", "match": {"map": "finals_2", "class": "grand_gallery"}, "count": 1},
		"rewards": {"xp": 3200, "credits": 1600, "tokens": 45,
			"item": {"name": "Gallery Keeper's Guard", "rarity": "epic", "slot": "off_hand", "bonus_stat": "PRE", "bonus_amt": 107, "ilvl": 26, "item_power": 133}},
	},
}

# stable display/iteration order (also the chain order). ORDER is the SECRET-BOSS GATE list (the server's
# _all_quests_done iterates exactly this) — keep it the original 9; never append the mid-level chain here.
const ORDER := ["gy1_intro", "gy2_push", "gy2_brute", "gy3_clear", "gy3_sled",
	"gy4_clear", "gy4_elites", "gy5_command", "headcoach_down"]

# the mid-level spine (gameplay-length P6a) — a SEPARATE display/chain order, NOT part of the secret gate.
const MIDGAME_ORDER := ["mid1_proving", "mid2_circuit", "mid3_command", "mid4_detail", "mid5_respec",
	"mid6_tower", "mid7_grind", "mid8_veteran", "mid9_legend"]

# Phase 8: the Away Circuit chain — grows per slice (S2 appends away_3/boss quests). GOVERNANCE RULE:
# nothing may EVER gate on AWAY_ORDER completion (no _all_quests_done-style iteration, no portal gate, no
# reward check) — that is what keeps mid-slice appends retroactively safe. Gate on individual quest ids
# (e.g. a specific boss quest) if a gate is ever needed. (The ORDER lesson, above.)
const AWAY_ORDER := ["away1_roadgame", "away1_blocker", "away2_gauntlet", "away2_medics",
	"away3_stadium", "away3_elites", "rival_down"]

# W7: the Base Camp chain — SAME GOVERNANCE as AWAY_ORDER (append-only; NOTHING may ever gate on
# WILD_ORDER completion — gate on individual quest ids if ever needed).
const WILD_ORDER := ["wild1_stake", "wild2_grazers", "wild3_rallywings", "wild4_splinter", "wild5_alpha"]

# Phase 8 S3: the Finals chain — same governance rule as AWAY_ORDER (grows per slice, append-only;
# NOTHING may ever gate on FINALS_ORDER completion — gate on individual quest ids if ever needed).
const FINALS_ORDER := ["finals1_contenders", "finals1_machines", "finals2_gate", "finals2_gallery"]

static func order() -> Array:
	return ORDER

# every quest in display order (original chain, the Away Circuit, its Base Camp side chain, the Finals,
# then the mid-level spine) — for the CLIENT log/tracker/giver only. The server keeps using ORDER for
# the gate and get_quest()/kill_matches() for progress.
static func display_order() -> Array:
	return ORDER + AWAY_ORDER + WILD_ORDER + FINALS_ORDER + MIDGAME_ORDER

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
