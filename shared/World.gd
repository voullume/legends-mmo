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

# Spawn / arrival points per world (the fixed login spawn for safe maps; the portal drop-point for the rest).
const HOME_SPAWN := Vector2(480, 300)        # players appear / return here in the home base
const GY1_SPAWN := Vector2(200, 425)         # the Home→Glitchyard portal drops you here (west, clear of camps)
const GY2_SPAWN := Vector2(200, 450)
const GY3_SPAWN := Vector2(220, 490)
const GY4_SPAWN := Vector2(220, 520)
const GY5_SPAWN := Vector2(220, 550)
const GYB_SPAWN := Vector2(140, 410)         # boss arena: arrive far WEST, well clear of the central boss camp
const GYS_SPAWN := Vector2(160, 460)         # secret arena: arrive far WEST of Head Coach PRIME
const ARENA_SPAWN := Vector2(200, 400)       # the Home→Arena portal drops you here

# Per-map config. type drives spawn (safe = fixed spawn, else resume-at-logout); w/h = arena size;
# regen = max-HP fraction healed per second; regen_delay = seconds after a hit before regen resumes
# (0 = always); aggro = whether mobs chase players here; pvp = players are mutually hostile here
# (true for the Arena — free-for-all); spawn = login/arrival point. The Glitchyard zones grow in size
# along the gradient so later zones have more room for their tougher, cover-heavy fights.
const MAPS := {
	HOME:  {"type": "safe",   "w": 960,  "h": 540,  "regen": 0.12,  "regen_delay": 0.0, "aggro": false, "pvp": false, "spawn": HOME_SPAWN},
	GY1:   {"type": "combat", "w": 1500, "h": 850,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY1_SPAWN},
	GY2:   {"type": "combat", "w": 1650, "h": 900,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY2_SPAWN},
	GY3:   {"type": "combat", "w": 1800, "h": 980,  "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY3_SPAWN},
	GY4:   {"type": "combat", "w": 1900, "h": 1040, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY4_SPAWN},
	GY5:   {"type": "combat", "w": 2000, "h": 1100, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": GY5_SPAWN},
	GY_BOSS: {"type": "combat", "w": 1240, "h": 820, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": GYB_SPAWN},
	GY_SECRET: {"type": "combat", "w": 1440, "h": 940, "regen": 0.012, "regen_delay": 6.0, "aggro": true, "pvp": false, "spawn": GYS_SPAWN},
	ARENA: {"type": "combat", "w": 1200, "h": 800,  "regen": 0.012, "regen_delay": 6.0, "aggro": false, "pvp": true,  "spawn": ARENA_SPAWN},
}

const DUMMY_POS := Vector2(660, 300)         # the training dummy (home only)
const DUMMY_CLASS := "linebacker"            # a tanky punching bag
const PORTAL_RADIUS := 42.0                  # stepping this close to a pad teleports you
const SHOP_POS := Vector2(700, 150)          # the shop pad (home base only) — stand near it to open the shop
const SHOP_RADIUS := 80.0
const FORGE_POS := Vector2(480, 150)         # the forge pad (home base only) — upgrade/salvage gear here
const FORGE_RADIUS := 80.0
const QUESTGIVER_POS := Vector2(250, 150)    # the quest giver (home base only) — stand near it to accept/turn in quests
const QUESTGIVER_RADIUS := 80.0
const PRACTICE_POS := Vector2(830, 400)      # the Practice Vendor (home base only) — spend Practice Tokens on the Rookie Camp set (clear of the shop pad)
const PRACTICE_RADIUS := 80.0

# Portal pads per world: within PORTAL_RADIUS of {x,y} → teleport to world `to` at (tx,ty).
# Zone graph:  Home ↔ Arena,  Home → Glitchyard 1 ↔ 2 ↔ 3 ↔ 4 ↔ 5  (a linear chain; you arrive west, the
# forward pad sits far east past the camps). Back-portal drop points (tx,ty) land you in the PREVIOUS zone
# clear of its forward pad (> PORTAL_RADIUS) so you don't instantly bounce back.
const PORTALS := {
	HOME: [
		{"x": 300.0,  "y": 300.0, "to": GY1,   "tx": 200.0,  "ty": 425.0, "label": "▶ Glitchyard"},
		{"x": 660.0,  "y": 460.0, "to": ARENA, "tx": 200.0,  "ty": 400.0, "label": "▶ Arena"},
	],
	GY1: [
		{"x": 120.0,  "y": 425.0,  "to": HOME, "tx": 480.0,  "ty": 300.0, "label": "▶ Home Base"},
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
		{"x": 1900.0, "y": 350.0,  "to": GY_BOSS, "tx": 140.0,  "ty": 410.0, "label": "▶ Head Coach Arena"},
	],
	GY_BOSS: [
		# back to GY5, dropping clear of the drill camp (@1620,550, > AGGRO 320). The boss is central, far from
		# this west pad, so an arriving group isn't insta-pulled.
		{"x": 80.0,   "y": 410.0,  "to": GY5,     "tx": 1500.0, "ty": 250.0, "label": "◀ Command Tower"},
		# the SECRET portal (far east, past Boss1) — gated: hidden + inert until EVERY quest is done (incl.
		# beating Boss1). Server hides it from the snapshot + refuses the teleport until _all_quests_done.
		{"x": 1150.0, "y": 410.0,  "to": GY_SECRET, "tx": 160.0, "ty": 460.0, "gate": "all_quests", "label": "▶ ??? — The Final Lesson"},
	],
	GY_SECRET: [
		# drop WEST of the secret pad (@1150,410) so returning doesn't instantly bounce back through it.
		{"x": 80.0,   "y": 460.0,  "to": GY_BOSS, "tx": 980.0, "ty": 410.0, "label": "◀ Head Coach Arena"},
	],
	ARENA: [
		{"x": 110.0,  "y": 400.0,  "to": HOME, "tx": 480.0,  "ty": 300.0, "label": "▶ Home Base"},
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
		{"class": "foam_dummy",      "level": 4, "tier": "minion", "x": 520.0,  "y": 320.0},
		{"class": "cone_swarmer",    "level": 4, "tier": "minion", "x": 520.0,  "y": 660.0},
		{"class": "shooting_dummy",  "level": 5, "tier": "minion", "x": 980.0,  "y": 320.0},
		{"class": "foam_dummy",      "level": 5, "tier": "minion", "x": 980.0,  "y": 660.0},
		{"class": "sled_juggernaut", "level": 5, "tier": "elite",  "x": 1500.0, "y": 490.0},
	],
	GY4: [  # Target Court — the Ball Machine turret (+ a second sled)
		{"class": "shooting_dummy",  "level": 5, "tier": "minion", "x": 520.0,  "y": 340.0},
		{"class": "foam_dummy",      "level": 5, "tier": "minion", "x": 520.0,  "y": 700.0},
		{"class": "shooting_dummy",  "level": 6, "tier": "minion", "x": 980.0,  "y": 340.0},
		{"class": "sled_juggernaut", "level": 6, "tier": "elite",  "x": 980.0,  "y": 700.0},
		{"class": "ball_machine",    "level": 6, "tier": "elite",  "x": 1580.0, "y": 520.0},
	],
	GY5: [  # Command Tower — the Drill Sergeant summoner anchors the chain's end (boss = Phase 4)
		{"class": "cone_swarmer",    "level": 7, "tier": "minion", "x": 500.0,  "y": 360.0},
		{"class": "cone_swarmer",    "level": 7, "tier": "minion", "x": 500.0,  "y": 740.0},
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
	GY_SECRET: [  # Head Coach PRIME (secret raid boss) + 6 power cores — the cores SHIELD it (60% DR while up),
		# so the raid must keep them down. Their level is higher so they take a moment to clear each cycle.
		{"class": "head_coach_prime", "level": 10, "tier": "boss",   "x": 700.0, "y": 470.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 500.0, "y": 330.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 500.0, "y": 610.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 700.0, "y": 250.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 700.0, "y": 690.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 900.0, "y": 360.0},
		{"class": "power_core",       "level": 7,  "tier": "minion", "x": 900.0, "y": 580.0},
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
}
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
}

static func obstacles_for(map: String) -> Array:
	return OBSTACLES.get(map, [])

# Phase 3 — purely-visual decoration (no sim effect): painted drill rings ("ring") + scattered traffic
# cones ("cone") that give each zone its training-camp identity. Read CLIENT-side from the current map (the
# client preloads World.gd) and drawn by Client._render_decals — NOT sent over the wire.
const DECALS := {
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
