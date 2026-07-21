extends RefCounted
## World layout for the shared zone. Each map has a TYPE that drives spawn behaviour:
##   safe   — no mob aggro, strong health regen, fixed login spawn (the home base / future towns).
##   combat — mobs chase, weak out-of-combat regen, bigger arena; you resume where you logged out.
## Worlds are independent sims; portal pads teleport between them. Arena size is per-map (each fighter
## carries its world's bounds), so maps can differ in size. A per-map `pvp` flag (true for the Arena)
## drives open-PvP: Combat.is_hostile/is_ally make all players mutually hostile (free-for-all) there.

const HOME := "home"
# The Glitchyard: five chained training-camp subzones (MapleStory-style zoned maps) with a difficulty
# gradient 1→5. They REPLACE the old combat/frontier/depths zones; home + arena are unchanged. Each is a
# separate sim, linked back↔forward by portal pads. The boss arena (head_coach) hangs off GY5 in Phase 4.
const GY1 := "glitchyard_1"                 # Rookie Intake  — lvl 1-2 minions (cones + foam dummies)
const GY2 := "glitchyard_2"                 # Agility Grid   — lvl 2-3 + the tackle_brute elite
const GY3 := "glitchyard_3"                 # Impact Lanes   — lvl 4-5 + the Sled Juggernaut elite
const GY4 := "glitchyard_4"                 # Target Court   — lvl 5-6 + the Ball Machine turret elite
const GY5 := "glitchyard_5"                 # Command Tower  — lvl 7-8 + the Drill Sergeant summoner elite
const GY_BOSS := "glitchyard_boss"          # the Head Coach arena (Phase 4) — hangs off GY5's reserved east pad
const GY_SECRET := "glitchyard_secret"      # the SECRET boss arena (Head Coach PRIME) — gated portal in GY_BOSS,
                                            # only revealed once you've completed EVERY quest (incl. beating Boss1)
const ARENA := "arena"                     # dedicated open-PvP space (free-for-all: all players fight)
# THE AWAY CIRCUIT (gameplay-length Phase 8, plan: docs/phase8-away-circuit-plan.md) — the second biome:
# the Wildlife Expanse chain for the 9-16 band — entered THROUGH the Glitchyard (GY5 far gate) or the
# HOME shortcut, both behind wild_gate (gy5_command complete; pre-W6 characters grandfathered).
const AWAY1 := "away_1"                     # Overgrown Practice Field — lvl 9-10 wildlife + the tackle_brute elite (W4 swaps elites)
const AWAY2 := "away_2"                     # Overrun Gauntlet    — lvl 12-13 wildlife, healer-camp lesson (field_medic) + the warfrog anchor (W4)
const AWAY3 := "away_3"                     # Reclaimed Stadium   — lvl 15-16 wildlife, the drill_sergeant guards the boss door (S2)
const AWAY_BOSS := "away_boss"                 # Howler's Sideline — THE ARROWBOUND HOWLER (teaching boss: cores, no ult) (W5)
const FINALS1 := "finals_1"                 # Contenders' Quarter — lvl 19-21, behind finals_gate (L17 + IP800) (S3)
const FINALS2 := "finals_2"                 # Champions' Gate     — lvl 23-25 + THE GRAND GALLERY elite-plus (S3)
# INSTANCE TEMPLATES (endgame P0+). Never created as a static shared world — the server spins up a private
# per-party copy on demand (world key "<template>#<owner>"), scales it, and tears it down when empty. The
# template's MAPS/MOBS/PORTALS/OBSTACLES/DECALS entries below are the blueprint each instance is built from.
const CAMP := "camp"                        # the instanced Camp Circuit run (endgame grind + Intensity ladder)
const CAMP_B := "camp_b"                     # Circuit v2 rotating room "The Gauntlet" (turret/cover-heavy)
const CAMP_C := "camp_c"                     # Circuit v2 rotating room "The Scrimmage" (support-comp, focus-fire)
const DRILL := "drill"                      # the instanced Two-Minute Drill (endless wave survival → leaderboard)
const LOCKER := "locker_room"               # Builder Mode: the private per-CHARACTER Locker Room (safe, no combat)
const INSTANCE_MAPS := ["camp", "camp_b", "camp_c", "drill", "locker_room"]    # templates that are instance-only (skipped by static-world boot)

static func is_instance_template(map: String) -> bool:
	return INSTANCE_MAPS.has(map)

# Spawn / arrival points per world (the fixed login spawn for safe maps; the portal drop-point for the rest).
const HOME_SPAWN := Vector2(900, 780)        # players appear / return in the plaza (south of the fountain centerpiece)
const GY1_SPAWN := Vector2(200, 425)         # the Home→Glitchyard portal drops you here (west, clear of camps)
const GY2_SPAWN := Vector2(200, 450)
const GY3_SPAWN := Vector2(220, 490)
const GY4_SPAWN := Vector2(220, 520)
const GY5_SPAWN := Vector2(220, 550)
const GYB_SPAWN := Vector2(140, 410)         # boss arena: arrive far WEST, well clear of the central boss camp
const GYS_SPAWN := Vector2(160, 460)         # secret arena: arrive far WEST of Head Coach PRIME
const ARENA_SPAWN := Vector2(200, 400)       # the Home→Arena portal drops you here
const AWAY1_SPAWN := Vector2(200, 475)       # the Home→Wildlife Expanse portal drops you here (west, clear of camps)
const AWAY2_SPAWN := Vector2(200, 500)
const AWAY3_SPAWN := Vector2(220, 550)
const AWAYB_SPAWN := Vector2(140, 410)       # boss room: arrive far WEST, well clear of the central Rival Coach
const FINALS1_SPAWN := Vector2(200, 520)
const FINALS2_SPAWN := Vector2(200, 550)
const CAMP_SPAWN := Vector2(180, 420)        # Camp Circuit instance: arrive far west, clear of the camp
const CAMP_B_SPAWN := Vector2(180, 440)      # Circuit v2 "The Gauntlet" — arrive far west
const CAMP_C_SPAWN := Vector2(180, 470)      # Circuit v2 "The Scrimmage" — arrive far west
const DRILL_SPAWN := Vector2(600, 400)       # Two-Minute Drill: spawn in the arena center (waves close in)
const LOCKER_SPAWN := Vector2(350, 380)      # Locker Room: arrive lower-center, facing into your room (clear of the west exit pad)

# Per-map config. type drives spawn (safe = fixed spawn, else resume-at-logout); w/h = arena size;
# regen = max-HP fraction healed per second; regen_delay = seconds after a hit before regen resumes
# (0 = always); aggro = whether mobs chase players here; pvp = players are mutually hostile here
# (true for the Arena — free-for-all); spawn = login/arrival point. The Glitchyard zones grow in size
# along the gradient so later zones have more room for their tougher, cover-heavy fights.
const MAPS := {
	HOME:  {"type": "safe",   "w": 1800, "h": 1200, "regen": 0.12,  "regen_delay": 0.0, "aggro": false, "pvp": false, "spawn": HOME_SPAWN},
	GY1:   {"type": "combat", "w": 1500, "h": 850,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY1_SPAWN},
	GY2:   {"type": "combat", "w": 1650, "h": 900,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY2_SPAWN},
	GY3:   {"type": "combat", "w": 1800, "h": 980,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY3_SPAWN},
	GY4:   {"type": "combat", "w": 1900, "h": 1040, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY4_SPAWN},
	GY5:   {"type": "combat", "w": 2000, "h": 1100, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY5_SPAWN},
	GY_BOSS: {"type": "combat", "w": 1240, "h": 820, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": GYB_SPAWN},
	GY_SECRET: {"type": "combat", "w": 1440, "h": 940, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": GYS_SPAWN},
	ARENA: {"type": "combat", "w": 1200, "h": 800,  "regen": 0.012, "regen_delay": 6.0, "aggro": false, "pvp": true,  "spawn": ARENA_SPAWN},
	# Phase 8 — the Away Circuit chain (same combat profile as the Glitchyard zones)
	AWAY1: {"type": "combat", "w": 1700, "h": 950,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": AWAY1_SPAWN},
	AWAY2: {"type": "combat", "w": 1850, "h": 1000, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": AWAY2_SPAWN},
	AWAY3: {"type": "combat", "w": 2000, "h": 1100, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": AWAY3_SPAWN},
	AWAY_BOSS: {"type": "combat", "w": 1240, "h": 820, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": AWAYB_SPAWN},
	# Phase 8 S3 — the Finals district (the 18-25 capstone band)
	FINALS1: {"type": "combat", "w": 1900, "h": 1040, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": FINALS1_SPAWN},
	FINALS2: {"type": "combat", "w": 2000, "h": 1100, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": FINALS2_SPAWN},
	# instance TEMPLATE (P0 = a single proving room; P1 expands it into the condensed multi-room Circuit)
	CAMP:  {"type": "combat", "w": 1500, "h": 850,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": CAMP_SPAWN},
	CAMP_B: {"type": "combat", "w": 1600, "h": 900, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": CAMP_B_SPAWN},
	CAMP_C: {"type": "combat", "w": 1650, "h": 950, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": CAMP_C_SPAWN},
	# Two-Minute Drill arena (P5): no out-of-combat regen (survival), waves spawned by the server
	DRILL: {"type": "combat", "w": 1200, "h": 800,  "regen": 0.0,   "regen_delay": 0.0, "aggro": true,  "pvp": false, "spawn": DRILL_SPAWN},
	# Locker Room (Builder Mode): a small SAFE private room — no mobs, no aggro, strong regen. Decorated by its owner.
	LOCKER: {"type": "safe", "w": 700, "h": 460, "regen": 0.12, "regen_delay": 0.0, "aggro": false, "pvp": false, "spawn": LOCKER_SPAWN},
}

const DUMMY_POS := Vector2(1240, 790)         # the training dummy (home only)
const DUMMY_CLASS := "linebacker"            # a tanky punching bag
const PORTAL_RADIUS := 42.0                  # stepping this close to a pad teleports you
const SHOP_POS := Vector2(1240, 420)          # the shop pad (home base only) — stand near it to open the shop
const SHOP_RADIUS := 80.0
const FORGE_POS := Vector2(560, 600)         # the forge pad (home base only) — upgrade/salvage gear here
const FORGE_RADIUS := 80.0
const QUESTGIVER_POS := Vector2(560, 420)    # the quest giver (home base only) — stand near it to accept/turn in quests
const QUESTGIVER_RADIUS := 80.0
const PRACTICE_POS := Vector2(560, 790)      # the Practice Vendor (home base only) — spend Practice Tokens on the Rookie Camp set
const PRACTICE_RADIUS := 80.0
const BUILD_SHOP_POS := Vector2(1240, 600)    # Builder Mode: the Build Shop pad (home base only) — buy furniture/props (right column, above the Locker portal)
const BUILD_SHOP_RADIUS := 80.0

# Portal pads per world: within PORTAL_RADIUS of {x,y} → teleport to world `to` at (tx,ty).
# Zone graph:  Home ↔ Arena,  Home → Glitchyard 1 ↔ 2 ↔ 3 ↔ 4 ↔ 5  (a linear chain; you arrive west, the
# forward pad sits far east past the camps). Back-portal drop points (tx,ty) land you in the PREVIOUS zone
# clear of its forward pad (> PORTAL_RADIUS) so you don't instantly bounce back.
const PORTALS := {
	HOME: [
		# Founders Commons town hub (1800×1200): a central fountain plaza (spawn), vendors flanking W/E, adventure
		# gates along the NORTH edge, and Arena + Locker Room anchoring the SOUTH. Adventure gates (north):
		{"x": 600.0,  "y": 200.0, "to": GY1,   "tx": 200.0,  "ty": 425.0, "label": "▶ Glitchyard"},
		# INSTANCE entry: no static `to` — the server spins up (or rejoins) the player's private Camp instance.
		{"x": 900.0,  "y": 200.0, "instance": CAMP, "label": "▶ Camp Circuit"},
		# walk-on instance entry (`auto`) → drop straight into a fresh Two-Minute Drill (no tier selection)
		{"x": 1180.0, "y": 200.0, "instance": DRILL, "auto": true, "label": "▶ Two-Minute Drill"},
		# W6: the Wildlife Expanse SHORTCUT — visible-but-locked until gy5_command is done (wild_gate; the server
		# explains the requirement on approach, same UX as boss_ready).
		{"x": 300.0,  "y": 200.0, "to": AWAY1, "tx": 200.0,  "ty": 475.0, "gate": "wild_gate", "label": "▶ Wildlife Expanse"},
		# Phase 8 S3: the Finals — visible-but-locked until L17 + gear 800 (deliberately keyed on level+IP,
		# NOT the Head Coach kill, so a stalled raid never hard-blocks the capstone branch).
		{"x": 1480.0, "y": 200.0, "to": FINALS1, "tx": 200.0, "ty": 520.0, "gate": "finals_gate", "label": "▶ The Finals"},
		# south anchors: the PvP Arena (fronting a stadium) + your private Locker Room (fronting a house).
		{"x": 720.0,  "y": 1040.0, "to": ARENA, "tx": 200.0,  "ty": 400.0, "label": "▶ Arena"},
		# Builder Mode: walk on to enter your PRIVATE Locker Room. Per-CHARACTER instance (keyed by char_id). The
		# server gates entry on locker_unlocked — the pad is inert (and P3 shows "Purchase (10,000)") until you own it.
		{"x": 1080.0, "y": 1040.0, "instance": LOCKER, "auto": true, "label": "▶ Locker Room"},
	],
	GY1: [
		{"x": 120.0,  "y": 425.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "▶ Home Base"},
		{"x": 1420.0, "y": 425.0,  "to": GY2,  "tx": 200.0,  "ty": 450.0, "label": "▶ Agility Grid"},
	],
	GY2: [
		{"x": 120.0,  "y": 450.0,  "to": GY1,  "tx": 1280.0, "ty": 425.0, "label": "◀ Rookie Intake"},
		{"x": 1560.0, "y": 450.0,  "to": GY3,  "tx": 220.0,  "ty": 490.0, "label": "▶ Impact Lanes"},
	],
	GY3: [
		# back-drop sits in GY2's mid lane, WEST of the brute elite (>AGGRO_RANGE 320) so back-tracking
		# doesn't dump you onto a scaled elite (TP grace blocks re-port, not aggro).
		{"x": 120.0,  "y": 490.0,  "to": GY2,  "tx": 900.0,  "ty": 450.0, "label": "◀ Agility Grid"},
		{"x": 1700.0, "y": 490.0,  "to": GY4,  "tx": 220.0,  "ty": 520.0, "label": "▶ Target Court"},
	],
	GY4: [
		{"x": 120.0,  "y": 520.0,  "to": GY3,  "tx": 1080.0, "ty": 490.0, "label": "◀ Impact Lanes"},
		{"x": 1800.0, "y": 520.0,  "to": GY5,  "tx": 220.0,  "ty": 550.0, "label": "▶ Command Tower"},
	],
	GY5: [
		# GY4 has TWO elites (mid sled @980,700 + east ball @1580) — drop WEST of both, in the entry lane.
		{"x": 120.0,  "y": 550.0,  "to": GY4,     "tx": 600.0,  "ty": 520.0, "label": "◀ Target Court"},
		# the reserved east pad → the Head Coach arena (placed clear of the drill camp @1620,550, > AGGRO 320)
		{"x": 1900.0, "y": 350.0,  "to": GY_BOSS, "tx": 140.0,  "ty": 410.0, "gate": "boss_ready", "label": "▶ Head Coach Arena"},
		# W6: the PHYSICAL road into zone 2 — the Wildlife Expanse opens past the Command Tower. Placed
		# in the SE corner: 344 from the drill camp (@1620,550 — > AGGRO 320), mirrored under the boss pad.
		# Arrival (240,860) sits on away_1's empty south edge: 369 from the nearest skink camp, clear of
		# every pad (nearest 120 — the return pad; > PORTAL_RADIUS 42). Carries wild_gate like every pad into the biome (the S1 rule).
		{"x": 1900.0, "y": 750.0,  "to": AWAY1, "tx": 240.0,  "ty": 860.0, "gate": "wild_gate", "label": "▶ Wildlife Expanse"},
	],
	GY_BOSS: [
		# back to GY5, dropping clear of the drill camp (@1620,550, > AGGRO 320). The boss is central, far from
		# this west pad, so an arriving group isn't insta-pulled.
		{"x": 80.0,   "y": 410.0,  "to": GY5,     "tx": 1500.0, "ty": 250.0, "label": "◀ Command Tower"},
		# the SECRET portal (far east, past Boss1) — gated: hidden + inert until EVERY quest is done (incl.
		# beating Boss1). Server hides it from the snapshot + refuses the teleport until _all_quests_done.
		{"x": 1150.0, "y": 410.0,  "to": GY_SECRET, "tx": 160.0, "ty": 460.0, "gate": "secret_key", "label": "▶ ??? — The Final Lesson"},
	],
	GY_SECRET: [
		# drop WEST of the secret pad (@1150,410) so returning doesn't instantly bounce back through it.
		{"x": 80.0,   "y": 460.0,  "to": GY_BOSS, "tx": 980.0, "ty": 410.0, "label": "◀ Head Coach Arena"},
	],
	ARENA: [
		{"x": 110.0,  "y": 400.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "▶ Home Base"},
	],
	# Phase 8 — the Away Circuit. away_2's FORWARD pad (→ away_3) is deliberately withheld until S2 ships the
	# destination (plan §hardening: no dangling pads).
	AWAY1: [
		{"x": 120.0,  "y": 475.0,  "to": HOME,  "tx": 900.0,  "ty": 780.0, "label": "◀ Home Base"},
		# W6: the road back — drops beside GY5's Wildlife pad (191 apart, > PORTAL_RADIUS; 358 from the drill camp)
		{"x": 120.0,  "y": 860.0,  "to": GY5,   "tx": 1760.0, "ty": 880.0, "label": "◀ Command Tower"},
		# the interior pad ALSO carries wild_gate: gate_for_map() derives a zone's login re-validation gate
		# from its inbound pads, so without this a tampered last_map="away_2" restore would skip the level-8
		# check entirely (adversarial-review find). Zero UX cost — anyone standing here already passed it.
		# S2 rule: every deeper away/finals pad carries its chain's gate for the same reason.
		{"x": 1620.0, "y": 475.0,  "to": AWAY2, "tx": 200.0,  "ty": 500.0, "gate": "wild_gate", "label": "▶ Overrun Gauntlet"},
	],
	AWAY2: [
		# back-drop lands mid away_1 (1080,475), WEST of its tackle_brute elite @1500 (> AGGRO_RANGE 320) —
		# same convention as the GY3→GY2 drop (TP grace blocks re-port, not aggro).
		{"x": 120.0,  "y": 500.0,  "to": AWAY1, "tx": 1080.0, "ty": 475.0, "label": "◀ Overgrown Practice Field"},
		# S2: the withheld forward pad ships now that its destination exists (carries the chain gate — S1 rule)
		{"x": 1770.0, "y": 500.0,  "to": AWAY3, "tx": 220.0,  "ty": 550.0, "gate": "wild_gate", "label": "▶ Reclaimed Stadium"},
	],
	AWAY3: [
		# back-drop lands at away_2's spawn corridor (200,560) — the only spot in its denser mid that clears
		# every camp by > AGGRO 320 (the lane pairs sit at y 350/650).
		{"x": 120.0,  "y": 550.0,  "to": AWAY2, "tx": 200.0,  "ty": 560.0, "label": "◀ Overrun Gauntlet"},
		# the boss door — walk-up (difficulty is the gate; wild_gate rides for restore re-validation only)
		{"x": 1920.0, "y": 550.0,  "to": AWAY_BOSS, "tx": 140.0, "ty": 410.0, "gate": "wild_gate", "label": "▶ Howler's Sideline"},
	],
	AWAY_BOSS: [
		# drop back mid away_3, WEST of the drill_sergeant boss-door guard @1700 (> AGGRO 320) and CLEAR of
		# the rack cover panel @1300,550 (the review caught the drop landing inside its collision band)
		{"x": 80.0,   "y": 410.0,  "to": AWAY3, "tx": 1350.0, "ty": 550.0, "label": "◀ Reclaimed Stadium"},
	],
	# Phase 8 S3 — the Finals district. finals_2's FORWARD pad (→ the Commissioner's arena) is withheld
	# until S4 ships the destination (no dangling pads). Deeper pads carry finals_gate (the S1 restore rule).
	FINALS1: [
		{"x": 120.0,  "y": 520.0,  "to": HOME,    "tx": 900.0,  "ty": 780.0, "label": "◀ Home Base"},
		{"x": 1820.0, "y": 530.0,  "to": FINALS2, "tx": 200.0,  "ty": 550.0, "gate": "finals_gate", "label": "▶ Champions' Gate"},
	],
	FINALS2: [
		# back-drop lands at finals_1's spawn corridor — the only mid-band spot clear of both lane pairs
		{"x": 120.0,  "y": 550.0,  "to": FINALS1, "tx": 200.0,  "ty": 530.0, "label": "◀ Contenders' Quarter"},
	],
	# Camp instance exit (resolved by TEMPLATE — every "camp#<owner>" instance shares this exit back to home).
	CAMP: [
		{"x": 120.0,  "y": 420.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "◀ Leave Camp"},
	],
	CAMP_B: [
		{"x": 120.0,  "y": 440.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "◀ Leave Camp"},
	],
	CAMP_C: [
		{"x": 120.0,  "y": 470.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "◀ Leave Camp"},
	],
	# Drill exit (a west-corner bail — walking here ends the run; you also end by dying).
	DRILL: [
		{"x": 90.0,   "y": 400.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "◀ End Drill"},
	],
	# Locker Room exit (resolved by TEMPLATE — every "locker_room#<char>" instance shares this exit back to home).
	LOCKER: [
		{"x": 80.0,   "y": 380.0,  "to": HOME, "tx": 900.0,  "ty": 780.0, "label": "◀ Leave Locker Room"},
	],
}

# Mob camps per combat world, spread so engaging one doesn't pull the next (> AGGRO_RANGE apart, with a
# difficulty gradient from the arrival side). Tougher zones lean on higher `level` + tier (minion/elite/
# boss) — _scale_mob handles the scaling, no new stat blocks. The Arena has none (it is a PvP space).
const MOBS := {
	# The Glitchyard roster (sports-training equipment) spread across the five subzones with a level
	# gradient. Camps are > AGGRO_RANGE apart so engaging one doesn't pull the next, with the elite
	# anchoring each zone's far (east) end by its forward portal. _scale_mob handles per-level/tier scaling
	# — no new stat blocks. (The retired combat/frontier/depths player-class filler mobs are gone.)
	GY1: [  # Rookie Intake — pure minions, the on-ramp
		{"class": "cone_swarmer", "level": 1, "tier": "minion", "x": 500.0,  "y": 280.0},
		{"class": "cone_swarmer", "level": 1, "tier": "minion", "x": 500.0,  "y": 570.0},
		{"class": "foam_dummy",   "level": 2, "tier": "minion", "x": 950.0,  "y": 280.0},
		{"class": "foam_dummy",   "level": 2, "tier": "minion", "x": 950.0,  "y": 570.0},
	],
	GY2: [  # Agility Grid — first elite (the tackle_brute)
		{"class": "cone_swarmer",   "level": 2, "tier": "minion", "x": 520.0,  "y": 300.0},
		{"class": "foam_dummy",     "level": 2, "tier": "minion", "x": 520.0,  "y": 600.0},
		{"class": "shooting_dummy", "level": 3, "tier": "minion", "x": 950.0,  "y": 300.0},
		{"class": "foam_dummy",     "level": 3, "tier": "minion", "x": 950.0,  "y": 600.0},
		{"class": "tackle_brute",   "level": 3, "tier": "elite",  "x": 1340.0, "y": 450.0},
	],
	GY3: [  # Impact Lanes — the Sled Juggernaut (push/slam)
		{"class": "tire_dummy",      "level": 4, "tier": "minion", "x": 520.0,  "y": 320.0},
		{"class": "spring_cone",     "level": 4, "tier": "minion", "x": 520.0,  "y": 660.0},
		{"class": "shooting_dummy",  "level": 5, "tier": "minion", "x": 980.0,  "y": 320.0},
		{"class": "foam_dummy",      "level": 5, "tier": "minion", "x": 980.0,  "y": 660.0},
		{"class": "sled_juggernaut", "level": 5, "tier": "elite",  "x": 1500.0, "y": 490.0},
	],
	GY4: [  # Target Court — the Ball Machine turret (+ a second sled)
		{"class": "chalk_liner",     "level": 5, "tier": "minion", "x": 520.0,  "y": 340.0},
		{"class": "whistle_cone",    "level": 5, "tier": "minion", "x": 520.0,  "y": 700.0},
		{"class": "shooting_dummy",  "level": 6, "tier": "minion", "x": 980.0,  "y": 340.0},
		{"class": "sled_juggernaut", "level": 6, "tier": "elite",  "x": 980.0,  "y": 700.0},
		{"class": "ball_machine",    "level": 6, "tier": "elite",  "x": 1580.0, "y": 520.0},
	],
	GY5: [  # Command Tower — the Drill Sergeant summoner anchors the chain's end (boss = Phase 4)
		{"class": "spring_cone",     "level": 7, "tier": "minion", "x": 500.0,  "y": 360.0},
		{"class": "pop_dummy",       "level": 7, "tier": "minion", "x": 500.0,  "y": 740.0},
		{"class": "shooting_dummy",  "level": 7, "tier": "minion", "x": 1000.0, "y": 360.0},
		{"class": "ball_machine",    "level": 7, "tier": "elite",  "x": 1000.0, "y": 740.0},
		{"class": "drill_sergeant",  "level": 8, "tier": "elite",  "x": 1620.0, "y": 550.0},
	],
	GY_BOSS: [  # the Head Coach Prototype (central boss) + 4 destructible power cores around it gating the ult.
		{"class": "head_coach", "level": 8, "tier": "boss",   "x": 620.0, "y": 410.0},
		{"class": "power_core", "level": 5, "tier": "minion", "x": 450.0, "y": 300.0},
		{"class": "power_core", "level": 5, "tier": "minion", "x": 450.0, "y": 520.0},
		{"class": "power_core", "level": 5, "tier": "minion", "x": 790.0, "y": 300.0},
		{"class": "power_core", "level": 5, "tier": "minion", "x": 790.0, "y": 520.0},
	],
	GY_SECRET: [  # Head Coach PRIME (secret raid boss) + 6 power cores — the cores SHIELD it (55% DR while up),
		# so the raid must keep them down. Their level is higher so they take a moment to clear each cycle.
		{"class": "head_coach_prime", "level": 10, "tier": "boss",   "x": 700.0, "y": 470.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 500.0, "y": 330.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 500.0, "y": 610.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 700.0, "y": 250.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 700.0, "y": 690.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 900.0, "y": 360.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 900.0, "y": 580.0},
	],
	# Phase 8 — the Away Circuit camps (docs/phase8-away-circuit-plan.md). Same grammar as the GY chain:
	# lane-pair camps west→east with a level gradient, elites anchoring the east by the forward pad.
	AWAY1: [  # Overgrown Practice Field — the 9-10 on-ramp; W3 wildlife roster (same camps/levels/tiers,
		# classes swapped — the quest matchers are map/tier-keyed so progress carries seamlessly)
		{"class": "netvine_skink",     "level": 9,  "tier": "minion", "x": 520.0,  "y": 330.0},
		{"class": "netvine_skink",     "level": 9,  "tier": "minion", "x": 520.0,  "y": 620.0},
		{"class": "tacklehorn_grazer", "level": 9,  "tier": "minion", "x": 960.0,  "y": 330.0},
		{"class": "tacklehorn_grazer", "level": 10, "tier": "minion", "x": 960.0,  "y": 620.0},
		# the elite guard sits 200 from the forward pad (the shipped-grammar minimum — jukeable, not a
		# mandatory hit) and 340 from away_2's back-drop @1080 (> AGGRO 320).
		{"class": "tackle_brute", "level": 10, "tier": "elite",  "x": 1420.0, "y": 475.0},   # the "Lot Marshal" (nameplate: Tackle Bag Brute)
	],
	AWAY2: [  # Overrun Gauntlet — first healer-camp lesson: the medic sits IN its lane camp's pull
		# (260 from the blocker < AGGRO 320, the CAMP-instance joint-pull convention) so the lesson always
		# fires — engage the lane and the medic wakes with it; focus the healer or the fight drags.
		{"class": "scrapmask_forager", "level": 12, "tier": "minion", "x": 520.0,  "y": 350.0},
		{"class": "tacklehorn_grazer", "level": 12, "tier": "minion", "x": 520.0,  "y": 650.0},
		{"class": "rallywing_magpie",  "level": 13, "tier": "minion", "x": 980.0,  "y": 350.0},
		{"class": "scrapmask_forager", "level": 12, "tier": "minion", "x": 980.0,  "y": 650.0},
		{"class": "field_medic",     "level": 12, "tier": "elite",  "x": 1240.0, "y": 650.0},
		{"class": "emerald_warfrog", "level": 13, "tier": "elite",  "x": 1580.0, "y": 420.0},   # W4: the warfrog takes the east-anchor slot (≥200 from the fwd pad — jukeable, the shipped grammar)
	],
	AWAY3: [  # Reclaimed Stadium — the chain's last field zone; the drill_sergeant guards the boss door
		{"class": "rallywing_magpie",  "level": 15, "tier": "minion", "x": 520.0,  "y": 380.0},
		{"class": "netvine_skink",     "level": 15, "tier": "minion", "x": 520.0,  "y": 720.0},
		{"class": "scrapmask_forager", "level": 15, "tier": "minion", "x": 1000.0, "y": 380.0},
		{"class": "splinterback_elite", "level": 15, "tier": "elite", "x": 1000.0, "y": 720.0},   # W4b: the quill-back takes the ranged-elite seat
		{"class": "drill_sergeant", "level": 16, "tier": "elite",  "x": 1700.0, "y": 550.0},   # the boss-door guard (220 from the pad — jukeable)
	],
	AWAY_BOSS: [  # Rival Sideline — the teaching boss: 3 SLOW-respawn cores shield it (0.40 DR), NO ult.
		# rival_core (respawnS 45, lvl 10) — a solo rotation can genuinely earn the shield-down window;
		# the GY raid's 6-s power_core cadence would keep the boolean shield permanently up on a soloist.
		{"class": "arrowbound_howler", "level": 16, "tier": "boss", "x": 620.0, "y": 410.0},   # W5: the Howler took the sideline (numeric parity with the rival)
		{"class": "rival_core",  "level": 10, "tier": "minion", "x": 450.0, "y": 300.0},
		{"class": "rival_core",  "level": 10, "tier": "minion", "x": 790.0, "y": 300.0},
		{"class": "rival_core",  "level": 10, "tier": "minion", "x": 620.0, "y": 560.0},
	],
	FINALS1: [  # Contenders' Quarter — the capstone band's on-ramp; the instance elites make their open-world debut
		{"class": "pop_dummy",       "level": 19, "tier": "minion", "x": 520.0,  "y": 360.0},
		{"class": "whistle_cone",    "level": 20, "tier": "minion", "x": 520.0,  "y": 700.0},
		{"class": "pop_dummy",       "level": 19, "tier": "minion", "x": 980.0,  "y": 360.0},
		{"class": "chalk_liner",     "level": 20, "tier": "minion", "x": 980.0,  "y": 700.0},
		{"class": "iron_sled",       "level": 20, "tier": "elite",  "x": 1340.0, "y": 360.0},
		{"class": "gatling_machine", "level": 21, "tier": "elite",  "x": 1620.0, "y": 530.0},   # east guard (200 from the fwd pad)
	],
	FINALS2: [  # Champions' Gate — THE GRAND GALLERY (elite-plus, respawnS 120) guards the east behind its
		# 2 slow cores (the S2 window lesson at endgame pace); the medic is a self-healing solo skill-check.
		{"class": "away_blocker",   "level": 23, "tier": "minion", "x": 520.0,  "y": 380.0},
		{"class": "spring_cone",    "level": 23, "tier": "minion", "x": 520.0,  "y": 720.0},
		{"class": "line_judge",     "level": 24, "tier": "minion", "x": 1000.0, "y": 380.0},
		{"class": "field_medic",    "level": 23, "tier": "elite",  "x": 1000.0, "y": 720.0},
		{"class": "blitz_captain",  "level": 24, "tier": "elite",  "x": 1400.0, "y": 380.0},
		{"class": "grand_gallery",  "level": 25, "tier": "elite",  "x": 1680.0, "y": 550.0},
		{"class": "rival_core",     "level": 20, "tier": "minion", "x": 1540.0, "y": 440.0},
		{"class": "rival_core",     "level": 20, "tier": "minion", "x": 1540.0, "y": 660.0},
	],
	# Camp Circuit instance TEMPLATE roster (P0 proving room — a spread of minions + one elite gatekeeper by
	# the exit; P1 replaces this with the condensed multi-room circuit + Intensity scaling). mobLevel/tier are
	# the BASE; the server multiplies by the instance's Intensity in _scale_mob (P1).
	CAMP: [
		{"class": "cone_swarmer",   "level": 5, "tier": "minion", "x": 460.0,  "y": 300.0},
		{"class": "cone_swarmer",   "level": 5, "tier": "minion", "x": 460.0,  "y": 560.0},
		{"class": "foam_dummy",     "level": 6, "tier": "minion", "x": 820.0,  "y": 300.0},
		{"class": "field_medic",    "level": 6, "tier": "elite",  "x": 820.0,  "y": 560.0},   # P3b: a healer — focus it or the run drags
		{"class": "iron_sled",      "level": 7, "tier": "elite",  "x": 1080.0, "y": 430.0},   # P3b: tankier sled, flank it
		# the CLEAR objective: killing the gatekeeper completes the run (grants the tier reward + unlocks the
		# next Intensity). Instance mobs don't respawn, so a Circuit is a finite clear.
		{"class": "tackle_captain", "level": 8, "tier": "elite",  "x": 1320.0, "y": 430.0, "objective": true},   # P3b: the clear gatekeeper (well-rounded bruiser)
	],
	CAMP_B: [  # Circuit v2 "The Gauntlet" — turret/cover: chalk hazards + a gatling turret; iron_sled gatekeeper
		{"class": "cone_swarmer",    "level": 5, "tier": "minion", "x": 480.0,  "y": 300.0},
		{"class": "spring_cone",     "level": 5, "tier": "minion", "x": 480.0,  "y": 640.0},
		{"class": "chalk_liner",     "level": 6, "tier": "minion", "x": 900.0,  "y": 300.0},
		{"class": "gatling_machine", "level": 7, "tier": "elite",  "x": 900.0,  "y": 640.0},
		{"class": "iron_sled",       "level": 8, "tier": "elite",  "x": 1320.0, "y": 460.0, "objective": true},
	],
	CAMP_C: [  # Circuit v2 "The Scrimmage" — support-comp: a medic + a summoner-captain; focus the medic or it drags
		{"class": "spring_cone",    "level": 5, "tier": "minion", "x": 480.0,  "y": 320.0},
		{"class": "pop_dummy",      "level": 5, "tier": "minion", "x": 480.0,  "y": 660.0},
		{"class": "field_medic",    "level": 6, "tier": "elite",  "x": 900.0,  "y": 320.0},
		{"class": "blitz_captain",  "level": 7, "tier": "elite",  "x": 900.0,  "y": 660.0},
		{"class": "tackle_captain", "level": 8, "tier": "elite",  "x": 1340.0, "y": 480.0, "objective": true},
	],
}

# Phase 3 — per-zone cover geometry. Each entry is a PROP PANEL: {x,y, prop, len(=long-axis length, sim),
# yaw(=long-axis direction, rad)}. `circles_from` expands a panel into a ROW of collision circles that hug
# its rectangular footprint (so a wide barrier blocks along its whole length with no end-overhang); the
# server feeds those circles to each world's map for collision/LOS/projectile-block. The client renders the
# named GLB prop scaled to `len`, oriented by `yaw`. Coords are in the zone's own space (Combat 1920×1080,
# Frontier 2200×1240); placed as cover in open lanes, clear of camps + portals.
const PROP_DIM := {                                  # native GLB footprint (model units): long axis / depth axis
	"barrier": {"long": 1.91, "depth": 0.69},
	"rack":    {"long": 1.91, "depth": 0.65},
	"bag":     {"long": 1.03, "depth": 1.03},         # square → a single round pillar
	# collision pass-2 review fix: LONG decor models expanded into circle ROWS (a single centered circle
	# left ~70-80% of each rendered wall walk/shoot-through). Aspect measured from the real GLB AABBs.
	"championship_arena_wall": {"long": 1.899, "depth": 0.623},
	"glitchyard_wall":         {"long": 1.898, "depth": 0.523},
	"spectator_safety_rail":   {"long": 1.899, "depth": 0.335},
	"straight_cover_barrier":  {"long": 1.899, "depth": 1.115},
}
# decal models routed through the row expansion; value = the model's native HEIGHT (Y), so a decal's sim
# length = long/height × h × 20 (the client scales props uniformly to h; SCALE 0.05 → ×20 sim per world).
const DECAL_PANELS := {
	"championship_arena_wall": 0.662, "glitchyard_wall": 0.545,
	"spectator_safety_rail": 0.857, "straight_cover_barrier": 0.321,
}
const GATE_LONG_H := 1.32                             # player_tunnel_gate: an ARCH — two solid posts, a
const GATE_POST_R_H := 2.2                            # walkable opening between (native 1.899L/1.439H)
const OBSTACLE_PAD := 14.0                            # AI.separation blocks fighters at circle r + this

# Expand prop panels → collision circles hugging each panel's rectangle. r is set so the block boundary
# (r + OBSTACLE_PAD) sits ~at the panel's thin face; circles are spaced so the row blocks continuously.
static func circles_from(entries: Array) -> Array:
	var out := []
	for e in entries:
		var prop := str(e.get("prop", "barrier"))
		var dim: Dictionary = PROP_DIM.get(prop, PROP_DIM["barrier"])
		var L := float(e.get("len", 80.0))                       # panel length (sim, long axis)
		var wid := L * float(dim["depth"]) / float(dim["long"])  # panel depth (sim)
		var half := wid * 0.5
		var inner := maxf(L - wid, 0.0)                          # span between the two end-circle centers
		var single := inner < 1.0
		# A single-circle pillar (the square bag) sits flush (block = face). A multi-circle WALL pulls its
		# circles in a touch so the row's pinched "waist" between circles still reaches the panel face — i.e.
		# no slip-through notch — at the cost of a tiny (~0.3-world) gap on the face. Block = cr + PAD.
		var cr := maxf(half - (OBSTACLE_PAD if single else 8.0), 5.0)
		var block := cr + OBSTACLE_PAD
		# spacing whose between-circles waist (sqrt(block² − (s/2)²)) still covers the face `half`
		var max_s := 2.0 * sqrt(maxf(block * block - half * half, 1.0))
		var n := maxi(1, int(ceil(inner / maxf(max_s, 1.0))) + 1)
		var yaw := float(e.get("yaw", 0.0))
		var dx := cos(yaw)
		var dy := sin(yaw)
		for i in n:
			var tt: float = (float(i) / float(n - 1) - 0.5) if n > 1 else 0.0
			out.append({"x": float(e["x"]) + dx * tt * inner, "y": float(e["y"]) + dy * tt * inner, "r": cr})
	return out

static func obstacle_circles(map: String) -> Array:
	return circles_from(OBSTACLES.get(map, []))

# ---- collision for DECORATION props (data/decals/<map>.json) — so players + mobs can't walk through the town's
# buildings/trees/fences/etc. Server-side only: each solid prop becomes one collision circle appended to the
# world's obstacle set (the sim's AI.separation blocks fighters at r + 14). It is NOT sent to the client, which
# already renders the props as decals — so no double-render. ----
# Per-model footprint: the block RADIUS (sim units) generated PER unit of placed height  →  r = FOOTPRINT * h.
# So a prop scaled up blocks a proportionally bigger circle. A model NOT listed here gets NO collision (flat décor
# you walk over: grass, flowers, painted rings, cones). TO GIVE A NEW PROP COLLISION: add it here with a factor ≈
# its horizontal footprint relative to its height — wide buildings ~5.5, chunky rocks ~8, thin fences ~9, tree
# TRUNKS ~2 (the canopy is visual). Err on the SMALL side (you can widen later); the sim blocks at r + 14.
const PROP_FOOTPRINT := {
	"building-a": 5.5, "building-c": 5.5, "building-e": 5.5, "building-h": 5.5,
	"building-k": 5.5, "building-n": 5.5, "building-q": 5.5, "building-t": 5.5, "stadium": 4.5,
	"rock_largeA": 8.0, "rock_largeC": 8.0, "rock_largeE": 8.0, "rock_tallC": 5.0, "stone_largeB": 8.0,
	"tree_oak": 2.2, "tree_default": 2.2, "tree_thin": 1.6, "tree_pineRoundC": 2.4, "tree_palmDetailedTall": 1.6,
	"fence_simple": 9.0, "fence_planks": 9.0, "fence_corner": 9.0,
	"plant_bush": 6.0, "plant_bushLarge": 8.0,
	"chimney-small": 3.5, "chimney-medium": 3.5, "chimney-large": 4.0, "detail-tank": 5.0,
	"bag": 9.0, "barrier": 9.0, "rack": 9.0, "log_stack": 7.0,
	# admin-only Meshy landmarks (see client DECO_PROPS). quest_board is a THIN board → footprint sized to its
	# depth (not width) so players can walk up to its face; the others are solid boxy structures.
	"gear_forge": 9.5, "sideline_stand": 8.0, "power_core": 7.5, "quest_board": 2.8,
	# Phase-8 S5 (batch_006/007): SOLID landmarks get collision. Footprints follow the shipped grammar
	# above (boxy ≈ 3.5-9.5); r = footprint × the decal's h, clamped 4..130 (collision_from_decals).
	"championship_fountain": 8.5, "covered_market_stall": 7.0, "vendor_service_kiosk": 5.0,
	"plaza_light_column": 1.6, "season_reward_vault": 5.5, "portal_anchor": 4.0, "open_salvage_hopper": 5.0,
	# COLLISION PASS-2 (owner-requested 2026-07-15): the original decor pass shipped everything footprint-0
	# ("optional Pass-2") and players walked through walls/stands/kiosks. Every PHYSICAL prop now collides;
	# only flat flora (flowers/grass) stays walk-through. These circles join the world obstacle set, so
	# walls/stands also block shots + LOS — real physics, real cover. (Duel-harness venues are separate:
	# FORMAT_MODS untouched; re-proven via bal_identity.)
	# (championship_arena_wall / glitchyard_wall / spectator_safety_rail / straight_cover_barrier ride the
	#  DECAL_PANELS row expansion; player_tunnel_gate is the two-post arch — none use the single circle.)
	"arena_service_door": 3.5, "boundary_pylon": 1.8,
	"bounty_terminal": 2.8, "leaderboard_kiosk": 2.8, "zone_terminal": 2.8,
	"single_locker": 2.4, "equipment_shelf": 2.6, "sports_ball_rack": 2.4, "championship_trophy": 2.5,
	"equipment_transport_crate": 3.5, "player_bench": 2.2, "public_plaza_bench": 2.2,
	"community_team_table": 2.8, "championship_reward_chest": 2.0, "loot_drop_capsule": 2.2,
	"cable_spool_cart": 3.2, "coolant_pump_station": 4.5, "industrial_ventilation_unit": 4.0,
	"maintenance_tool_cart": 3.0, "scrap_sports_equipment_pile": 5.0,
}
const DECAL_COLLIDE_MIN_R := 4.0
const DECAL_COLLIDE_MAX_R := 130.0

# collision circles for a map's decoration props. Reads the authored data/decals/<map>.json (what the client
# draws), else the const DECALS fallback, so collision always matches what's visible.
static func collision_from_decals(map: String) -> Array:
	var out := []
	var panels := []                                     # long models → circle-ROW expansion via circles_from
	for d in _decals_source(map):
		if not (d is Dictionary) or str(d.get("kind", "")) != "prop":
			continue
		var model := str(d.get("model", ""))
		var hv = d.get("h", 1.0)
		var h: float = float(hv) if (hv is float or hv is int) else 1.0
		var yaw := float(d.get("yaw", 0.0))
		if DECAL_PANELS.has(model):                      # walls/rails: a row of circles hugging the real length
			var dimp: Dictionary = PROP_DIM[model]
			panels.append({"x": float(d.get("x", 0.0)), "y": float(d.get("y", 0.0)), "prop": model,
				"len": float(dimp["long"]) / float(DECAL_PANELS[model]) * h * 20.0, "yaw": yaw})
			continue
		if model == "player_tunnel_gate":                # the arch: two solid POSTS, walkable opening between
			var glen := GATE_LONG_H * h * 20.0
			var pr := maxf(GATE_POST_R_H * h, DECAL_COLLIDE_MIN_R)
			for s in [-1.0, 1.0]:
				out.append({"x": float(d.get("x", 0.0)) + cos(yaw) * s * (glen / 2.0 - pr),
					"y": float(d.get("y", 0.0)) + sin(yaw) * s * (glen / 2.0 - pr), "r": pr})
			continue
		if not PROP_FOOTPRINT.has(model):
			continue                                     # flat décor (grass/flowers/…) → no collision
		var r: float = clampf(float(PROP_FOOTPRINT[model]) * h, DECAL_COLLIDE_MIN_R, DECAL_COLLIDE_MAX_R)
		out.append({"x": float(d.get("x", 0.0)), "y": float(d.get("y", 0.0)), "r": r})
	out.append_array(circles_from(panels))
	return out

# the decal list for a map: the authored JSON if present (what players see), else the const DECALS.
static func _decals_source(map: String) -> Array:
	var jpath := "res://data/decals/%s.json" % map
	if FileAccess.file_exists(jpath):
		var f := FileAccess.open(jpath, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Array:
				return parsed
	return DECALS.get(map, [])

const OBSTACLES := {
	# Panels run perpendicular to the player's eastward approach (yaw≈PI/2 = a N–S wall), split into lanes
	# so the camps stay reachable; bags (square pillars, single circle) flank each zone's elite. Cover grows
	# heavier along the gradient. Coords are in each zone's own space (see MAPS w/h).
	GY1: [  # light cover for the on-ramp
		{"x": 730.0,  "y": 280.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708}, {"x": 730.0,  "y": 570.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
		{"x": 1180.0, "y": 425.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
	GY2: [
		{"x": 700.0,  "y": 300.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708}, {"x": 700.0,  "y": 600.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
		{"x": 1130.0, "y": 450.0, "prop": "rack", "len": 120.0, "yaw": 1.5708},
		{"x": 1340.0, "y": 300.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1340.0, "y": 600.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the brute
	],
	GY3: [
		{"x": 720.0,  "y": 320.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 720.0,  "y": 660.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1240.0, "y": 490.0, "prop": "rack", "len": 130.0, "yaw": 1.5708},
		{"x": 1500.0, "y": 330.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1500.0, "y": 650.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the sled
	],
	GY4: [
		{"x": 720.0,  "y": 340.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 720.0,  "y": 700.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1280.0, "y": 520.0, "prop": "rack", "len": 140.0, "yaw": 1.5708},
		{"x": 1580.0, "y": 360.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1580.0, "y": 680.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the ball machine
	],
	GY5: [
		{"x": 760.0,  "y": 360.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 760.0,  "y": 740.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1320.0, "y": 550.0, "prop": "rack", "len": 140.0, "yaw": 1.5708},
		{"x": 1620.0, "y": 380.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1620.0, "y": 720.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the drill (cover vs its hazard + adds)
	],
	GY_BOSS: [  # a RING of cover around the central boss (@620,410): a wall on each side, so from ANY fighting
		# position the Full Camp Reset ult forces a deliberate run to the nearest cover to break LOS — there is
		# no passively-safe spot (hiding the whole fight = you can't damage the boss through the same wall).
		{"x": 330.0, "y": 410.0, "prop": "barrier", "len": 150.0, "yaw": 1.5708},   # W — hide x<330
		{"x": 910.0, "y": 410.0, "prop": "barrier", "len": 150.0, "yaw": 1.5708},   # E — hide x>910
		{"x": 620.0, "y": 170.0, "prop": "rack", "len": 160.0, "yaw": 0.0},          # N — hide y<170
		{"x": 620.0, "y": 650.0, "prop": "rack", "len": 160.0, "yaw": 0.0},          # S — hide y>650
	],
	GY_SECRET: [  # the same cover-ring idea, larger, around Head Coach PRIME (@700,470) — its Total Camp Reset
		# fires often, so cover positions on every side are essential.
		{"x": 380.0,  "y": 470.0, "prop": "barrier", "len": 160.0, "yaw": 1.5708},   # W
		{"x": 1020.0, "y": 470.0, "prop": "barrier", "len": 160.0, "yaw": 1.5708},   # E
		{"x": 700.0,  "y": 200.0, "prop": "rack", "len": 180.0, "yaw": 0.0},          # N
		{"x": 700.0,  "y": 740.0, "prop": "rack", "len": 180.0, "yaw": 0.0},          # S
	],
	# Phase 8 — Away Circuit cover, mirroring the GY gradient (light on-ramp → heavier lanes).
	AWAY1: [
		{"x": 740.0,  "y": 330.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708}, {"x": 740.0,  "y": 620.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
		{"x": 1230.0, "y": 475.0, "prop": "rack", "len": 120.0, "yaw": 1.5708},
		{"x": 1420.0, "y": 330.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1420.0, "y": 620.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the Lot Marshal
	],
	AWAY2: [
		{"x": 740.0,  "y": 350.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 740.0,  "y": 650.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1180.0, "y": 500.0, "prop": "rack", "len": 130.0, "yaw": 1.5708},
		{"x": 1580.0, "y": 270.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1580.0, "y": 570.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the sled
	],
	AWAY3: [
		{"x": 740.0,  "y": 380.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 740.0,  "y": 720.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1300.0, "y": 550.0, "prop": "rack", "len": 140.0, "yaw": 1.5708},
		{"x": 1700.0, "y": 400.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1700.0, "y": 700.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the boss-door guard
	],
	AWAY_BOSS: [  # LIGHT cover only — the Rival Coach has no camp-reset ult, so no mandated LOS ring; these
		# panels are kite/juke cover for the sled-drive + crowd-surge phases.
		{"x": 380.0,  "y": 410.0, "prop": "barrier", "len": 140.0, "yaw": 1.5708},
		{"x": 860.0,  "y": 410.0, "prop": "barrier", "len": 140.0, "yaw": 1.5708},
		{"x": 620.0,  "y": 220.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 620.0, "y": 600.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
	FINALS1: [
		{"x": 740.0,  "y": 360.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 740.0,  "y": 700.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1180.0, "y": 530.0, "prop": "rack", "len": 130.0, "yaw": 1.5708},
		{"x": 1620.0, "y": 380.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1620.0, "y": 680.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # flank the gatling guard
	],
	FINALS2: [  # heavier cover — the Gallery's spread/carom volleys make these panels the fight's grammar
		{"x": 740.0,  "y": 380.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 740.0,  "y": 720.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1230.0, "y": 550.0, "prop": "rack", "len": 140.0, "yaw": 1.5708},
		{"x": 1800.0, "y": 430.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},   # the Gallery court's LOS-break wall
		{"x": 1680.0, "y": 400.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1680.0, "y": 700.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
	CAMP: [  # proving-room cover: mid barriers split the lanes + bags flank the elite gatekeeper
		{"x": 720.0,  "y": 300.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708}, {"x": 720.0, "y": 560.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
		{"x": 1300.0, "y": 300.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1300.0, "y": 560.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
	CAMP_B: [  # The Gauntlet — cover to break the turrets' line-of-sight
		{"x": 700.0,  "y": 320.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 700.0, "y": 600.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1080.0, "y": 460.0, "prop": "barrier", "len": 140.0, "yaw": 0.0},
		{"x": 1380.0, "y": 320.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1380.0, "y": 600.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
	CAMP_C: [  # The Scrimmage — lighter cover (open, to reach the medic)
		{"x": 760.0,  "y": 340.0, "prop": "barrier", "len": 110.0, "yaw": 1.5708}, {"x": 760.0, "y": 640.0, "prop": "barrier", "len": 110.0, "yaw": 1.5708},
		{"x": 1360.0, "y": 340.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1360.0, "y": 640.0, "prop": "bag", "len": 36.0, "yaw": 0.0},
	],
}

# the gate protecting ENTRY to `map` (scans portals leading to it), or "" if ungated. Lets the server
# re-validate a restored/teleported map against its gate (not just the walk-in portal path).
static func gate_for_map(map: String) -> String:
	for src in PORTALS:
		for p in PORTALS[src]:
			if str(p.get("to", "")) == map and p.has("gate"):
				return str(p["gate"])
	return ""

static func obstacles_for(map: String) -> Array:
	return OBSTACLES.get(map, [])

# Phase 3 — purely-visual decoration (no sim effect): painted drill rings ("ring") + scattered traffic
# cones ("cone") that give each zone its training-camp identity. Read CLIENT-side from the current map (the
# client preloads World.gd) and drawn by Client._render_decals — NOT sent over the wire.
const DECALS := {
	# WORKED EXAMPLE (home had no decals). All of these are purely cosmetic — no collision, client-only.
	# The "prop" entries pull free Kenney CC0 GLBs from models/kits (no Meshy credits). Tune x/y/h/yaw to
	# taste; press F3 in-game to read the sim-space coord under your cursor. See docs/map-authoring-guide.md.
	HOME: [
		{"kind": "ring", "x": 480.0, "y": 300.0, "r": 110.0},                                  # painted ring around the spawn
		{"kind": "cone", "x": 340.0, "y": 300.0}, {"kind": "cone", "x": 300.0, "y": 250.0},     # flank the ▶ Glitchyard pad
		{"kind": "prop", "model": "tree_oak",        "x": 110.0, "y": 470.0, "h": 3.4, "yaw": 0.3},
		{"kind": "prop", "model": "tree_pineRoundC", "x": 150.0, "y": 95.0,  "h": 3.6, "yaw": 0.0},
		{"kind": "prop", "model": "tree_default",    "x": 880.0, "y": 100.0, "h": 3.2, "yaw": 1.2},
		{"kind": "prop", "model": "tree_oak",        "x": 860.0, "y": 480.0, "h": 3.4, "yaw": 2.1},
		{"kind": "prop", "model": "rock_largeA",     "x": 200.0, "y": 385.0, "h": 1.3, "yaw": 0.6},
		{"kind": "prop", "model": "rock_largeC",     "x": 770.0, "y": 305.0, "h": 1.1, "yaw": 1.9},
		{"kind": "prop", "model": "plant_bushLarge", "x": 560.0, "y": 380.0, "h": 1.0, "yaw": 0.0},
		{"kind": "prop", "model": "plant_bush",      "x": 420.0, "y": 255.0, "h": 0.8, "yaw": 0.0},
		{"kind": "prop", "model": "fence_simple",    "x": 470.0, "y": 505.0, "h": 1.3, "yaw": 0.0},
		{"kind": "prop", "model": "fence_simple",    "x": 555.0, "y": 505.0, "h": 1.3, "yaw": 0.0},
		{"kind": "prop", "model": "fence_simple",    "x": 620.0, "y": 505.0, "h": 1.3, "yaw": 0.0},
	],
	GY1: [
		{"kind": "ring", "x": 750.0, "y": 425.0, "r": 140.0}, {"kind": "ring", "x": 1180.0, "y": 425.0, "r": 90.0},
		{"kind": "cone", "x": 540.0, "y": 280.0}, {"kind": "cone", "x": 540.0, "y": 570.0}, {"kind": "cone", "x": 1180.0, "y": 425.0},
	],
	GY2: [
		{"kind": "ring", "x": 825.0, "y": 450.0, "r": 150.0}, {"kind": "ring", "x": 1340.0, "y": 450.0, "r": 105.0},
		{"kind": "cone", "x": 700.0, "y": 300.0}, {"kind": "cone", "x": 700.0, "y": 600.0}, {"kind": "cone", "x": 1130.0, "y": 450.0},
	],
	GY3: [
		{"kind": "ring", "x": 900.0, "y": 490.0, "r": 150.0}, {"kind": "ring", "x": 1500.0, "y": 490.0, "r": 110.0},
		{"kind": "cone", "x": 720.0, "y": 320.0}, {"kind": "cone", "x": 720.0, "y": 660.0}, {"kind": "cone", "x": 1240.0, "y": 490.0},
	],
	GY4: [
		{"kind": "ring", "x": 950.0, "y": 520.0, "r": 150.0}, {"kind": "ring", "x": 1580.0, "y": 520.0, "r": 110.0},
		{"kind": "cone", "x": 720.0, "y": 340.0}, {"kind": "cone", "x": 720.0, "y": 700.0}, {"kind": "cone", "x": 1280.0, "y": 520.0},
	],
	GY5: [
		{"kind": "ring", "x": 1000.0, "y": 550.0, "r": 150.0}, {"kind": "ring", "x": 1620.0, "y": 550.0, "r": 120.0},
		{"kind": "cone", "x": 760.0, "y": 360.0}, {"kind": "cone", "x": 760.0, "y": 740.0}, {"kind": "cone", "x": 1320.0, "y": 550.0},
	],
	GY_BOSS: [
		{"kind": "ring", "x": 620.0, "y": 410.0, "r": 200.0}, {"kind": "ring", "x": 620.0, "y": 410.0, "r": 110.0},
		{"kind": "cone", "x": 620.0, "y": 290.0}, {"kind": "cone", "x": 620.0, "y": 530.0}, {"kind": "cone", "x": 480.0, "y": 410.0}, {"kind": "cone", "x": 760.0, "y": 410.0},
	],
	GY_SECRET: [
		{"kind": "ring", "x": 700.0, "y": 470.0, "r": 240.0}, {"kind": "ring", "x": 700.0, "y": 470.0, "r": 130.0},
		{"kind": "cone", "x": 700.0, "y": 320.0}, {"kind": "cone", "x": 700.0, "y": 620.0}, {"kind": "cone", "x": 540.0, "y": 470.0}, {"kind": "cone", "x": 860.0, "y": 470.0},
	],
	CAMP: [
		{"kind": "ring", "x": 760.0, "y": 430.0, "r": 150.0}, {"kind": "ring", "x": 1300.0, "y": 430.0, "r": 100.0},
		{"kind": "cone", "x": 520.0, "y": 300.0}, {"kind": "cone", "x": 520.0, "y": 560.0}, {"kind": "cone", "x": 1300.0, "y": 430.0},
	],
	CAMP_B: [
		{"kind": "ring", "x": 1000.0, "y": 460.0, "r": 140.0}, {"kind": "ring", "x": 1420.0, "y": 460.0, "r": 100.0},
		{"kind": "cone", "x": 500.0, "y": 320.0}, {"kind": "cone", "x": 500.0, "y": 600.0},
	],
	CAMP_C: [
		{"kind": "ring", "x": 1000.0, "y": 480.0, "r": 150.0}, {"kind": "ring", "x": 1440.0, "y": 480.0, "r": 100.0},
		{"kind": "cone", "x": 540.0, "y": 340.0}, {"kind": "cone", "x": 540.0, "y": 640.0},
	],
}

static func decals_for(map: String) -> Array:
	return DECALS.get(map, [])

static func cfg(map: String) -> Dictionary:
	return MAPS.get(map, MAPS[HOME])

# the login/arrival spawn for a world (safe maps spawn here; combat maps use it as a fallback)
static func spawn_for(map: String) -> Vector2:
	var c: Dictionary = MAPS.get(map, MAPS[HOME])
	return c.get("spawn", HOME_SPAWN)

# slim portal list for snapshots (the client only needs to draw them)
static func portals_for(map: String) -> Array:
	var out := []
	for p in PORTALS.get(map, []):
		out.append({"x": p["x"], "y": p["y"], "label": p["label"]})
	return out
