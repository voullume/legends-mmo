extends RefCounted
## Legends of the Arena — data layer.
## Direct port of the web sim's ARENA / CLASSES / FORMAT_MODS / derive / createFighter.
## Source of truth: voullume-site/build/apps/legends/app.jsx (v1.0 "Stadium").
## Fighters are plain Dictionaries here (parity with the JS objects); they become
## proper nodes in a later phase.

# --- Arena geometry ---
const ARENA_W := 960
const ARENA_H := 540
const ARENA_PAD := 50

# --- Global tuning constants ---
const SPREAD_DIST := 92.0
const PEEL_HP := 0.35
const PEEL_RANGE := 130.0
const SWAP_HYSTERESIS := 1.22
const TIME_LIMIT := 95.0
const OT_START := 50.0

# --- Classes (stats order: PWR PRE SPD END INS CLU; lane 0=front 1=mid 2=back) ---
const CLASSES := {
	"pitcher": {
		"name": "Pitcher", "sport": "Baseball", "mono": "P", "color": "#58C6FF",
		"lane": 2, "role": "Zone Artillery",
		"stats": {"PWR": 60, "PRE": 70, "SPD": 35, "END": 30, "INS": 35, "CLU": 20},
		"zoneAllyBoost": 1.30, "zoneSelfBoost": 1.35,
		"abilities": [
			{"key": "fastball", "name": "Fastball", "type": "projectile", "basic": true, "dmg": 46, "cd": 1.25, "range": 330, "speed": 430},
			{"key": "curveball", "name": "Curveball", "type": "projectile", "dmg": 64, "cd": 5.0, "range": 310, "speed": 330, "slow": {"amt": 0.30, "dur": 1.5}},
			{"key": "strikezone", "name": "Strike Zone", "type": "zone", "cd": 12, "dur": 5, "radius": 95},
			{"key": "beanball", "name": "Beanball", "type": "projectile", "dmg": 40, "cd": 9, "range": 290, "speed": 480, "stun": 0.9},
			{"key": "perfectgame", "name": "Perfect Game", "type": "barrage", "ult": true, "dmg": 82, "count": 3, "cd": 26, "range": 350, "speed": 460},
		],
	},
	"batter": {
		"name": "Batter", "sport": "Baseball", "mono": "B", "color": "#2F86FF",
		"lane": 1, "role": "Melee Burst",
		"stats": {"PWR": 75, "PRE": 37, "SPD": 40, "END": 48, "INS": 25, "CLU": 25},
		"shieldCrusher": 1.25, "meleeLifesteal": 0.20,
		"abilities": [
			{"key": "swing", "name": "Swing", "type": "melee", "basic": true, "dmg": 57, "cd": 1.3, "range": 62},
			{"key": "powerswing", "name": "Power Swing", "type": "melee", "dmg": 124, "cd": 6.0, "range": 70, "cast": 0.4, "knockback": 60},
			{"key": "slide", "name": "Slide", "type": "dash", "cd": 4.2, "dist": 175, "evade": 0.4, "gapClose": true},
			{"key": "stolenbase", "name": "Stolen Base", "type": "selfbuff", "cd": 9, "buff": {"ms": 1.45, "dur": 2.5}},
			{"key": "grandslam", "name": "Grand Slam", "type": "meleeAoe", "ult": true, "dmg": 235, "cd": 26, "radius": 110, "knockback": 80, "cast": 0.5},
		],
	},
	"quarterback": {
		"name": "Quarterback", "sport": "Football", "mono": "QB", "color": "#51E08A",
		"lane": 0, "role": "Support Tank",
		"stats": {"PWR": 40, "PRE": 40, "SPD": 35, "END": 65, "INS": 45, "CLU": 25},
		"pocketDR": 0.045, "pocketRange": 165,
		"abilities": [
			{"key": "shouldercheck", "name": "Shoulder Check", "type": "melee", "basic": true, "dmg": 50, "cd": 1.35, "range": 60},
			{"key": "huddle", "name": "Huddle Up", "type": "allybuff", "cd": 6.5, "targetType": "ally", "shieldPct": 0.22, "dur": 4.0},
			{"key": "blitz", "name": "Blitz", "type": "allybuff", "cd": 7.5, "targetType": "ally", "buff": {"atkspd": 1.32, "dur": 2.4}},
			{"key": "tackle", "name": "Tackle", "type": "dashAttack", "dmg": 56, "cd": 7, "dist": 150, "slow": {"amt": 0.25, "dur": 1.2}},
			{"key": "sack", "name": "Sack", "type": "melee", "dmg": 16, "cd": 11, "range": 66, "stun": 1.1},
			{"key": "hailmary", "name": "Hail Mary", "type": "projectile", "ult": true, "dmg": 195, "cd": 28, "range": 420, "speed": 520, "teamShieldPct": 0.08},
		],
	},
	"linebacker": {
		"name": "Linebacker", "sport": "Football", "mono": "LB", "color": "#1FA864",
		"lane": 0, "role": "Bruiser",
		"stats": {"PWR": 55, "PRE": 25, "SPD": 30, "END": 80, "INS": 35, "CLU": 25},
		"momentumGain": 0.05, "momentumMax": 5,
		"abilities": [
			{"key": "shed", "name": "Shed Block", "type": "melee", "basic": true, "dmg": 50, "cd": 1.35, "range": 62},
			{"key": "tackle", "name": "Tackle", "type": "dashAttack", "dmg": 70, "cd": 7, "dist": 165, "knockdown": 0.8},
			{"key": "block", "name": "Block", "type": "selfbuff", "cd": 9.8, "buff": {"dr": 0.30, "dur": 2.0}},
			{"key": "bullrush", "name": "Bull Rush", "type": "dashAttack", "dmg": 55, "cd": 8, "dist": 140, "knockback": 70},
			{"key": "fourthgoal", "name": "Fourth & Goal", "type": "dashAttack", "ult": true, "dmg": 220, "cd": 28, "dist": 220, "knockdown": 1.0, "cast": 0.4},
		],
	},
	"setter": {
		"name": "Setter", "sport": "Volleyball", "mono": "S", "color": "#C792EA",
		"lane": 2, "role": "Support",
		"stats": {"PWR": 30, "PRE": 50, "SPD": 40, "END": 50, "INS": 55, "CLU": 25},
		"supportBoost": 1.28, "blockHeal": 0.14, "echoEvery": 6, "echoPct": 0.5,
		"abilities": [
			{"key": "bump", "name": "Bump", "type": "projectile", "basic": true, "dmg": 45, "cd": 1.3, "range": 280, "speed": 380},
			{"key": "set", "name": "Set", "type": "allybuff", "cd": 5.0, "targetType": "ally", "buff": {"nextdmg": 1.70}},
			{"key": "rally", "name": "Rally", "type": "allybuff", "cd": 9, "targetType": "ally", "buff": {"crit": 0.30, "atkspd": 1.20, "dur": 2.6}},
			{"key": "dig", "name": "Dig", "type": "allyheal", "cd": 7, "targetType": "ally", "healPct": 0.15},
			{"key": "rotation", "name": "Rotation", "type": "teamheal", "ult": true, "cd": 30, "healPct": 0.18, "cleanse": true},
		],
	},
	"spiker": {
		"name": "Spiker", "sport": "Volleyball", "mono": "SP", "color": "#9D5CFF",
		"lane": 1, "role": "Burst Assassin",
		"stats": {"PWR": 70, "PRE": 55, "SPD": 50, "END": 30, "INS": 25, "CLU": 20},
		"shieldBypass": 0.40, "airborneDmg": 1.12,
		"abilities": [
			{"key": "serve", "name": "Jump Serve", "type": "projectile", "basic": true, "dmg": 44, "cd": 1.3, "range": 260, "speed": 400},
			{"key": "thunderspike", "name": "Thunderspike", "type": "leapAttack", "dmg": 98, "cd": 6, "dist": 190, "airborne": true},
			{"key": "toolblock", "name": "Tool the Block", "type": "selfbuff", "cd": 12, "buff": {"bypass": true, "dur": 3.0}},
			{"key": "pancake", "name": "Pancake", "type": "dash", "cd": 7, "dist": 150, "evade": 0.35},
			{"key": "killshot", "name": "Kill Shot", "type": "leapAttack", "ult": true, "dmg": 330, "cd": 27, "dist": 240, "airborne": true, "untargetable": 0.6, "cast": 0.35},
		],
	},
	"striker": {
		"name": "Striker", "sport": "Soccer", "mono": "ST", "color": "#FF8A4C",
		"lane": 1, "role": "Finisher",
		"stats": {"PWR": 60, "PRE": 55, "SPD": 65, "END": 25, "INS": 25, "CLU": 20},
		"hatTrickEvery": 2, "hatTrickBonus": 1.30, "chainMS": 1.25, "chainDR": 0.10,
		"lowHPDmg": 1.50, "lowHPThresh": 0.40,
		"abilities": [
			{"key": "finesse", "name": "Finesse Shot", "type": "projectile", "basic": true, "dmg": 46, "cd": 1.25, "range": 240, "speed": 420},
			{"key": "dribble", "name": "Dribble", "type": "dash", "cd": 3.25, "dist": 155},
			{"key": "yellowcard", "name": "Yellow Card", "type": "melee", "dmg": 30, "cd": 7, "range": 64, "stun": 1.0},
			{"key": "clinical", "name": "Clinical Finish", "type": "projectile", "dmg": 84, "cd": 6, "range": 220, "speed": 460},
			{"key": "goldengoal", "name": "Golden Goal", "type": "projectile", "ult": true, "dmg": 255, "cd": 27, "range": 300, "speed": 500, "cast": 0.4, "onKillStealth": 2.0},
		],
	},
	"goalkeeper": {
		"name": "Goalkeeper", "sport": "Soccer", "mono": "GK", "color": "#E4572E",
		"lane": 0, "role": "Guardian",
		"stats": {"PWR": 35, "PRE": 35, "SPD": 30, "END": 75, "INS": 50, "CLU": 25},
		"cleanSheetDelay": 5, "cleanSheetRate": 20, "cleanSheetCap": 190, "reflectMult": 1.6,
		"abilities": [
			{"key": "distribution", "name": "Distribution", "type": "projectile", "basic": true, "dmg": 47, "cd": 1.35, "range": 270, "speed": 400},
			{"key": "header", "name": "Punching Save", "type": "selfbuff", "cd": 9, "buff": {"reflect": true, "dur": 1.2}},
			{"key": "divingsave", "name": "Diving Save", "type": "allybuff", "cd": 8, "targetType": "ally", "shieldPct": 0.20, "dur": 2.0, "dashTo": true},
			{"key": "sweeper", "name": "Sweeper", "type": "meleeAoe", "dmg": 50, "cd": 6, "radius": 90, "slow": {"amt": 0.30, "dur": 1.5}},
			{"key": "penaltysave", "name": "Penalty Save", "type": "barrier", "ult": true, "cd": 30, "dur": 3.0, "dr": 0.70, "blastDmg": 320, "blastRadius": 130},
		],
	},
	# ── Glitchyard mobs (NON-PLAYABLE) ──────────────────────────────────────────────────────────────
	# Flagged mob:true so they're kept out of client PLAYABLE + the AI-duel balance harness's player loop
	# (they ride the same generic AI brain a reskinned class does). Render fields the client reads off its
	# preloaded def: `model` = models/meshy/mobs/<id>.glb basename; `skins` = alt cosmetic GLBs picked
	# per-spawn; `anim` = procedural-animator profile; `h` = rendered world-height (units). Phase 1 kits
	# reuse ONLY existing ability types (melee/dashAttack/meleeAoe/selfbuff/projectile) → no new sim rng.
	# A non-melee basic MUST carry `range` (AI.desired_range reads it); a `reflect` buff needs `reflectMult`.
	"cone_swarmer": {
		"name": "Cone Swarmer", "sport": "", "mob": true, "model": "cone", "anim": "cone", "h": 1.5,
		"lane": 0, "color": "#FF7A1A",
		"stats": {"PWR": 34, "PRE": 30, "SPD": 70, "END": 26, "INS": 20, "CLU": 15},
		"abilities": [
			{"key": "tripjab", "name": "Trip Jab", "type": "melee", "basic": true, "dmg": 30, "cd": 1.1, "range": 52},
			{"key": "tripdash", "name": "Trip Dash", "type": "dashAttack", "dmg": 34, "cd": 5.5, "dist": 150, "slow": {"amt": 0.20, "dur": 1.0}},
		],
	},
	"foam_dummy": {
		"name": "Foam Rookie Dummy", "sport": "", "mob": true, "rig": true, "model": "foam_dummy",
		"skins": ["foam_dummy", "foam_dummy2"], "h": 3.3,   # rigged: real skeletal walk/run/punch/hit/death
		"lane": 0, "color": "#E8D44D",
		"stats": {"PWR": 42, "PRE": 28, "SPD": 30, "END": 44, "INS": 20, "CLU": 18},
		"abilities": [
			{"key": "badform", "name": "Bad Form Swing", "type": "melee", "basic": true, "dmg": 40, "cd": 1.35, "range": 60, "cast": 0.35},
			{"key": "shove", "name": "Practice Shove", "type": "melee", "dmg": 30, "cd": 6.0, "range": 62, "cast": 0.3, "knockback": 55},
		],
	},
	"tackle_brute": {
		"name": "Tackle Bag Brute", "sport": "", "mob": true, "model": "tackle_brute", "anim": "brute", "h": 3.5,
		"lane": 0, "color": "#C0492E",
		"stats": {"PWR": 56, "PRE": 24, "SPD": 26, "END": 70, "INS": 22, "CLU": 20},
		"abilities": [
			{"key": "bagbash", "name": "Bag Bash", "type": "melee", "basic": true, "dmg": 46, "cd": 1.5, "range": 64},
			{"key": "impactcharge", "name": "Impact Charge", "type": "dashAttack", "dmg": 64, "cd": 7.5, "dist": 175, "cast": 0.45, "knockback": 80},
			{"key": "rubberslam", "name": "Rubber Slam", "type": "meleeAoe", "dmg": 40, "cd": 8.0, "radius": 90},
			{"key": "braceup", "name": "Brace Up", "type": "selfbuff", "cd": 11.0, "buff": {"dr": 0.30, "dur": 2.4}},
		],
	},
	"shooting_dummy": {
		"name": "Shooting Dummy", "sport": "", "mob": true, "model": "shooting_dummy",
		"skins": ["shooting_dummy", "shooting_dummy2"], "anim": "turret", "h": 3.2,
		"lane": 2, "color": "#4DA6FF", "reflectMult": 1.4, "stationary": true,   # legless turret — holds position, never chases
		"stats": {"PWR": 46, "PRE": 40, "SPD": 8, "END": 34, "INS": 28, "CLU": 18},
		"abilities": [
			{"key": "practiceshot", "name": "Practice Shot", "type": "projectile", "basic": true, "dmg": 38, "cd": 1.3, "range": 300, "speed": 420},
			{"key": "targetlock", "name": "Target Lock", "type": "projectile", "dmg": 60, "cd": 6.5, "range": 320, "speed": 360, "slow": {"amt": 0.25, "dur": 1.2}},
			{"key": "calibration", "name": "Calibration Spin", "type": "selfbuff", "cd": 12.0, "buff": {"reflect": true, "dur": 1.2}},
		],
	},
	# ── Glitchyard ELITES (Phase 2) ── new primitives: `summon` (server-spawned adds) + hazard `zone`
	# (dmg/slow ground area). Sled + Ball Machine are reuse-only; the Drill Sergeant drives both new ones.
	"drill_sergeant": {
		"name": "Drill Sergeant Dummy", "sport": "", "mob": true, "rig": true, "model": "drill_sergeant", "h": 2.9,
		"lane": 0, "color": "#9AA86B",   # rigged: real skeletal idle/run/punch/hit/death + a shout on cast/summon
		"stats": {"PWR": 48, "PRE": 30, "SPD": 30, "END": 60, "INS": 30, "CLU": 22},
		"abilities": [
			{"key": "raporder", "name": "Bark Order", "type": "melee", "basic": true, "dmg": 40, "cd": 1.4, "range": 62},
			{"key": "clipboardbash", "name": "Clipboard Bash", "type": "melee", "dmg": 30, "cd": 7.5, "range": 64, "stun": 1.0},
			{"key": "conditioning", "name": "Mandatory Conditioning", "type": "summon", "mobType": "cone_swarmer", "count": 3, "cd": 16.0},
			{"key": "drillzone", "name": "Conditioning Drill", "type": "zone", "cd": 11.0, "radius": 115, "dur": 4.5, "dmg": 9.0, "slow": {"amt": 0.30, "dur": 0.5}},
		],
	},
	"sled_juggernaut": {
		"name": "Blocking Sled Juggernaut", "sport": "", "mob": true, "model": "sled_juggernaut", "anim": "brute", "h": 2.9,
		"face": 90.0,                        # model's native front is 90° off — rotate it to face its target
		"lane": 0, "color": "#5566AA",
		"stats": {"PWR": 60, "PRE": 22, "SPD": 18, "END": 90, "INS": 20, "CLU": 20},
		"abilities": [
			{"key": "shoulder", "name": "Shoulder Drive", "type": "melee", "basic": true, "dmg": 48, "cd": 1.6, "range": 66},
			{"key": "driveblock", "name": "Drive Block", "type": "dashAttack", "dmg": 70, "cd": 7.5, "dist": 175, "cast": 0.45, "knockback": 95},
			{"key": "pancakeslam", "name": "Pancake Slam", "type": "meleeAoe", "dmg": 56, "cd": 9.0, "radius": 95, "cast": 0.5, "knockback": 50},
			{"key": "bandlash", "name": "Resistance Band Lash", "type": "melee", "dmg": 34, "cd": 6.0, "range": 72, "slow": {"amt": 0.35, "dur": 1.5}},
		],
	},
	"ball_machine": {
		"name": "Overclocked Ball Machine", "sport": "", "mob": true, "model": "ball_machine", "anim": "turret", "h": 2.4,
		"face": 90.0,                        # native front 90° off (same correction as the sled, empirically)
		"lane": 2, "color": "#D08A2E", "stationary": true,   # turret — holds position
		"stats": {"PWR": 52, "PRE": 45, "SPD": 8, "END": 40, "INS": 28, "CLU": 18},
		"abilities": [
			{"key": "lobshot", "name": "Lob Shot", "type": "projectile", "basic": true, "dmg": 40, "cd": 1.25, "range": 300, "speed": 430},
			{"key": "tripleshot", "name": "Triple Shot", "type": "barrage", "dmg": 36, "count": 3, "cd": 6.0, "range": 320, "speed": 440},
			{"key": "overcharge", "name": "Overcharged Cannon", "type": "projectile", "dmg": 92, "cd": 8.5, "range": 340, "speed": 360, "stun": 0.6},
		],
	},
	# THE BOSS (Phase 4). tier:"boss" (×6 HP via _scale_mob). "phased":true → the Sim runs the HP-fraction
	# phase system: f["phase"] climbs 0→3 across HP bands 100-70 / 70-40 / 40-15 / 15-0, abilities are tagged
	# with a "phase" and unlock at/above it (min-unlock), and ENTERING a new phase fires the one-time
	# "threshSummon" cone wave. The Full Camp Reset ult (type "campreset", phase 3) is an arena-wide AoE that
	# spares fighters whose LOS to the boss is blocked by cover, and is cancelled/weakened by destroying the
	# arena power cores (coreCount). Static GLB + the "boss" procedural animator + per-phase emissive.
	"head_coach": {
		"name": "Head Coach Prototype", "sport": "", "mob": true, "model": "head_coach", "anim": "boss", "h": 4.6,
		"lane": 0, "color": "#C0392B", "phased": true, "coreCount": 4,
		"threshSummon": {"mobType": "cone_swarmer", "count": 2},   # P1/P2/P3 entry each calls a cone wave (SUMMON_CAP-bounded)
		"stats": {"PWR": 56, "PRE": 34, "SPD": 26, "END": 86, "INS": 30, "CLU": 24},
		"abilities": [
			# the ult is listed first so _ab_order tries it first among "specials" once unlocked (phase 3) + off cd
			{"key": "campreset", "name": "Full Camp Reset", "type": "campreset", "dmg": 120, "cd": 15.0, "cast": 3.0, "phase": 3},
			# P0 Evaluation
			{"key": "barkpoint", "name": "Point & Bark", "type": "melee", "basic": true, "dmg": 38, "cd": 1.4, "range": 70, "phase": 0},
			{"key": "clipcheck", "name": "Clipboard Check", "type": "meleeAoe", "dmg": 40, "cd": 6.0, "radius": 95, "cast": 0.5, "phase": 0},
			{"key": "whistle", "name": "Whistle Burst", "type": "meleeAoe", "dmg": 18, "cd": 9.0, "radius": 125, "stun": 0.8, "cast": 0.4, "phase": 0},
			{"key": "formcorrect", "name": "Form Correction", "type": "dashAttack", "dmg": 60, "cd": 8.0, "dist": 190, "cast": 0.4, "phase": 0},
			# P1 Conditioning
			{"key": "ladderlock", "name": "Ladder Lock", "type": "zone", "cd": 12.0, "radius": 120, "dur": 5.0, "slow": {"amt": 0.35, "dur": 0.6}, "phase": 1},
			{"key": "shockwave", "name": "Hurdle Shockwave", "type": "meleeAoe", "dmg": 52, "cd": 10.0, "radius": 155, "cast": 0.7, "knockback": 55, "phase": 1},
			# P2 Contact
			{"key": "sleddrive", "name": "Sled Drive", "type": "dashAttack", "dmg": 80, "cd": 8.0, "dist": 210, "cast": 0.5, "knockback": 110, "phase": 2},
			{"key": "pancake", "name": "Pancake Protocol", "type": "meleeAoe", "dmg": 70, "cd": 9.5, "radius": 110, "cast": 0.55, "knockback": 45, "phase": 2},
		],
	},
	# Power cores — inert destructible objects (team 1, the boss's side). No abilities, stationary → they just
	# sit; players destroy them to weaken/cancel the boss's Full Camp Reset ult (mult = cores_alive/coreCount).
	# "isCore":true → the server tags them no-loot/no-XP. They respawn like any mob, so the counterplay recurs.
	"power_core": {
		"name": "Power Core", "sport": "", "mob": true, "model": "power_core", "anim": "core", "h": 2.0,
		"lane": 1, "color": "#33CCFF", "stationary": true, "isCore": true,
		"stats": {"PWR": 1, "PRE": 1, "SPD": 1, "END": 44, "INS": 1, "CLU": 1},
		"abilities": [],
	},
}

# --- Bracket tuning: per-format dmg/hp/ms multipliers (5v5 is baseline) ---
const FORMAT_MODS := {
	1: {
		"pitcher": {"dmg": 0.90, "hp": 1.10}, "setter": {"dmg": 1.14, "hp": 1.12},
		"quarterback": {"dmg": 0.94}, "goalkeeper": {"dmg": 1.06},
		"batter": {"dmg": 1.20, "hp": 1.08}, "striker": {"dmg": 0.90},
		"linebacker": {"dmg": 0.88}, "spiker": {"dmg": 0.88},
	},
	2: {
		"pitcher": {"dmg": 0.78}, "linebacker": {"dmg": 0.91}, "spiker": {"dmg": 0.91},
		"striker": {"dmg": 0.98}, "quarterback": {"dmg": 1.02}, "goalkeeper": {"dmg": 1.04},
		"batter": {"dmg": 1.24, "hp": 1.08}, "setter": {"dmg": 1.32, "hp": 1.10},
	},
	3: {
		"pitcher": {"dmg": 0.89}, "linebacker": {"dmg": 0.95}, "striker": {"dmg": 0.94},
		"spiker": {"dmg": 0.97}, "goalkeeper": {"dmg": 0.96}, "quarterback": {"dmg": 1.05},
		"batter": {"dmg": 1.24}, "setter": {"dmg": 1.18},
	},
	5: {   # the live MMO format (ZONE_TEAM_SIZE). Tuned so all 8 classes sit ~47-53% in AI duels
	       # (was a 61-point spread: spiker 78% … setter 17%). Mods apply to players AND mobs alike.
		"spiker": {"dmg": 0.82},
		"striker": {"dmg": 0.86},
		"pitcher": {"dmg": 0.93},
		"linebacker": {"dmg": 0.93},
		"batter": {"dmg": 1.30, "hp": 1.12},
		"setter": {"dmg": 1.18, "hp": 1.06},
	},
}

# --- Venues (obstacles are circular rigs that block movement, shots, and LOS) ---
const MAPS := {
	"stadium": {"id": "stadium", "name": "Champions Stadium", "obstacles": []},
	"rooftop": {"id": "rooftop", "name": "Training Tower Rooftop", "obstacles": [
		{"x": 400, "y": 196, "r": 42}, {"x": 560, "y": 344, "r": 42},
		{"x": 480, "y": 96, "r": 24}, {"x": 480, "y": 444, "r": 24}]},
	"centerfield": {"id": "centerfield", "name": "Center Field Park", "obstacles": [{"x": 480, "y": 270, "r": 58}]},
	"sandcourt": {"id": "sandcourt", "name": "The Sand Court", "obstacles": [
		{"x": 480, "y": 140, "r": 30}, {"x": 480, "y": 270, "r": 30}, {"x": 480, "y": 400, "r": 30}]},
	"trenches": {"id": "trenches", "name": "Gridiron Trenches", "obstacles": [
		{"x": 410, "y": 120, "r": 30}, {"x": 410, "y": 193, "r": 30},
		{"x": 550, "y": 347, "r": 30}, {"x": 550, "y": 420, "r": 30}]},
}
const MAP_IDS := ["stadium", "rooftop", "centerfield", "sandcourt", "trenches"]

# --- Item sets (P5): one set per sport. Every item rolls a set_id; the server grants a set bonus for
# wearing N matching EPIC+ pieces (counts/thresholds + the SET_BONUS_CAP live in Server.gd). `stat` is the
# set's signature stat; `th` maps a piece-count threshold → bonus to that stat (bonuses are <= SET_BONUS_CAP).
const SET_DEFS := {
	"baseball":   {"name": "Slugger",   "stat": "PWR", "th": {"2": 8, "4": 15}},
	"football":   {"name": "Gridiron",  "stat": "END", "th": {"2": 8, "4": 15}},
	"volleyball": {"name": "Spiker",    "stat": "PRE", "th": {"2": 8, "4": 15}},
	"soccer":     {"name": "Striker",   "stat": "SPD", "th": {"2": 8, "4": 15}},
}
const SET_IDS := ["baseball", "football", "volleyball", "soccer"]

# --- Crafting (P5): static recipes (no recipes table). Spend scrap → a random item of the given rarity.
# A scrap sink + a way to target gear; the server rolls the item via _make_item and validates the cost.
const RECIPES := [
	{"id": "forge_unc",    "name": "Forge Uncommon Gear", "scrap": 12,  "rarity": "uncommon", "ilvl": 12},
	{"id": "forge_rare",   "name": "Forge Rare Gear",     "scrap": 40,  "rarity": "rare",     "ilvl": 18},
	{"id": "forge_epic",   "name": "Forge Epic Gear",     "scrap": 120, "rarity": "epic",     "ilvl": 26},
	{"id": "forge_unique", "name": "Forge a Unique",      "scrap": 400, "rarity": "epic",     "ilvl": 30, "unique": true},
]

# --- Uniques & procs (P6). A proc is PURE DATA (a fixed effect enum), never a script — so the sim stays
# deterministic. Procs draw NO rng; proc/DOT damage routes through Combat.deal_damage with opts.proc=true
# (which skips the crit rng draw + re-proccing), so a fighter WITH procs draws the same rng as one without.
#   effect:  "DOT" (damage/sec for dur on the target) · "FLAT" (one burst of damage) · "LIFESTEAL" (heal the
#            owner for amt × the hit's damage)
#   trigger: "on_hit" · "on_crit" (more added later: on_kill, on_lowhp)
#   icd:     internal cooldown (s) so a proc can't fire every hit. amt scales with proc_tier (×1 .. ×2).
const PROC_CATALOG := {
	"searing":  {"name": "Searing",  "effect": "DOT",       "trigger": "on_hit",  "amt": 5.0,  "dur": 3.0, "icd": 4.0},
	"crushing": {"name": "Crushing", "effect": "FLAT",      "trigger": "on_crit", "amt": 4.0,  "icd": 1.5},
	"vampiric": {"name": "Vampiric", "effect": "LIFESTEAL", "trigger": "on_hit",  "amt": 0.04, "icd": 1.0},
}
# Procs scale with the wearer's dmgMult, so big procs AMPLIFY the class-dmg gaps FORMAT_MODS balances →
# they're deliberately SMALL (a flavor edge, not a power spike). PROC_DPS_CAP bounds damage procs/sec.
const PROC_DPS_CAP := 18.0
static func proc_amt(proc_id: String, tier: int) -> float:
	return float(PROC_CATALOG.get(proc_id, {}).get("amt", 0.0)) * (1.0 + clampi(tier, 0, 5) * 0.2)

# unique items: a fixed name + slot + signature proc. Stats are generated epic-tier (RARITY_CAP-bound) — the
# identity is the PROC, not a bigger number. Dropped by bosses (rare) or crafted (forge_unique).
const UNIQUE_DEFS := {
	"embermaw":      {"name": "Embermaw",      "slot": "main_hand", "proc_id": "searing"},
	"skullcleaver":  {"name": "Skullcleaver",  "slot": "main_hand", "proc_id": "crushing"},
	"sanguine_band": {"name": "Sanguine Band", "slot": "ring",      "proc_id": "vampiric"},
}
const UNIQUE_IDS := ["embermaw", "skullcleaver", "sanguine_band"]

# Player-selectable classes only (CLASSES now also holds non-playable mob defs flagged mob:true).
# Use this anywhere a player picks/cycles a class and for the AI-duel balance harness — never CLASSES.keys().
static func playable_ids() -> Array:
	var out := []
	for k in CLASSES:
		if not CLASSES[k].get("mob", false):
			out.append(k)
	return out

static func is_mob(class_id: String) -> bool:
	return CLASSES.get(class_id, {}).get("mob", false)

# --- Derived stats (exact formulas from the sim) ---
static func derive(s: Dictionary) -> Dictionary:
	return {
		"maxHP": float(600 + s["END"] * 9),
		"dmgMult": 1.0 + s["PWR"] / 100.0,
		"crit": 0.05 + s["PRE"] * 0.0035 + s["INS"] * 0.001,
		"critMult": 1.6,
		"ms": 95.0 + s["SPD"] * 1.1,
		"cdr": s["INS"] * 0.003,
		"clutchDmg": s["CLU"] * 0.004,
		"clutchDR": s["CLU"] * 0.002,
	}

# --- Fighter factory ---
static func create_fighter(class_id: String, team: int, slot: int, rng, team_size: int = 5) -> Dictionary:
	if not CLASSES.has(class_id):                # defensive: an unknown id used to crash here (and the client)
		push_error("[gamedata] unknown classId '%s' — falling back to 'striker'" % class_id)
		class_id = "striker"
	var c: Dictionary = CLASSES[class_id]
	var d: Dictionary = derive(c["stats"])
	var bm: Dictionary = FORMAT_MODS.get(team_size, {}).get(class_id, {})
	if bm.has("dmg"): d["dmgMult"] *= bm["dmg"]
	if bm.has("hp"): d["maxHP"] = round(d["maxHP"] * bm["hp"])
	if bm.has("ms"): d["ms"] *= bm["ms"]
	var lane_x: Array = [150, 235, 320] if team == 0 else [ARENA_W - 150, ARENA_W - 235, ARENA_W - 320]
	var y_frac: float = 0.5 + (slot - (team_size - 1) / 2.0) * 0.16
	var cds: Dictionary = {}
	for a in c["abilities"]:
		cds[a["key"]] = 0.0
	return {
		"id": "%d-%d" % [team, slot], "classId": class_id, "team": team, "slot": slot,
		"x": lane_x[c["lane"]] + (rng.next() - 0.5) * 20.0,
		"y": ARENA_H * y_frac + (rng.next() - 0.5) * 16.0,
		"hp": d["maxHP"], "maxHP": d["maxHP"], "shield": 0.0, "shieldT": 0.0,
		"dmgMult": d["dmgMult"], "crit": d["crit"], "critMult": d["critMult"],
		"ms": d["ms"], "cdr": d["cdr"], "clutchDmg": d["clutchDmg"], "clutchDR": d["clutchDR"],
		"cds": cds,
		"casting": null, "stun": 0.0, "slowT": 0.0, "slowAmt": 0.0, "evade": 0.0, "untarget": 0.0,
		"buffs": {"nextdmg": 0.0, "crit": 0.0, "critT": 0.0, "atkspd": 1.0, "atkspdT": 0.0,
			"dr": 0.0, "drT": 0.0, "ms": 1.0, "msT": 0.0, "bypass": 0.0, "reflect": 0.0},
		"momentum": 0.0, "momentumT": 0.0, "chaseT": 0.0, "atkCommitT": 0.0,
		"hatTarget": null, "hatCount": 0, "hatChainT": 0.0,
		"supportCasts": 0, "noDmgT": 0.0,
		"barrier": 0.0, "barrierT": 0.0, "barrierStored": 0.0, "_barrierAb": null,
		"alive": true, "deathT": 0.0, "_pocketDR": 0.0, "flash": 0.0,
		"dmgDealt": 0.0, "dmgTaken": 0.0, "healing": 0.0, "mitigated": 0.0, "kills": 0,
		# movement / heading state
		"strafeDir": (1 if (team + slot) % 2 == 0 else -1),
		"hx": float(1 if team == 0 else -1), "hy": 0.0,
		"moveMode": "approach", "flipT": 0.0,
		"facing": (1 if team == 0 else -1),
		# procs (P6): procs = this fighter's equipped-item effects; _procT = per-proc ICD; dots = active
		# damage-over-time on this fighter; _procDmg/_procWin = the per-second proc-damage cap window.
		"procs": [], "_procT": {}, "dots": [], "_procDmg": 0.0, "_procWin": 1.0,
		# boss (Phase 4): HP-gated phase (0 for everyone else — inert) + the per-phase threshold-summon latch.
		# In `fresh` so Server._revive auto-resets them on respawn (a respawned boss re-runs all phases).
		"phase": 0, "_threshSummoned": {},
	}
