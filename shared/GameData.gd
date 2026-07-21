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
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "fastball", "name": "Fastball", "type": "projectile", "basic": true, "dmg": 46, "cd": 1.25, "range": 330, "speed": 430,
				"desc": "A quick pitch that pelts the target."},
			{"key": "curveball", "name": "Curveball", "type": "projectile", "dmg": 64, "cd": 5.0, "range": 310, "speed": 330, "slow": {"amt": 0.30, "dur": 1.5},
				"desc": "A bending pitch that slows the target."},
			{"key": "pickoff", "name": "Pickoff Move", "type": "dash", "cd": 7, "dist": 145, "evade": 0.25,
				"desc": "A quick-step dash off the mound; briefly evades all attacks."},
			{"key": "strikezone", "name": "Strike Zone", "type": "zone", "cd": 12, "dur": 5, "radius": 95,
				"desc": "Paint a zone: your projectiles into it hit harder, allies' shots too."},
			{"key": "changeup", "name": "Changeup", "type": "projectile", "dmg": 42, "cd": 8, "range": 300, "speed": 285, "slow": {"amt": 0.35, "dur": 2.0},
				"desc": "A deceptive off-speed ball that heavily slows the target."},
			{"key": "beanball", "name": "Beanball", "type": "projectile", "dmg": 40, "cd": 9, "range": 290, "speed": 480, "stun": 0.9,
				"desc": "A wild inside fastball that stuns the target."},
			{"key": "moundpresence", "name": "Mound Presence", "type": "selfbuff", "cd": 12, "aiPressure": true, "buff": {"dr": 0.22, "ms": 1.20, "dur": 2.5},
				"desc": "Dig in on the mound: take less damage and move faster for a moment."},
			{"key": "perfectgame", "name": "Perfect Game", "type": "barrage", "ult": true, "dmg": 82, "count": 3, "cd": 26, "range": 350, "speed": 460,
				"desc": "Unleash three full-heat fastballs in a row."},
		],
	},
	"batter": {
		"name": "Batter", "sport": "Baseball", "mono": "B", "color": "#2F86FF",
		"lane": 1, "role": "Melee Burst",
		"stats": {"PWR": 75, "PRE": 37, "SPD": 40, "END": 48, "INS": 25, "CLU": 25},
		"shieldCrusher": 1.25, "meleeLifesteal": 0.20,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "swing", "name": "Swing", "type": "melee", "basic": true, "dmg": 57, "cd": 1.3, "range": 62,
				"desc": "A bat swing. Your melee hits heal you for a cut of the damage."},
			{"key": "powerswing", "name": "Power Swing", "type": "melee", "dmg": 124, "cd": 6.0, "range": 70, "cast": 0.4, "knockback": 60,
				"desc": "A wound-up slugger swing that knocks the target back."},
			{"key": "slide", "name": "Slide", "type": "dash", "cd": 4.2, "dist": 175, "evade": 0.4, "gapClose": true,
				"desc": "Dive into or out of the play; briefly evades all attacks."},
			{"key": "checkswing", "name": "Check Swing", "type": "selfbuff", "cd": 10, "buff": {"dr": 0.28, "dur": 1.5},
				"desc": "Hold the swing and brace: sharply reduced damage taken, briefly."},
			{"key": "batflip", "name": "Bat Flip", "type": "meleeAoe", "dmg": 65, "cd": 8, "radius": 88, "knockback": 35,
				"desc": "Flip the bat in a taunting arc: damages and knocks back everyone nearby."},
			{"key": "stolenbase", "name": "Stolen Base", "type": "selfbuff", "cd": 9, "buff": {"ms": 1.45, "dur": 2.5},
				"desc": "Take off for the next bag: a burst of move speed."},
			{"key": "walkoff", "name": "Walk-Off", "type": "melee", "dmg": 92, "cd": 11, "range": 68, "onHitSelfShieldPct": 0.12, "onHitSelfShieldDur": 3.0,
				"desc": "A game-ending blow: a clean hit also shields you."},
			{"key": "grandslam", "name": "Grand Slam", "type": "meleeAoe", "ult": true, "dmg": 235, "cd": 26, "radius": 110, "knockback": 80, "cast": 0.5,
				"desc": "A colossal swing: heavy damage and a big knockback all around you."},
		],
	},
	"quarterback": {
		"name": "Quarterback", "sport": "Football", "mono": "QB", "color": "#51E08A",
		"lane": 0, "role": "Support Tank",
		"stats": {"PWR": 40, "PRE": 40, "SPD": 35, "END": 65, "INS": 45, "CLU": 25},
		"pocketDR": 0.045, "pocketRange": 165,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "shouldercheck", "name": "Shoulder Check", "type": "melee", "basic": true, "dmg": 50, "cd": 1.35, "range": 60,
				"desc": "A shoulder-first jab."},
			{"key": "huddle", "name": "Huddle Up", "type": "allybuff", "cd": 6.5, "targetType": "ally", "shieldPct": 0.22, "dur": 4.0,
				"desc": "Call the huddle: shield an ally."},
			{"key": "scramble", "name": "Scramble", "type": "dash", "cd": 8, "dist": 140, "evade": 0.2, "selfBuff": {"dr": 0.20, "dur": 1.5},
				"desc": "Escape the pocket: dash with brief evasion, then shrug off damage."},
			{"key": "blitz", "name": "Blitz", "type": "allybuff", "cd": 7.5, "targetType": "ally", "buff": {"atkspd": 1.32, "dur": 2.4},
				"desc": "Fire up an ally: faster basic attacks."},
			{"key": "tackle", "name": "Tackle", "type": "dashAttack", "dmg": 56, "cd": 7, "dist": 150, "slow": {"amt": 0.25, "dur": 1.2},
				"desc": "Charge a target, hit, and slow them."},
			{"key": "sack", "name": "Sack", "type": "melee", "dmg": 16, "cd": 11, "range": 66, "stun": 1.1,
				"desc": "A wrap-up hit that stuns the target."},
			{"key": "playaction", "name": "Play Action", "type": "allybuff", "cd": 11, "targetType": "ally", "buff": {"ms": 1.25, "dr": 0.15, "dur": 2.5},
				"desc": "Fake the hand-off: an ally moves faster and takes less damage."},
			{"key": "hailmary", "name": "Hail Mary", "type": "projectile", "ult": true, "dmg": 195, "cd": 28, "range": 420, "speed": 520, "teamShieldPct": 0.08,
				"desc": "A deep bomb: on a connecting hit, shields every ally."},
		],
	},
	"linebacker": {
		"name": "Linebacker", "sport": "Football", "mono": "LB", "color": "#1FA864",
		"lane": 0, "role": "Bruiser",
		"stats": {"PWR": 55, "PRE": 25, "SPD": 30, "END": 80, "INS": 35, "CLU": 25},
		"momentumGain": 0.05, "momentumMax": 5,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "shed", "name": "Shed Block", "type": "melee", "basic": true, "dmg": 50, "cd": 1.35, "range": 62,
				"desc": "Shed a blocker and strike. Melee hits build Momentum (stacking damage)."},
			{"key": "tackle", "name": "Tackle", "type": "dashAttack", "dmg": 70, "cd": 7, "dist": 165, "knockdown": 0.8,
				"desc": "Charge and flatten the target."},
			{"key": "block", "name": "Block", "type": "selfbuff", "cd": 9.8, "buff": {"dr": 0.30, "dur": 2.0},
				"desc": "Set your base: take much less damage, briefly."},
			{"key": "stripball", "name": "Strip Ball", "type": "melee", "dmg": 54, "cd": 10, "range": 64, "dispelBuffs": 1,
				"desc": "Punch the ball out: a connecting hit strips one enemy buff."},
			{"key": "bullrush", "name": "Bull Rush", "type": "dashAttack", "dmg": 55, "cd": 8, "dist": 140, "knockback": 70,
				"desc": "Charge through the line, knocking the target back."},
			{"key": "crackback", "name": "Crackback", "type": "meleeAoe", "dmg": 58, "cd": 9, "radius": 92, "slow": {"amt": 0.25, "dur": 1.5},
				"desc": "A blindside sweep: damages and slows everyone nearby."},
			{"key": "goalstand", "name": "Goal-Line Stand", "type": "selfbuff", "cd": 14, "aiPressure": true, "buff": {"dr": 0.35, "ms": 0.80, "dur": 3.0},
				"desc": "Anchor the line: heavy damage reduction, but you move slower."},
			{"key": "fourthgoal", "name": "Fourth & Goal", "type": "dashAttack", "ult": true, "dmg": 220, "cd": 28, "dist": 220, "knockdown": 1.0, "cast": 0.4,
				"desc": "An unstoppable goal-line charge: massive damage and a knockdown."},
		],
	},
	"setter": {
		"name": "Setter", "sport": "Volleyball", "mono": "S", "color": "#C792EA",
		"lane": 2, "role": "Support",
		"stats": {"PWR": 30, "PRE": 50, "SPD": 40, "END": 50, "INS": 55, "CLU": 25},
		"supportBoost": 1.28, "blockHeal": 0.14, "echoEvery": 6, "echoPct": 0.5,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "bump", "name": "Bump", "type": "projectile", "basic": true, "dmg": 45, "cd": 1.3, "range": 280, "speed": 380,
				"desc": "A precise pass turned projectile."},
			{"key": "set", "name": "Set", "type": "allybuff", "cd": 5.0, "targetType": "ally", "buff": {"nextdmg": 1.70},
				"desc": "Set up an ally: their next special hits much harder."},
			{"key": "cover", "name": "Cover", "type": "dash", "cd": 7, "dist": 135, "evade": 0.3,
				"desc": "Slide under the play: dash with brief evasion."},
			{"key": "rally", "name": "Rally", "type": "allybuff", "cd": 9, "targetType": "ally", "buff": {"crit": 0.30, "atkspd": 1.20, "dur": 2.6},
				"desc": "Rally an ally: bonus crit chance and faster basics."},
			{"key": "quickset", "name": "Quick Set", "type": "allybuff", "cd": 8, "targetType": "ally", "buff": {"ms": 1.35, "dur": 3.0},
				"desc": "Run the quick tempo: an ally moves much faster."},
			{"key": "dig", "name": "Dig", "type": "allyheal", "cd": 7, "targetType": "ally", "healPct": 0.15,
				"desc": "Dig the attack out: heal an ally."},
			{"key": "joust", "name": "Joust", "type": "projectile", "dmg": 50, "cd": 9, "range": 270, "speed": 410, "slow": {"amt": 0.25, "dur": 1.5},
				"desc": "Contest at the net: damages and slows the target."},
			{"key": "rotation", "name": "Rotation", "type": "teamheal", "ult": true, "cd": 30, "healPct": 0.18, "cleanse": true,
				"desc": "Rotate the lineup: heal the whole team and cleanse stuns and slows."},
		],
	},
	"spiker": {
		"name": "Spiker", "sport": "Volleyball", "mono": "SP", "color": "#9D5CFF",
		"lane": 1, "role": "Burst Assassin",
		"stats": {"PWR": 70, "PRE": 55, "SPD": 50, "END": 30, "INS": 25, "CLU": 20},
		"shieldBypass": 0.40, "airborneDmg": 1.12,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "serve", "name": "Jump Serve", "type": "projectile", "basic": true, "dmg": 44, "cd": 1.3, "range": 260, "speed": 400,
				"desc": "A leaping serve fired at the target."},
			{"key": "approach", "name": "Approach", "type": "dash", "cd": 6, "dist": 120, "selfBuff": {"ms": 1.20, "dur": 1.5},
				"desc": "Explosive approach steps: dash, then keep the momentum."},
			{"key": "thunderspike", "name": "Thunderspike", "type": "leapAttack", "dmg": 98, "cd": 6, "dist": 190, "airborne": true,
				"desc": "Leap to the target and spike down (bonus damage while airborne)."},
			{"key": "toolblock", "name": "Tool the Block", "type": "selfbuff", "cd": 12, "buff": {"bypass": true, "dur": 3.0},
				"desc": "Aim off the blocker's hands: your hits pierce enemy shields."},
			{"key": "rollshot", "name": "Roll Shot", "type": "projectile", "dmg": 58, "cd": 8, "range": 250, "speed": 350, "slow": {"amt": 0.30, "dur": 1.4},
				"desc": "A soft roll shot that slows the target."},
			{"key": "pancake", "name": "Pancake", "type": "dash", "cd": 7, "dist": 150, "evade": 0.35,
				"desc": "Dive flat to the floor: dash with brief evasion."},
			{"key": "roofblock", "name": "Roof Block", "type": "selfbuff", "cd": 12, "buff": {"dr": 0.25, "dur": 2.0, "guard": {"charges": 1, "kb": 45.0}},
				"desc": "Put up a roof: take less damage, and the first melee attacker is knocked back."},
			{"key": "killshot", "name": "Kill Shot", "type": "leapAttack", "ult": true, "dmg": 330, "cd": 27, "dist": 240, "airborne": true, "untargetable": 0.6, "cast": 0.35,
				"desc": "Leap untargetable and bury the kill shot."},
		],
	},
	"striker": {
		"name": "Striker", "sport": "Soccer", "mono": "ST", "color": "#FF8A4C",
		"lane": 1, "role": "Finisher",
		"stats": {"PWR": 60, "PRE": 55, "SPD": 65, "END": 25, "INS": 25, "CLU": 20},
		"hatTrickEvery": 2, "hatTrickBonus": 1.30, "chainMS": 1.25, "chainDR": 0.10,
		"lowHPDmg": 1.50, "lowHPThresh": 0.40,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "finesse", "name": "Finesse Shot", "type": "projectile", "basic": true, "dmg": 46, "cd": 1.25, "range": 240, "speed": 420,
				"desc": "A curled shot. Repeated hits on one target chain into Hat Trick bonuses."},
			{"key": "dribble", "name": "Dribble", "type": "dash", "cd": 3.25, "dist": 155,
				"desc": "A burst dribble: quick dash on a short cooldown."},
			{"key": "yellowcard", "name": "Yellow Card", "type": "melee", "dmg": 30, "cd": 7, "range": 64, "stun": 1.0,
				"desc": "A cynical foul that stuns the target."},
			{"key": "stepover", "name": "Step Over", "type": "selfbuff", "cd": 9, "buff": {"ms": 1.35, "dr": 0.15, "dur": 2.0},
				"desc": "Sell the feint: move faster and take less damage."},
			{"key": "clinical", "name": "Clinical Finish", "type": "projectile", "dmg": 84, "cd": 6, "range": 220, "speed": 460,
				"desc": "A clinical strike: bonus damage against badly hurt targets."},
			{"key": "throughball", "name": "Through Ball", "type": "projectile", "dmg": 52, "cd": 7, "range": 300, "speed": 500, "slow": {"amt": 0.20, "dur": 1.2},
				"desc": "A driven ball that slows the target."},
			{"key": "bicyclekick", "name": "Bicycle Kick", "type": "leapAttack", "dmg": 105, "cd": 11, "dist": 170, "airborne": true,
				"desc": "Leap to the target and strike overhead."},
			{"key": "goldengoal", "name": "Golden Goal", "type": "projectile", "ult": true, "dmg": 255, "cd": 27, "range": 300, "speed": 500, "cast": 0.4,
				"onKillBuff": {"ms": 1.45, "dr": 0.15, "dur": 2.0},
				"desc": "Wind up the match-winner. Scoring the kill grants a burst of speed and toughness."},
		],
	},
	"goalkeeper": {
		"name": "Goalkeeper", "sport": "Soccer", "mono": "GK", "color": "#E4572E",
		"lane": 0, "role": "Guardian",
		"stats": {"PWR": 35, "PRE": 35, "SPD": 30, "END": 75, "INS": 50, "CLU": 25},
		"cleanSheetDelay": 5, "cleanSheetRate": 20, "cleanSheetCap": 190, "reflectMult": 1.6,
		# 8-skill kit: slot 1 = basic, 2-7 = specials (unlock order), 8 = ult
		"abilities": [
			{"key": "distribution", "name": "Distribution", "type": "projectile", "basic": true, "dmg": 47, "cd": 1.35, "range": 270, "speed": 400,
				"desc": "A sharp throw at the target."},
			{"key": "header", "name": "Punching Save", "type": "selfbuff", "cd": 9, "buff": {"reflect": true, "dur": 1.2},
				"desc": "Read the shot: reflect the next hit back at the attacker, amplified."},
			{"key": "divingsave", "name": "Diving Save", "type": "allybuff", "cd": 8, "targetType": "ally", "shieldPct": 0.20, "dur": 2.0, "dashTo": true,
				"desc": "Dive to an ally and shield them."},
			{"key": "keeperrush", "name": "Keeper Rush", "type": "dashAttack", "dmg": 42, "cd": 8, "dist": 145, "slow": {"amt": 0.30, "dur": 1.5},
				"desc": "Rush off the line: a dash attack that slows the target."},
			{"key": "sweeper", "name": "Sweeper", "type": "meleeAoe", "dmg": 50, "cd": 6, "radius": 90, "slow": {"amt": 0.30, "dur": 1.5},
				"desc": "Sweep the box: damages and slows everyone nearby."},
			{"key": "claimcross", "name": "Claim the Cross", "type": "selfbuff", "cd": 11, "aiPressure": true, "buff": {"dr": 0.25, "ms": 1.30, "dur": 2.5},
				"desc": "Command the area: take less damage and move faster."},
			{"key": "rollout", "name": "Roll Out", "type": "allybuff", "cd": 10, "targetType": "ally", "shieldPct": 0.12, "dur": 2.5, "buff": {"ms": 1.25, "dur": 2.5},
				"desc": "Roll the ball out: shield an ally and speed them up."},
			{"key": "penaltysave", "name": "Penalty Save", "type": "barrier", "ult": true, "cd": 30, "dur": 3.0, "dr": 0.70, "blastDmg": 320, "blastRadius": 130,
				"desc": "An impenetrable stance, ending in a blast that grows with damage soaked."},
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
		"lane": 0, "color": "#9AA86B", "kbImmune": true,   # rigged: real skeletal idle/run/punch/hit/death + a shout on cast/summon
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
		"lane": 0, "color": "#5566AA", "kbImmune": true, "frontalDR": 0.55,   # a blocking sled: immovable + frontal armor (flank it)
		"stats": {"PWR": 60, "PRE": 22, "SPD": 18, "END": 90, "INS": 20, "CLU": 20},
		"abilities": [
			{"key": "shoulder", "name": "Shoulder Drive", "type": "melee", "basic": true, "dmg": 48, "cd": 1.6, "range": 66},
			{"key": "driveblock", "name": "Drive Block", "type": "dashAttack", "dmg": 70, "cd": 7.5, "dist": 175, "cast": 0.45, "knockback": 95, "wallStun": 1.5},
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
			{"key": "lobshot", "name": "Lob Shot", "type": "projectile", "basic": true, "dmg": 40, "cd": 1.25, "range": 300, "speed": 430, "wobble": 1},   # sustained fire stacks Wobble (cd 1.25 < decay 2.0 → builds while you facetank)
			{"key": "scatter", "name": "Scatter Volley", "type": "spread", "dmg": 24, "count": 5, "arc": 0.7, "cd": 7.0, "range": 320, "speed": 420, "wobble": 1},   # 5-shot fan also stacks Wobble
			{"key": "bankshot", "name": "Bank Shot", "type": "spread", "dmg": 44, "count": 2, "arc": 0.22, "cd": 9.0, "range": 340, "speed": 380, "bounces": 2},   # ricochets off cover walls
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
		"lane": 0, "color": "#C0392B", "phased": true, "coreCount": 4, "kbImmune": true,
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
			{"key": "sleddrive", "name": "Sled Drive", "type": "dashAttack", "dmg": 80, "cd": 8.0, "dist": 210, "cast": 0.5, "knockback": 110, "wallStun": 1.4, "phase": 2},
			{"key": "pancake", "name": "Pancake Protocol", "type": "meleeAoe", "dmg": 70, "cd": 9.5, "radius": 110, "cast": 0.55, "knockback": 45, "phase": 2},
			{"key": "respull", "name": "Resistance Pull", "type": "meleeAoe", "dmg": 28, "cd": 11.0, "radius": 300, "cast": 0.8, "pull": 220, "phase": 2},   # yanks players OFF cover toward the boss
		],
	},
	# Phase 8 S2 — THE RIVAL COACH (the Away Circuit's capstone, docs/phase8-away-circuit-plan.md). The
	# TEACHING boss: deliberately ONE PRIMITIVE TIER below the Head Coach raid — phased + threshSummon +
	# hazard zone + coreShield/cores, but NO campreset ult (no LOS dance yet; that's the raid's lesson).
	# head_coach.glb in rival crimson (recolor channel) at a smaller h — the away-jersey thesis: he IS
	# literally another coach. Fought AT-level (16) solo-first: dmgScale is the solo-viability dial
	# (playtest-tunable), respawnS 600 (a leveling-chain quest boss, not a 30-min endgame event).
	# NOTE (W5): the Arrowbound Howler took the sideline — this def is kept DORMANT (golden-
	# fingerprinted, admin-spawnable) like rally_cone; the owner may re-seat it elsewhere later.
	"rival_coach": {
		"name": "The Rival Coach", "sport": "", "mob": true, "model": "head_coach", "anim": "boss", "h": 4.2,
		"lane": 0, "color": "#C43C2E", "recolor": true, "phased": true, "coreCount": 3, "kbImmune": true,
		# review-tuned to keep the "one tier below the raid" promise NUMERICALLY at the same player power:
		# hpMult 0.6 lands the lvl-16 pool at ≈ the Head Coach's (34k vs 32.8k); dmgScale 0.6 is exact melee
		# parity (2.352×0.6 = the HC's 1.411) — and the rival has no ult, so it IS strictly the easier boss.
		# Respawn stays the shipped 30-min boss cadence (headcoach_down precedent; a 600s cadence made this
		# the game's best pages/loot farm). The CORES carry the fast respawn instead — see rival_core.
		"coreShield": 0.40, "hpMult": 0.6, "dmgScale": 0.6,
		"plate": "RIVAL COACH", "phases": ["FILM STUDY", "CONDITIONING", "CONTACT", "GARBAGE TIME"],
		"threshSummon": {"mobType": "cone_swarmer", "count": 2},   # NOT rally_cone — a support add would shield the boss's huge pool
		"stats": {"PWR": 54, "PRE": 32, "SPD": 26, "END": 82, "INS": 28, "CLU": 24},
		"abilities": [
			# P0 Film Study
			{"key": "rivalbark", "name": "Sideline Bark", "type": "melee", "basic": true, "dmg": 40, "cd": 1.4, "range": 70, "phase": 0},
			{"key": "rivalclip", "name": "Playbook Slam", "type": "meleeAoe", "dmg": 42, "cd": 6.0, "radius": 95, "cast": 0.5, "phase": 0},
			# P1 Conditioning — the hazard lesson
			{"key": "rivalladder", "name": "Away Drills", "type": "zone", "cd": 12.0, "radius": 120, "dur": 5.0, "dmg": 8.0, "slow": {"amt": 0.35, "dur": 0.6}, "phase": 1},
			{"key": "rivalshock", "name": "Crowd Surge", "type": "meleeAoe", "dmg": 54, "cd": 10.0, "radius": 150, "cast": 0.7, "knockback": 55, "phase": 1},
			# P2 Contact
			{"key": "rivalsled", "name": "Rival Sled Drive", "type": "dashAttack", "dmg": 78, "cd": 8.0, "dist": 200, "cast": 0.5, "knockback": 100, "wallStun": 1.3, "phase": 2},
			# P3 Garbage Time
			{"key": "rivalwhistle", "name": "Final Whistle Burst", "type": "meleeAoe", "dmg": 20, "cd": 8.0, "radius": 130, "stun": 0.9, "cast": 0.4, "phase": 3},
			{"key": "rivalpancake", "name": "Statement Slam", "type": "meleeAoe", "dmg": 70, "cd": 9.0, "radius": 110, "cast": 0.55, "knockback": 45, "phase": 3},
		],
	},
	# THE SECRET BOSS (Boss2) — Head Coach PRIME. Reachable only via the gated portal in the boss arena, which
	# unlocks once a character has completed EVERY Glitchyard quest (incl. the headcoach_down capstone = beating
	# Boss1). A 10+ minute raid: a huge HP pool (hpMult on top of tier:boss ×6), 4 HP phases, the full P5 kit
	# intensified, and CORE-SHIELD — it takes `coreShield` less damage while ANY of its power cores live, so the
	# team must keep the (respawning) cores down to make a dent. Static GLB (boss2) + the "boss" animator.
	"head_coach_prime": {
		"name": "Head Coach PRIME", "sport": "", "mob": true, "model": "boss2", "anim": "boss", "h": 6.0,
		"lane": 0, "color": "#8E2DE2", "phased": true, "coreCount": 6, "kbImmune": true,
		"hpMult": 6.0, "coreShield": 0.55, "dmgScale": 0.55,   # ×6 HP; 55% DR while a core lives (kill them!); damage dialed so a geared team survives + PROGRESSES the phases (so the ult/mechanics engage) over ~10+ min. (Very tunable — playtest the length; dial hpMult up if too fast, down if a wall.)
		"threshSummon": {"mobType": "cone_swarmer", "count": 3},   # a bigger wave per phase entry
		"stats": {"PWR": 64, "PRE": 38, "SPD": 30, "END": 96, "INS": 34, "CLU": 28},
		"abilities": [
			# the ult unlocks at phase 2 + fires often — the cover LOS-spare is the recurring survival check
			{"key": "totalreset", "name": "Total Camp Reset", "type": "campreset", "dmg": 150, "cd": 12.0, "cast": 3.0, "phase": 2},
			# P0
			{"key": "primebark", "name": "Prime Bark", "type": "melee", "basic": true, "dmg": 50, "cd": 1.3, "range": 74, "phase": 0},
			{"key": "primeclip", "name": "Clipboard Storm", "type": "meleeAoe", "dmg": 50, "cd": 5.5, "radius": 115, "cast": 0.5, "phase": 0},
			{"key": "primeform", "name": "Form Correction", "type": "dashAttack", "dmg": 70, "cd": 7.0, "dist": 220, "cast": 0.4, "wallStun": 1.4, "phase": 0},
			# P1
			{"key": "primeladder", "name": "Conditioning Grid", "type": "zone", "cd": 9.0, "radius": 140, "dur": 6.0, "dmg": 12.0, "slow": {"amt": 0.4, "dur": 0.6}, "phase": 1},
			{"key": "primeshock", "name": "Hurdle Shockwave", "type": "meleeAoe", "dmg": 60, "cd": 8.0, "radius": 175, "cast": 0.6, "knockback": 60, "phase": 1},
			# P2
			{"key": "primesled", "name": "Sled Drive", "type": "dashAttack", "dmg": 95, "cd": 7.0, "dist": 240, "cast": 0.5, "knockback": 120, "wallStun": 1.6, "phase": 2},
			{"key": "primepull", "name": "Resistance Pull", "type": "meleeAoe", "dmg": 35, "cd": 9.0, "radius": 340, "cast": 0.7, "pull": 260, "phase": 2},
			# P3 (final band — the phase ladder is 4 bands: 0/1/2/3, so the kit fully unlocks here)
			{"key": "primepancake", "name": "Pancake Protocol", "type": "meleeAoe", "dmg": 85, "cd": 8.0, "radius": 130, "cast": 0.5, "knockback": 50, "phase": 3},
			{"key": "primewhistle", "name": "Whistle Burst", "type": "meleeAoe", "dmg": 26, "cd": 7.0, "radius": 155, "stun": 1.0, "cast": 0.4, "phase": 3},
		],
	},
	# Phase 8 S3 — THE GRAND GALLERY: the Finals district's farmable ELITE-PLUS miniboss (the plan's
	# "repeatable skill-check instead of a portal-blocking 30-min event"). Elite tier + hpMult 3.0 +
	# coreShield 0.35 behind 2 slow-respawn rival_cores → the S2 core-window lesson at endgame pace.
	# respawnS 120: farmable, but not an instant turret camp. Gold recolor + h 3.0 (silhouette by scale).
	"grand_gallery": {
		"name": "The Grand Gallery", "sport": "", "mob": true, "model": "ball_machine", "anim": "turret", "h": 3.0,
		"face": 90.0,
		"lane": 2, "color": "#D4AF37", "recolor": true, "stationary": true,
		"hpMult": 3.0, "coreShield": 0.35, "respawnS": 120.0,
		"stats": {"PWR": 56, "PRE": 48, "SPD": 8, "END": 46, "INS": 30, "CLU": 20},
		"abilities": [
			{"key": "galleryshot", "name": "Gallery Shot", "type": "projectile", "basic": true, "dmg": 40, "cd": 1.15, "range": 310, "speed": 440, "wobble": 1},
			{"key": "galleryfan", "name": "Trophy Fan", "type": "spread", "dmg": 24, "count": 7, "arc": 0.9, "cd": 6.5, "range": 310, "speed": 430, "wobble": 1},
			{"key": "gallerycarom", "name": "Gilded Carom", "type": "spread", "dmg": 44, "count": 2, "arc": 0.22, "cd": 9.0, "range": 320, "speed": 420, "bounces": 2},
			{"key": "galleryburst", "name": "Golden Burst", "type": "projectile", "dmg": 96, "cd": 8.5, "range": 330, "speed": 380, "stun": 0.5},
		],
	},
	# Phase 8 S2 — the Rival Sideline's cores. The GY power_core respawns on the 6-s minion cadence, which is
	# correct for a 5-player raid splitting across cores but makes an ALL-DEAD shield window unreachable solo
	# (the review's arithmetic: a solo needs ~8s/core; the first is back before the third dies). This variant
	# carries a per-def respawnS 45 so a solo rotation (~24-28s for 3 cores) EARNS a real ~17-20s shield-down
	# burst window — the teaching loop the plate ("DESTROY THE CORES") promises. GY raid cores untouched.
	# NOTE (2026-07-21): the pack-boss redesign removed the Howler's cores — this def is DORMANT
	# (golden-fingerprinted, admin-spawnable) like rally_cone/rival_coach; re-seat it if ever wanted.
	"rival_core": {
		"name": "Rival Power Core", "sport": "", "mob": true, "model": "power_core", "anim": "core", "h": 2.0,
		"lane": 1, "color": "#FF6B4A", "recolor": true, "stationary": true, "isCore": true, "respawnS": 45.0,
		"stats": {"PWR": 1, "PRE": 1, "SPD": 1, "END": 44, "INS": 1, "CLU": 1},
		"abilities": [],
	},
	# Power cores — inert destructible objects (team 1, the boss's side). No abilities, stationary → they just
	# sit; players destroy them to weaken/cancel the boss's Full Camp Reset ult (mult = cores_alive/coreCount).
	# "isCore":true → the server tags them no-loot/no-XP. They respawn like any mob, so the counterplay recurs.
	# --- gameplay-length P3 (roster remix): new leveling-zone minions. Reuse existing GLBs (recolored via the
	# opt-in client tint) + ONLY ability types already proven on mobs (melee/dashAttack/meleeAoe/projectile/
	# zone/selfbuff — no new sim RNG). Seeded into GY3-5 + the Drill pool. Stats/colors are playtest-tunable.
	"spring_cone": {
		"name": "Spring-Loaded Cone", "sport": "", "mob": true, "model": "cone", "anim": "cone", "h": 1.5,
		"lane": 0, "color": "#7CFF4A", "recolor": true,
		"stats": {"PWR": 34, "PRE": 24, "SPD": 78, "END": 24, "INS": 18, "CLU": 16},
		"abilities": [
			{"key": "hopjab", "name": "Hop Jab", "type": "melee", "basic": true, "dmg": 30, "cd": 1.0, "range": 52},
			{"key": "springdash", "name": "Spring Dash", "type": "dashAttack", "dmg": 30, "cd": 4.5, "dist": 165, "slow": {"amt": 0.15, "dur": 0.8}},
		],
	},
	"tire_dummy": {
		"name": "Tractor-Tire Dummy", "sport": "", "mob": true, "rig": true, "model": "foam_dummy",
		"skins": ["foam_dummy", "foam_dummy2"], "h": 3.3,
		"lane": 0, "color": "#8792A6", "recolor": true,
		"stats": {"PWR": 40, "PRE": 26, "SPD": 26, "END": 58, "INS": 20, "CLU": 18},
		"abilities": [
			{"key": "tireroll", "name": "Tire Roll", "type": "melee", "basic": true, "dmg": 38, "cd": 1.4, "range": 60, "cast": 0.3},
			{"key": "brace", "name": "Brace", "type": "selfbuff", "cd": 10.0, "buff": {"dr": 0.30, "dur": 2.2}},
			{"key": "tirebump", "name": "Tire Bump", "type": "melee", "dmg": 28, "cd": 6.5, "range": 62, "cast": 0.3, "knockback": 55},
		],
	},
	"chalk_liner": {
		"name": "Chalk-Line Marker", "sport": "", "mob": true, "model": "shooting_dummy",
		"skins": ["shooting_dummy", "shooting_dummy2"], "anim": "turret", "h": 3.2,
		"lane": 2, "color": "#EDEDED", "recolor": true, "stationary": true,
		"stats": {"PWR": 40, "PRE": 38, "SPD": 8, "END": 34, "INS": 24, "CLU": 18},
		"abilities": [
			{"key": "chalkshot", "name": "Chalk Shot", "type": "projectile", "basic": true, "dmg": 34, "cd": 1.3, "range": 290, "speed": 410},
			{"key": "dustline", "name": "Dust Line", "type": "zone", "cd": 9.0, "dur": 4.0, "radius": 110, "dmg": 6, "slow": {"amt": 0.25, "dur": 0.5}},
		],
	},
	"whistle_cone": {
		"name": "Whistle Cone", "sport": "", "mob": true, "model": "cone", "anim": "cone", "h": 1.5,
		"lane": 0, "color": "#FFE04A", "recolor": true,
		"stats": {"PWR": 38, "PRE": 28, "SPD": 64, "END": 26, "INS": 20, "CLU": 16},
		"abilities": [
			{"key": "conenip", "name": "Cone Nip", "type": "melee", "basic": true, "dmg": 30, "cd": 1.1, "range": 54},
			{"key": "whistle", "name": "Whistle Blast", "type": "melee", "dmg": 18, "cd": 7.0, "range": 60, "stun": 0.9},
		],
	},
	"pop_dummy": {
		"name": "Pop-Up Dummy", "sport": "", "mob": true, "rig": true, "model": "foam_dummy",
		"skins": ["foam_dummy2", "foam_dummy"], "h": 3.3,
		"lane": 0, "color": "#E8564A", "recolor": true,
		"stats": {"PWR": 46, "PRE": 26, "SPD": 30, "END": 40, "INS": 20, "CLU": 18},
		"abilities": [
			{"key": "popswing", "name": "Pop Swing", "type": "melee", "basic": true, "dmg": 38, "cd": 1.35, "range": 60, "cast": 0.35},
			{"key": "popburst", "name": "Pop Burst", "type": "meleeAoe", "dmg": 34, "cd": 7.0, "radius": 90, "cast": 0.4},
		],
	},
	# --- Phase 8 (the Away Circuit, docs/phase8-away-circuit-plan.md): rival-team minions for the 9-16 band.
	# Same P3a recolor grammar (existing GLBs + the dye channel) and only shipped/AI-proven ability types +
	# field shapes (allybuff mirrors field_medic's extrapads; projectile slow rides the generic Sim.gd:180 path).
	# NOTE (W3): rally_cone's last spawn rows were swapped out by the wildlife roster — the def is
	# kept DORMANT (golden-fingerprinted, admin-spawnable; Drill-pool candidate) like rival_coach at W5.
	"rally_cone": {
		"name": "Rally Cone", "sport": "", "mob": true, "model": "cone", "anim": "cone", "h": 1.5,
		"lane": 0, "color": "#E0433D", "recolor": true,
		"stats": {"PWR": 36, "PRE": 26, "SPD": 70, "END": 26, "INS": 22, "CLU": 16},
		"abilities": [
			{"key": "conejab", "name": "Cone Jab", "type": "melee", "basic": true, "dmg": 31, "cd": 1.1, "range": 54},
			{"key": "rallycry", "name": "Rally Cry", "type": "allybuff", "targetType": "ally", "shieldPct": 0.08, "dur": 2.5, "cd": 9.0},   # rival fans shield their squad — focus the cones first
		],
	},
	"away_blocker": {
		"name": "Visiting Blocker", "sport": "", "mob": true, "rig": true, "model": "foam_dummy",
		"skins": ["foam_dummy2", "foam_dummy"], "h": 3.3,
		"lane": 0, "color": "#3D5A99", "recolor": true,
		"stats": {"PWR": 46, "PRE": 28, "SPD": 32, "END": 52, "INS": 22, "CLU": 18},
		"abilities": [
			{"key": "shoulderset", "name": "Shoulder Set", "type": "melee", "basic": true, "dmg": 38, "cd": 1.35, "range": 60, "cast": 0.3},
			{"key": "pancakeblock", "name": "Pancake Block", "type": "dashAttack", "dmg": 34, "cd": 7.0, "dist": 150, "cast": 0.35, "knockback": 55},
		],
	},
	"line_judge": {
		"name": "Line Judge", "sport": "", "mob": true, "model": "shooting_dummy",
		"skins": ["shooting_dummy2", "shooting_dummy"], "anim": "turret", "h": 3.2,
		"lane": 2, "color": "#46557A", "recolor": true, "stationary": true,
		"stats": {"PWR": 42, "PRE": 40, "SPD": 8, "END": 36, "INS": 26, "CLU": 18},
		"abilities": [
			{"key": "penaltyshot", "name": "Penalty Shot", "type": "projectile", "basic": true, "dmg": 35, "cd": 1.3, "range": 290, "speed": 410},
			{"key": "flagthrow", "name": "Flag Throw", "type": "projectile", "dmg": 30, "cd": 6.5, "range": 300, "speed": 380, "slow": {"amt": 0.25, "dur": 1.2}},
		],
	},
	# --- gameplay-length P3b (roster remix, elites): new ELITE mob defs reusing existing GLBs (recolored) + only
	# AI-proven/verified ability types (incl. mob support via AI.support_tick). Seeded into the Camp Circuit + Drill.
	"iron_sled": {
		"name": "Iron Blocking Sled", "sport": "", "mob": true, "model": "sled_juggernaut", "anim": "brute", "h": 2.9,
		"face": 90.0,
		"lane": 0, "color": "#6E7681", "recolor": true, "kbImmune": true, "frontalDR": 0.55,
		"stats": {"PWR": 64, "PRE": 22, "SPD": 16, "END": 96, "INS": 20, "CLU": 20},
		"abilities": [
			{"key": "ironshoulder", "name": "Iron Shoulder", "type": "melee", "basic": true, "dmg": 50, "cd": 1.6, "range": 66},
			{"key": "irondrive", "name": "Iron Drive", "type": "dashAttack", "dmg": 74, "cd": 7.5, "dist": 175, "cast": 0.45, "knockback": 95, "wallStun": 1.5},
			{"key": "ironslam", "name": "Iron Slam", "type": "meleeAoe", "dmg": 58, "cd": 9.0, "radius": 95, "cast": 0.5, "knockback": 50},
			{"key": "ironbrace", "name": "Iron Brace", "type": "selfbuff", "cd": 11.0, "buff": {"dr": 0.30, "dur": 2.4}},
		],
	},
	"gatling_machine": {
		"name": "Gatling Ball Machine", "sport": "", "mob": true, "model": "ball_machine", "anim": "turret", "h": 2.4,
		"face": 90.0,
		"lane": 2, "color": "#C43C2E", "recolor": true, "stationary": true,
		"stats": {"PWR": 54, "PRE": 46, "SPD": 8, "END": 42, "INS": 28, "CLU": 18},
		"abilities": [
			{"key": "rapidfire", "name": "Rapid Fire", "type": "projectile", "basic": true, "dmg": 36, "cd": 1.0, "range": 300, "speed": 450, "wobble": 1},
			{"key": "fanvolley", "name": "Fan Volley", "type": "spread", "dmg": 22, "count": 7, "arc": 0.9, "cd": 6.0, "range": 300, "speed": 430, "wobble": 1},
			{"key": "carom", "name": "Carom Shot", "type": "spread", "dmg": 40, "count": 2, "arc": 0.22, "cd": 9.0, "range": 300, "speed": 430, "bounces": 2},
		],
	},
	"field_medic": {
		"name": "Camp Field Medic", "sport": "", "mob": true, "rig": true, "model": "drill_sergeant", "h": 2.9,
		"lane": 0, "color": "#2FA79A", "recolor": true,
		"stats": {"PWR": 40, "PRE": 40, "SPD": 30, "END": 58, "INS": 34, "CLU": 22},
		"abilities": [
			{"key": "medjab", "name": "Med Jab", "type": "melee", "basic": true, "dmg": 34, "cd": 1.4, "range": 60},
			{"key": "tapeup", "name": "Tape Up", "type": "allyheal", "targetType": "ally", "healPct": 0.09, "cd": 9.0},   # P3b: conservative — % heal scales with Intensity-inflated HP, so keep it under a party's DPS (playtest-tune)
			{"key": "extrapads", "name": "Extra Pads", "type": "allybuff", "targetType": "ally", "shieldPct": 0.13, "dur": 3.0, "cd": 10.0},
		],
	},
	"blitz_captain": {
		"name": "Blitz Captain", "sport": "", "mob": true, "rig": true, "model": "drill_sergeant", "h": 2.9,
		"lane": 0, "color": "#E08A2E", "recolor": true, "kbImmune": true,
		"stats": {"PWR": 50, "PRE": 32, "SPD": 30, "END": 66, "INS": 30, "CLU": 22},
		"abilities": [
			{"key": "captainbark", "name": "Captain's Bark", "type": "melee", "basic": true, "dmg": 42, "cd": 1.4, "range": 62},
			{"key": "reinforce", "name": "Reinforce", "type": "summon", "mobType": "spring_cone", "count": 3, "cd": 16.0},
			{"key": "blindsidecharge", "name": "Blindside Charge", "type": "dashAttack", "dmg": 60, "cd": 8.0, "dist": 175, "cast": 0.4, "knockback": 70},
		],
	},
	"tackle_captain": {
		"name": "Tackle Captain", "sport": "", "mob": true, "model": "tackle_brute", "anim": "brute", "h": 3.5,
		"lane": 0, "color": "#D9A21A", "recolor": true,
		"stats": {"PWR": 60, "PRE": 26, "SPD": 26, "END": 78, "INS": 24, "CLU": 22},
		"abilities": [
			{"key": "captainbash", "name": "Captain's Bash", "type": "melee", "basic": true, "dmg": 48, "cd": 1.5, "range": 64},
			{"key": "blindside", "name": "Blindside", "type": "dashAttack", "dmg": 66, "cd": 7.5, "dist": 180, "cast": 0.45, "knockback": 80},
			{"key": "flatten", "name": "Flatten", "type": "meleeAoe", "dmg": 44, "cd": 8.0, "radius": 95, "cast": 0.5, "knockback": 45},
			{"key": "churn", "name": "Churn", "type": "zone", "cd": 11.0, "radius": 115, "dur": 4.5, "dmg": 8.0, "slow": {"amt": 0.30, "dur": 0.5}},
		],
	},
	"power_core": {
		"name": "Power Core", "sport": "", "mob": true, "model": "power_core", "anim": "core", "h": 2.0,
		"lane": 1, "color": "#33CCFF", "stationary": true, "isCore": true,
		"stats": {"PWR": 1, "PRE": 1, "SPD": 1, "END": 44, "INS": 1, "CLU": 1},
		"abilities": [],
	},
	# ── Wildlife Expanse mobs (Zone-2 re-roster, docs/wildlife-expanse-zone2-plan.md) — the owner's
	# rigged quadruped GLBs staged in W1 (models/meshy/mobs/rigged/ + clips/). Kits reuse ONLY ability
	# types already proven on mobs (no new sim rng). W2 ships DARK: no World.MOBS rows until W3, so
	# nothing spawns for players — the F1 admin "Spawn Skink" button is the sole way in.
	"netvine_skink": {
		"name": "Netvine Skink", "sport": "", "mob": true, "rig": true, "model": "netvine_skink", "h": 1.7,
		"lane": 0, "color": "#7FA65A",
		"stats": {"PWR": 36, "PRE": 34, "SPD": 66, "END": 30, "INS": 22, "CLU": 16},
		"abilities": [
			{"key": "vinelash", "name": "Vine Lash", "type": "melee", "basic": true, "dmg": 30, "cd": 1.2, "range": 56},
			{"key": "netsnare", "name": "Net Snare", "type": "projectile", "dmg": 26, "cd": 7.0, "range": 240, "speed": 380, "slow": {"amt": 0.35, "dur": 1.5}},
		],
	},
	# W3 normals (roster swap, away_1-3 minion rows). Charge mirrors the sled's driveblock (lighter);
	# Scrap Guard mirrors the proven dr/dur selfbuff shape (no aiPressure — mob-freeze rule); Rally
	# Screech is byte-shaped on field_medic's extrapads allybuff (the mob-proven support primitive).
	"tacklehorn_grazer": {
		"name": "Tacklehorn Grazer", "sport": "", "mob": true, "rig": true, "model": "tacklehorn_grazer", "h": 2.6,
		"lane": 0, "color": "#C9A15A",
		"stats": {"PWR": 52, "PRE": 26, "SPD": 40, "END": 60, "INS": 20, "CLU": 16},
		"abilities": [
			{"key": "hornjab", "name": "Horn Jab", "type": "melee", "basic": true, "dmg": 36, "cd": 1.4, "range": 62},
			{"key": "tacklecharge", "name": "Tacklehorn Charge", "type": "dashAttack", "dmg": 52, "cd": 7.5, "dist": 175, "cast": 0.45, "knockback": 70, "wallStun": 1.2},
		],
	},
	"scrapmask_forager": {
		"name": "Scrapmask Forager", "sport": "", "mob": true, "rig": true, "model": "scrapmask_forager", "h": 1.9,
		"lane": 0, "color": "#8B7A5E",
		"stats": {"PWR": 42, "PRE": 32, "SPD": 52, "END": 44, "INS": 24, "CLU": 20},
		"abilities": [
			{"key": "clawrake", "name": "Claw Rake", "type": "melee", "basic": true, "dmg": 32, "cd": 1.25, "range": 56},
			{"key": "scrapguard", "name": "Scrap Guard", "type": "selfbuff", "cd": 11.0, "buff": {"dr": 0.30, "dur": 2.5}},
		],
	},
	"rallywing_magpie": {
		"name": "Rallywing Magpie", "sport": "", "mob": true, "rig": true, "model": "rallywing_magpie", "h": 2.1,
		"lane": 0, "color": "#4FC3E8",
		"stats": {"PWR": 34, "PRE": 42, "SPD": 62, "END": 36, "INS": 32, "CLU": 22},
		"abilities": [
			{"key": "beakpeck", "name": "Beak Peck", "type": "melee", "basic": true, "dmg": 28, "cd": 1.2, "range": 54},
			{"key": "rallyscreech", "name": "Rally Screech", "type": "allybuff", "targetType": "ally", "shieldPct": 0.12, "dur": 3.0, "cd": 9.0},
		],
	},
	# W4 elite: replaces the away_2 sled anchor (the medic stays — the healer-camp lesson is the
	# medic's, not the anchor's). Ground Slam mirrors pancakeslam/shockwave; Croak Wave mirrors
	# ladderlock's pure-slow zone (no dmg — the controller identity). kbImmune like the old anchor.
	# THE PACK BOSS (owner redesign 2026-07-21): the Howler's fight is DELIBERATELY unlike the Head
	# Coach's — NO cores, NO core-shield (those are Boss1's signature). The mechanic is THE PACK:
	# phase waves + the Signature Howl call skinks, and from P2 the Pack Call summons a rallywing
	# magpie whose Rally Screech SHIELDS the alpha and pack — the zone's kill-the-support-first
	# lesson at boss stakes (SUMMON_CAP 3 bounds the whole pack; adds are isAdd = no loot). Blood
	# Frenzy (P2 ms-surge selfbuff, the stolenbase shape) makes Frenzy a kiting phase. hpMult
	# 0.6→0.7 compensates the lost 40% shield window (~40k flat vs the rival's 34k-behind-cores,
	# within the re-pinned ≤1.25× Head Coach pool bound; no ult keeps it the easier boss; tunable). Still no campreset ult + 30-min cadence. All shapes mob-proven; no new rng.
	"arrowbound_howler": {
		"name": "The Arrowbound Howler", "sport": "", "mob": true, "rig": true, "model": "arrowbound_howler", "h": 3.4,
		"lane": 0, "color": "#7A4FC9", "phased": true, "kbImmune": true,
		"hpMult": 0.7, "dmgScale": 0.6,
		"plate": "ARROWBOUND HOWLER", "phases": ["PROWL", "HUNT", "FRENZY", "LAST STAND"],
		"threshSummon": {"mobType": "netvine_skink", "count": 2},   # each phase entry: the wilds answer
		"stats": {"PWR": 54, "PRE": 32, "SPD": 26, "END": 82, "INS": 28, "CLU": 24},
		"abilities": [
			# the pack call — listed first so the shield-bird takes summon priority once P2 unlocks
			{"key": "packcall", "name": "Pack Call", "type": "summon", "mobType": "rallywing_magpie", "count": 1, "cd": 24.0, "phase": 2},
			{"key": "sighowl", "name": "Signature Howl", "type": "summon", "mobType": "netvine_skink", "count": 2, "cd": 18.0, "phase": 1},
			# P0 Prowl
			{"key": "bite", "name": "Arrowbound Bite", "type": "melee", "basic": true, "dmg": 40, "cd": 1.4, "range": 70, "phase": 0},
			{"key": "ripclaw", "name": "Rip Claw", "type": "meleeAoe", "dmg": 42, "cd": 6.0, "radius": 95, "cast": 0.5, "phase": 0},
			# P1 Hunt — the hazard lesson stays
			{"key": "huntground", "name": "Hunting Ground", "type": "zone", "cd": 12.0, "radius": 120, "dur": 5.0, "dmg": 8.0, "slow": {"amt": 0.35, "dur": 0.6}, "phase": 1},
			{"key": "pounce", "name": "Pounce", "type": "dashAttack", "dmg": 74, "cd": 8.0, "dist": 200, "cast": 0.5, "knockback": 90, "wallStun": 1.2, "phase": 1},
			# P2 Frenzy — the alpha speeds up; kite it
			{"key": "bloodfrenzy", "name": "Blood Frenzy", "type": "selfbuff", "cd": 14.0, "buff": {"ms": 1.30, "dur": 4.0}, "phase": 2},
			{"key": "frenzysweep", "name": "Frenzy Sweep", "type": "meleeAoe", "dmg": 54, "cd": 10.0, "radius": 150, "cast": 0.7, "knockback": 55, "phase": 2},
			# P3 Last Stand
			{"key": "deathhowl", "name": "Death Howl", "type": "meleeAoe", "dmg": 20, "cd": 8.0, "radius": 130, "stun": 0.9, "cast": 0.4, "phase": 3},
			{"key": "finishpounce", "name": "Killing Pounce", "type": "meleeAoe", "dmg": 70, "cd": 9.0, "radius": 110, "cast": 0.55, "knockback": 45, "phase": 3},
		],
	},
	# W4b elite (owner accepted the pass-1 animation set 2026-07-20): replaces away_3's ball_machine
	# slot — the ranged-elite seat. Quill Barrage is the proven spread fan (scatter shape); a mobile
	# bruiser that closes to melee and unloads point-blank fans. Quills are dorsal, so no frontalDR.
	"splinterback_elite": {
		"name": "Splinterback", "sport": "", "mob": true, "rig": true, "model": "splinterback_elite", "h": 2.9,
		"lane": 0, "color": "#B08A4F", "kbImmune": true,
		"stats": {"PWR": 54, "PRE": 34, "SPD": 34, "END": 72, "INS": 22, "CLU": 18},
		"abilities": [
			{"key": "headslam", "name": "Head Slam", "type": "melee", "basic": true, "dmg": 42, "cd": 1.5, "range": 66},
			{"key": "quillbarrage", "name": "Quill Barrage", "type": "spread", "dmg": 30, "count": 5, "arc": 0.85, "cd": 8.0, "range": 300, "speed": 430},
		],
	},
	"emerald_warfrog": {
		"name": "Emerald Warfrog", "sport": "", "mob": true, "rig": true, "model": "emerald_warfrog", "h": 3.0,
		"lane": 0, "color": "#2E9E63", "kbImmune": true,
		"stats": {"PWR": 56, "PRE": 30, "SPD": 30, "END": 86, "INS": 24, "CLU": 18},   # END 86: raw-pool parity with the old sled anchor (its frontalDR is deliberately NOT inherited — controller, not wall)
		"abilities": [
			{"key": "swipe", "name": "Swipe", "type": "melee", "basic": true, "dmg": 40, "cd": 1.4, "range": 64},
			{"key": "groundslam", "name": "Ground Slam", "type": "meleeAoe", "dmg": 58, "cd": 9.0, "radius": 100, "cast": 0.55, "knockback": 60},
			{"key": "croakwave", "name": "Croak Wave", "type": "zone", "cd": 12.0, "radius": 110, "dur": 4.0, "slow": {"amt": 0.30, "dur": 0.6}},
		],
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
	5: {   # the live MMO format (ZONE_TEAM_SIZE). RE-TUNED 2026-07-15 for the 8-skill kits: the expansion moved
	       # the AI-duel spread to 58.6 at the old mods (sett 74 / quar 15 — multi-effect support inflated the
	       # supports, the QB's support-heavy kit collapsed). Re-measured with tools/bal_tune.gd, pulling each
	       # class toward ~50%. Mods apply to players AND mobs alike (mobs have no entry).
		"goalkeeper": {"dmg": 0.58},
		"quarterback": {"dmg": 1.15},
		"batter": {"dmg": 1.17},
		"linebacker": {"dmg": 0.95},
		"pitcher": {"dmg": 0.94},
		"striker": {"dmg": 1.08},
		"spiker": {"dmg": 0.98},
		"setter": {"dmg": 1.18, "hp": 1.10},
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
# --- gameplay-length P4: talent / mastery trees -------------------------------------------------------------
# One talent point per level (L1=0 → literally fixes "build complete at level 1"; L30=29). 3 branches × 3 nodes;
# EVERY node is a bounded delta on one of the 6 stats derive() reads (PWR/PRE/SPD/END/INS/CLU) → NO Sim/Combat/AI
# code is touched. The NUMBERS live once in TALENT_SHAPE (identical for all 8 classes → symmetry is STRUCTURAL,
# not a convention); classes add only NAMES in TALENT_FLAVOR. Talent deltas fold into the server's gear `bonus`
# funnel as a 3rd above-cap layer (parallel TALENT_STAT_CAP, like set bonuses) — the AI-duel harness must re-run
# to confirm FORMAT_MODS[5] parity holds (a symmetric +power still multiplies the existing class dmg gaps).
const TALENT_POINTS_PER_LEVEL := 1
const TALENT_STAT_CAP := 20               # per-stat talent ceiling (parallel above EQUIP_STAT_CAP, mirrors SET_BONUS_CAP)
const TALENT_RESPEC_CREDITS := 50000      # heavy flat-credits respec sink (tunable) — makes players COMMIT to a build (5x the 10k Locker unlock)
const TALENT_BRANCH_ORDER := ["power", "guard", "tempo"]
# node = {slot, stat, max ranks, per-rank delta, req = cumulative RANKS in this branch to unlock the node}.
# req is 0 on EVERY node → the whole tree is ungated: any node can be raised at any time (only bounded by the node's
# max ranks + your total points). This is deliberate build-diversity — no forced a→b→c spend order, so players mix
# branches/nodes into concept builds instead of one streamlined path. (Raise a req to re-introduce a spend order.)
const TALENT_SHAPE := {
	"power": {"nodes": [
		{"slot": "a", "stat": "PWR", "max": 5, "per": 2, "req": 0},
		{"slot": "b", "stat": "PRE", "max": 5, "per": 2, "req": 0},
		{"slot": "c", "stat": "PWR", "max": 3, "per": 2, "req": 0, "capstone": true}]},
	"guard": {"nodes": [
		{"slot": "a", "stat": "END", "max": 5, "per": 2, "req": 0},
		{"slot": "b", "stat": "CLU", "max": 5, "per": 2, "req": 0},
		{"slot": "c", "stat": "END", "max": 3, "per": 2, "req": 0, "capstone": true}]},
	"tempo": {"nodes": [
		{"slot": "a", "stat": "SPD", "max": 5, "per": 2, "req": 0},
		{"slot": "b", "stat": "INS", "max": 5, "per": 2, "req": 0},
		{"slot": "c", "stat": "SPD", "max": 3, "per": 2, "req": 0, "capstone": true}]},
}
# names only — node_id = "<cls>_<branch>_<slot>"; mechanics are identical across all 8 classes
const TALENT_FLAVOR := {
	"pitcher":     {"tree": "Ace Command",  "power": {"name": "Velocity",   "a": "Heat",          "b": "Command",       "c": "Filthy Stuff"},   "guard": {"name": "Bullpen",    "a": "Conditioning",  "b": "Ice in the Veins", "c": "Complete Game"},  "tempo": {"name": "Tempo",      "a": "Quick Pitch",   "b": "Pitch IQ",     "c": "No-Windup"}},
	"batter":      {"tree": "Slugger",      "power": {"name": "Power",      "a": "Bat Speed",     "b": "Contact",       "c": "Walk-Off"},        "guard": {"name": "Durability", "a": "Iron Grip",     "b": "Clutch Gene",      "c": "Extra Innings"},  "tempo": {"name": "Baserunning","a": "Jump",          "b": "Read",         "c": "Steal"}},
	"quarterback": {"tree": "Field General","power": {"name": "Arm",        "a": "Cannon",        "b": "Accuracy",      "c": "Deep Bomb"},       "guard": {"name": "Pocket",     "a": "Presence",      "b": "Poise",            "c": "Fourth Down"},    "tempo": {"name": "Audible",    "a": "Snap Count",    "b": "Field Vision", "c": "No Huddle"}},
	"linebacker":  {"tree": "Enforcer",     "power": {"name": "Impact",     "a": "Big Hit",       "b": "Read",          "c": "Blindside"},       "guard": {"name": "Toughness",  "a": "Brick Wall",    "b": "Grit",             "c": "Goal Line"},      "tempo": {"name": "Pursuit",    "a": "Closing Speed", "b": "Instinct",     "c": "Motor"}},
	"setter":      {"tree": "Playmaker",    "power": {"name": "Setting",    "a": "Quick Set",     "b": "Precision",     "c": "Perfect Set"},     "guard": {"name": "Anchor",     "a": "Dig Deep",      "b": "Composure",        "c": "Fifth Set"},      "tempo": {"name": "Rotation",   "a": "Tempo",         "b": "Court Vision", "c": "Fast Break"}},
	"spiker":      {"tree": "Attacker",     "power": {"name": "Spike",      "a": "Power Hit",     "b": "Placement",     "c": "Kill Shot"},       "guard": {"name": "Endurance",  "a": "Block Party",   "b": "Resolve",          "c": "Match Point"},    "tempo": {"name": "Approach",   "a": "Footwork",      "b": "Read",         "c": "Slide"}},
	"striker":     {"tree": "Golden Boot",  "power": {"name": "Finishing",  "a": "Killer Instinct","b": "Placement",    "c": "Clinical Edge"},   "guard": {"name": "Stamina",    "a": "Second Wind",   "b": "Comeback",         "c": "Ninety Minutes"}, "tempo": {"name": "Footwork",   "a": "Pace",          "b": "Vision",       "c": "Nutmeg"}},
	"goalkeeper":  {"tree": "Last Line",    "power": {"name": "Reflex",     "a": "Shot Stop",     "b": "Reads",         "c": "Point Blank"},     "guard": {"name": "Wall",       "a": "Iron Gloves",   "b": "Nerve",            "c": "Clean Sheet"},    "tempo": {"name": "Distribution","a": "Quick Release","b": "Vision",       "c": "Sweeper"}},
}

# The stat deltas from a talent allocation for a class — UNCAPPED sum (the server applies TALENT_STAT_CAP).
# Reads only KNOWN node ids from TALENT_SHAPE, so a stored alloc with orphaned/renamed keys is ignored safely.
static func talent_stat_deltas(talents: Dictionary, cls: String) -> Dictionary:
	var out := {}
	for br in TALENT_BRANCH_ORDER:
		for n in TALENT_SHAPE[br]["nodes"]:
			var r := mini(int(talents.get("%s_%s_%s" % [cls, br, n["slot"]], 0)), int(n["max"]))
			if r > 0:
				out[str(n["stat"])] = int(out.get(str(n["stat"]), 0)) + r * int(n["per"])
	return out

static func talent_points_available(level: int, talent_spent: int) -> int:
	return maxi(0, (level - 1) * TALENT_POINTS_PER_LEVEL - talent_spent)

# a node's def by node_id ("cls_branch_slot"), or {} if not a valid node for this class
static func talent_node_def(cls: String, node_id: String) -> Dictionary:
	for br in TALENT_BRANCH_ORDER:
		for n in TALENT_SHAPE[br]["nodes"]:
			if "%s_%s_%s" % [cls, br, n["slot"]] == node_id:
				return {"branch": br, "stat": str(n["stat"]), "max": int(n["max"]), "per": int(n["per"]), "req": int(n["req"])}
	return {}

# ranks already spent in a branch (for the in-branch prerequisite gate)
static func talent_branch_ranks(talents: Dictionary, cls: String, branch: String) -> int:
	var tot := 0
	for n in TALENT_SHAPE[branch]["nodes"]:
		tot += int(talents.get("%s_%s_%s" % [cls, branch, n["slot"]], 0))
	return tot

# gameplay-length P5: PARAGON ("Overtime") — post-cap INFINITE progression. DATA lives here (shared client+server) so
# the client can render the board + compute levels identically; the SERVER owns the reward-chokepoint logic. Paragon is
# QoL-ONLY: every perk is a multiplier/chance on a SERVER reward path (loot/credits/pages/tokens/salvage), NEVER a combat
# stat and NEVER the deterministic sim → create_fighter/derive/FORMAT_MODS + the AI-duel harness are byte-identical.
# Level is derived closed-form (overtime_xp / OT_PER_LEVEL) → no stored level to desync or dupe.
const PARAGON_OT_PER_LEVEL := 8250        # post-cap XP per paragon level (~1 full L30 bar; tunable)
const PARAGON_MILESTONE_EVERY := 5        # every Nth paragon level grants a gear-bag milestone
const PARAGON_BAG_PER_MILESTONE := 2      # +gear-inventory slots per milestone
const PARAGON_BAG_MAX := 20               # cap the gear-bag bonus (max gear cap = base 50 + 20 = 70)
const PARAGON_BRANCH_ORDER := ["scout", "payroll", "recruiter"]
const PARAGON_BRANCH_NAMES := {"scout": "Scout", "payroll": "Payroll", "recruiter": "Recruiter"}
# each perk = {branch, cap ranks, per-rank step, name, desc}. 6 perks x 5 ranks = 30 points fills the board (paragon 30).
const PARAGON_CATALOG := {
	"scout_drop":     {"branch": "scout",     "cap": 5, "step": 0.04, "name": "Sharp Eyes",    "desc": "+4% loot drop rate / rank"},
	"scout_clear":    {"branch": "scout",     "cap": 5, "step": 0.08, "name": "Bird Dog",      "desc": "+8% chance of an extra Camp-clear drop / rank"},
	"payroll_credit": {"branch": "payroll",   "cap": 5, "step": 0.05, "name": "Signing Bonus", "desc": "+5% credits from kills / rank"},
	"payroll_scrap":  {"branch": "payroll",   "cap": 5, "step": 0.06, "name": "Scrapper",      "desc": "+6% salvage yield / rank"},
	"recruit_pages":  {"branch": "recruiter", "cap": 5, "step": 0.05, "name": "Playbook Study","desc": "+5% Playbook Pages earned / rank"},
	"recruit_tokens": {"branch": "recruiter", "cap": 5, "step": 0.08, "name": "Talent Scout",  "desc": "+8% Practice Tokens found / rank"},
}
# AUDIBLES — the repeatable Pages sink: per-run consumables re-bought forever (spends via progression_add_pages(-cost)).
# NOTE: only SIDEGRADE affixes are buyable — "recruiting" (+50% Pages) is intentionally EXCLUDED so an Audible can never
# out-earn its own Pages cost (that would flip the sink into a faucet, and one buyer would fund the whole party's +Pages).
# The recruiting affix still occurs for free as the natural weekly rotation. hardened/frenzy give only +15% Pages but are
# net-negative after the 40-Page cost at typical clear payouts, so they're paid convenience, not farming.
const AUDIBLE_CATALOG := {
	"affix_standard": {"cost": 40, "type": "affix", "affix": "standard", "name": "Call: Standard Practice", "desc": "Next Camp run: baseline (no affix)."},
	"affix_hardened": {"cost": 40, "type": "affix", "affix": "hardened", "name": "Call: Hardened Pads",     "desc": "Next Camp run: tankier mobs (a steadier clear)."},
	"affix_frenzy":   {"cost": 40, "type": "affix", "affix": "frenzy",   "name": "Call: Two-Minute Frenzy", "desc": "Next Camp run: mobs hit harder (a faster, riskier clear)."},
	"bonus_drop":     {"cost": 30, "type": "bonus",                      "name": "Call: Extra Scouting",    "desc": "Next Camp clear: +1 guaranteed bonus drop."},
}
static func paragon_level(otx: int) -> int:
	return int(otx) / PARAGON_OT_PER_LEVEL
static func paragon_prog(otx: int) -> int:                # XP into the current paragon level (for the bar)
	return int(otx) % PARAGON_OT_PER_LEVEL
static func paragon_available(otx: int, spent: int) -> int:
	return maxi(0, paragon_level(otx) - spent)
static func paragon_gear_bonus(level: int) -> int:        # +gear slots from milestones, capped
	return mini((level / PARAGON_MILESTONE_EVERY) * PARAGON_BAG_PER_MILESTONE, PARAGON_BAG_MAX)

const SET_DEFS := {
	"baseball":   {"name": "Slugger",   "stat": "PWR", "th": {"2": 8, "4": 15}},
	"football":   {"name": "Gridiron",  "stat": "END", "th": {"2": 8, "4": 15}},
	"volleyball": {"name": "Spiker",    "stat": "PRE", "th": {"2": 8, "4": 15}},
	"soccer":     {"name": "Striker",   "stat": "SPD", "th": {"2": 8, "4": 15}},
	# Reward-loop chase set (Glitchyard) — vendor-only (NOT in SET_IDS, so random loot can't roll it), bought
	# with Practice Tokens. A survivability theme + a stronger bonus than the sport sets to reward the grind.
	"rookie_camp": {"name": "Rookie Camp", "stat": "END", "th": {"2": 12, "4": 20}},
}
const SET_IDS := ["baseball", "football", "volleyball", "soccer"]

# --- Crafting (P5): static recipes (no recipes table). Spend scrap → a random item of the given rarity.
# A scrap sink + a way to target gear; the server rolls the item via _make_item and validates the cost.
const RECIPES := [
	{"id": "forge_unc",    "name": "Forge Uncommon Gear", "scrap": 12,  "rarity": "uncommon", "ilvl": 12},
	{"id": "forge_rare",   "name": "Forge Rare Gear",     "scrap": 40,  "rarity": "rare",     "ilvl": 18},
	{"id": "forge_epic",   "name": "Forge Epic Gear",     "scrap": 120, "rarity": "epic",     "ilvl": 26},
	{"id": "forge_unique", "name": "Forge a Unique",      "scrap": 400, "rarity": "epic",     "ilvl": 30, "unique": true},
	# W7: the Base Camp's forge-tier rungs — recipes are knowledge (usable at any forge); the higher
	# scrap costs meter them. ilvl 30 epic lands ~IP 200 — under the finals drop ceiling (ilvl ≤37).
	{"id": "forge_rare2",  "name": "Wildforge Rare Gear", "scrap": 60,  "rarity": "rare",     "ilvl": 24},
	{"id": "forge_epic2",  "name": "Wildforge Epic Gear", "scrap": 200, "rarity": "epic",     "ilvl": 30},
]

# --- Uniques & procs (P6). A proc is PURE DATA (a fixed effect enum), never a script — so the sim stays
# deterministic. Procs draw NO rng; proc/DOT damage routes through Combat.deal_damage with opts.proc=true
# (which skips the crit rng draw + re-proccing), so a fighter WITH procs draws the same rng as one without.
#   effect (target):  "DOT" (dmg/s for dur) · "FLAT" (one burst) · "LIFESTEAL" (heal owner for amt × hit dmg)
#   effect (SELF, P7b, no rng/supportBoost — a class-neutral flavor edge): "SHIELD" (gain amt shield for dur) ·
#            "HEAL" (heal amt HP) · "HASTE" (+amt move-speed fraction for dur) · "GUARD" (amt damage-reduction for dur)
#   trigger: "on_hit" · "on_crit" · "on_kill" (fires on a killing blow) · "on_lowhp" (owner below 35% HP) [P7b]
#   icd:     internal cooldown (s) so a proc can't fire every hit. amt scales with proc_tier (×1 .. ×2).
#   chance:  probability the trigger actually fires (default 1.0). Rolled with Combat._proc_roll — a
#            deterministic hash, NOT a state.rng draw, so the main stream stays byte-identical.
const PROC_CATALOG := {
	"searing":  {"name": "Searing",  "effect": "DOT",       "trigger": "on_hit",  "amt": 5.0,  "dur": 3.0, "icd": 4.0, "chance": 0.4},
	"crushing": {"name": "Crushing", "effect": "FLAT",      "trigger": "on_crit", "amt": 4.0,  "icd": 1.5},
	"vampiric": {"name": "Vampiric", "effect": "LIFESTEAL", "trigger": "on_hit",  "amt": 0.04, "icd": 1.0},
	# P7b — self-benefit procs on the reserved triggers (effects, not stats): a defensive/sustain/tempo axis
	"bulwark":   {"name": "Bulwark",   "effect": "SHIELD", "trigger": "on_lowhp", "amt": 70.0, "dur": 4.0, "icd": 12.0},
	"vigor":     {"name": "Vigor",     "effect": "HEAL",   "trigger": "on_kill",  "amt": 55.0, "icd": 2.0},   # icd>0 so one AoE pack-wipe heals ONCE, not per-corpse
	"momentum":  {"name": "Momentum",  "effect": "HASTE",  "trigger": "on_kill",  "amt": 0.22, "dur": 3.0, "icd": 6.0},   # icd bounds uptime (~3s/6s) + one fire per AoE tick
	"stonewall": {"name": "Stonewall", "effect": "GUARD",  "trigger": "on_lowhp", "amt": 0.22, "dur": 3.0, "icd": 10.0},
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
	# P7b — new proc-carriers, spread across slots so they're a paperdoll-wide collection hunt
	"aegis_core":     {"name": "Aegis Core",      "slot": "chest",    "proc_id": "bulwark"},
	"reapers_edge":   {"name": "Reaper's Edge",   "slot": "off_hand", "proc_id": "vigor"},
	"trailblazers":   {"name": "Trailblazers",    "slot": "feet",     "proc_id": "momentum"},
	"ironhide_gorget":{"name": "Ironhide Gorget", "slot": "neck",     "proc_id": "stonewall"},
}
const UNIQUE_IDS := ["embermaw", "skullcleaver", "sanguine_band", "aegis_core", "reapers_edge", "trailblazers", "ironhide_gorget"]

# --- Cosmetic dyes (P4): pure-prestige character tints, bought with credits (a sink). Content only — the sim
# never reads this, so it's determinism-neutral. Client renders the color as a material overlay on the model.
const DYE_CATALOG := {
	"crimson":  {"name": "Crimson Wash",  "price": 1200, "color": "#c0392b"},
	"azure":    {"name": "Azure Wash",    "price": 1200, "color": "#2980d9"},
	"emerald":  {"name": "Emerald Wash",  "price": 1600, "color": "#27ae60"},
	"violet":   {"name": "Violet Wash",   "price": 1600, "color": "#8e44ad"},
	"coral":    {"name": "Coral Wash",    "price": 2200, "color": "#ff6f61"},
	"ivory":    {"name": "Ivory Wash",    "price": 2200, "color": "#e8e2d0"},
	"gold":     {"name": "Gilded",        "price": 3600, "color": "#e2b23a"},
	"obsidian": {"name": "Obsidian",      "price": 3600, "color": "#23262c"},
	# gameplay-length P7d: season-exclusive — granted to the weekly skill-board Champion, NEVER buyable (kept out of DYE_IDS so no shop/wardrobe/vendor lists it for purchase)
	"champion": {"name": "Season Champion", "color": "#f6d365", "buyable": false},
	# Phase 8 S2: quest-exclusive — granted by beating the Rival Coach (rival_down), never buyable (same
	# champion-dye pattern: out of DYE_IDS so no shop/vendor lists it)
	"rival_crimson": {"name": "Rival Crimson", "color": "#c43c2e", "buyable": false},
	# W7: quest-exclusive — granted by the Base Camp chain's capstone (wild5_alpha), never buyable
	"wildveil": {"name": "Wildveil Green", "color": "#3fa66a", "buyable": false},
}
const DYE_IDS := ["crimson", "azure", "emerald", "violet", "coral", "ivory", "gold", "obsidian"]

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
# --- gameplay-length P2: level-gated ability kits ---------------------------------------------------------
# AGGRESSIVE gating (owner-locked): only the basic attack at level 1; the first special at level 2 (barren
# window = a single level); the remaining SIX specials + the ult drip in as you level (8-skill kits: one
# special every ~3 levels, ult at 18). Enforced server-side in the intent layer (Server.submit_ability) and
# mirrored on the client hotbar. The deterministic Sim NEVER sees this gate — create_fighter still builds the
# full kit and the AI-duel balance harness never calls submit_ability. Bands are playtest-tunable.
const ABILITY_SPECIAL_UNLOCK := [2, 5, 8, 11, 14, 16]   # unlock level of the 1st..6th SPECIAL (in kit order)
const ABILITY_ULT_UNLOCK := 18                   # the ultimate unlocks here
# Characters created before this UTC epoch keep their full kit (grandfathered — no live player loses access);
# characters created after it are gated. Lexicographic compare on the ISO created_at works (same fixed format).
const ABILITY_GATE_EPOCH := "2026-07-09T22:45:00"

# The level at which `key` unlocks for `cls` (1 = always available). basic → 1, ult → ABILITY_ULT_UNLOCK, each
# special in kit order → ABILITY_SPECIAL_UNLOCK. Symmetric across classes by construction (preserves balance parity).
static func ability_unlock_level(cls: String, key: String) -> int:
	var c: Dictionary = CLASSES.get(cls, {})
	var special_i := 0
	for a in c.get("abilities", []):
		if str(a.get("key", "")) == key:
			if a.get("basic", false):
				return 1
			if a.get("ult", false):
				return ABILITY_ULT_UNLOCK
			return ABILITY_SPECIAL_UNLOCK[mini(special_i, ABILITY_SPECIAL_UNLOCK.size() - 1)]
		if not a.get("basic", false) and not a.get("ult", false):
			special_i += 1
	return 1                                       # key not found → never gate (fail-open)

# Grandfathered = created before the gating epoch → full kit regardless of level (empty/missing → grandfathered).
static func ability_grandfathered(created_at) -> bool:
	return str(created_at).substr(0, 19) < ABILITY_GATE_EPOCH

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
			"dr": 0.0, "drT": 0.0, "ms": 1.0, "msT": 0.0, "bypass": 0.0, "reflect": 0.0,
			# provenance of the current dr/ms value ("ability" | "proc") — dispel spares item-proc buffs
			"drSrc": "", "msSrc": ""},
		"momentum": 0.0, "momentumT": 0.0, "chaseT": 0.0, "atkCommitT": 0.0,
		# guarded melee knockback (Roof Block): charges armed by a selfbuff's buff.guard, expiring with guardT.
		# Consumed in Combat.deal_damage on an eligible direct melee hit; guardT decays in Sim's timer block.
		"guardCharges": 0, "guardKb": 0.0, "guardT": 0.0,
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
		# sub-frame DOT/hazard tick damage coalesces here (per source id) → one "burn" event/sec, not 30
		"_dotAcc": {}, "_dotEvT": 1.0,
		# boss (Phase 4): HP-gated phase (0 for everyone else — inert) + the per-phase threshold-summon latch.
		# In `fresh` so Server._revive auto-resets them on respawn (a respawned boss re-runs all phases).
		"phase": 0, "_threshSummoned": {},
		# P5 Wobble destabilize stacks (0 = inert; only tagged mob abilities ever raise it).
		"wobble": 0.0, "wobbleT": 0.0,
	}
