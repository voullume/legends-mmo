extends RefCounted
## World layout for the shared zone. Each map has a TYPE that drives spawn behaviour:
##   safe   — no mob aggro, strong health regen, fixed login spawn (the home base / future towns).
##   combat — mobs chase, weak out-of-combat regen, bigger arena; you resume where you logged out.
## Worlds are independent sims; portal pads teleport between them. Arena size is per-map (each fighter
## carries its world's bounds), so maps can differ in size. A per-map `pvp` flag (true for the Arena)
## drives open-PvP: Combat.is_hostile/is_ally make all players mutually hostile (free-for-all) there.

const HOME := "home"
const COMBAT := "combat"
const FRONTIER := "frontier"               # higher-tier PvE zone (lvl 4-7 + a boss), gated behind Combat
const DEPTHS := "depths"                    # endgame PvE zone (lvl 8-12 + a boss), gated behind the Frontier
const ARENA := "arena"                     # dedicated open-PvP space (free-for-all: all players fight)

# Spawn / arrival points per world (the fixed login spawn for safe maps; the portal drop-point for the rest).
const HOME_SPAWN := Vector2(480, 300)        # players appear / return here in the home base
const COMBAT_SPAWN := Vector2(200, 540)      # the home portal drops you here (west, clear of the camps)
const FRONTIER_SPAWN := Vector2(220, 620)    # the Combat→Frontier portal drops you here (west)
const DEPTHS_SPAWN := Vector2(220, 650)      # the Frontier→Depths portal drops you here (west)
const ARENA_SPAWN := Vector2(200, 400)       # the Home→Arena portal drops you here

# Per-map config. type drives spawn (safe = fixed spawn, else resume-at-logout); w/h = arena size;
# regen = max-HP fraction healed per second; regen_delay = seconds after a hit before regen resumes
# (0 = always); aggro = whether mobs chase players here; pvp = players are mutually hostile here
# (true for the Arena — free-for-all); spawn = login/arrival point.
const MAPS := {
	HOME:     {"type": "safe",   "w": 960,  "h": 540,  "regen": 0.12,  "regen_delay": 0.0, "aggro": false, "pvp": false, "spawn": HOME_SPAWN},
	COMBAT:   {"type": "combat", "w": 1920, "h": 1080, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": COMBAT_SPAWN},
	FRONTIER: {"type": "combat", "w": 2200, "h": 1240, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": FRONTIER_SPAWN},
	DEPTHS:   {"type": "combat", "w": 2400, "h": 1300, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": DEPTHS_SPAWN},
	ARENA:    {"type": "combat", "w": 1200, "h": 800,  "regen": 0.012, "regen_delay": 6.0, "aggro": false, "pvp": true,  "spawn": ARENA_SPAWN},
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

# Portal pads per world: within PORTAL_RADIUS of {x,y} → teleport to world `to` at (tx,ty).
# Zone graph:  Home ↔ Combat,  Home ↔ Arena,  Combat ↔ Frontier  (Frontier sits past the Combat camps).
const PORTALS := {
	HOME: [
		{"x": 300.0,  "y": 300.0, "to": COMBAT,   "tx": 200.0,  "ty": 540.0, "label": "▶ Combat Zone"},
		{"x": 660.0,  "y": 460.0, "to": ARENA,    "tx": 200.0,  "ty": 400.0, "label": "▶ Arena"},
	],
	COMBAT: [
		{"x": 200.0,  "y": 760.0,  "to": HOME,     "tx": 480.0,  "ty": 300.0, "label": "▶ Home Base"},
		{"x": 1850.0, "y": 540.0,  "to": FRONTIER, "tx": 220.0,  "ty": 620.0, "label": "▶ Frontier"},
	],
	FRONTIER: [
		# arrive SE in Combat — clear of the lvl-3 elite camp at (1700,540) so you aren't instantly aggroed on return
		{"x": 120.0,  "y": 620.0,  "to": COMBAT,   "tx": 1850.0, "ty": 900.0, "label": "▶ Combat Zone"},
		# the Depths pad sits past the Frontier boss (far SE) — gated behind clearing the Frontier
		{"x": 2120.0, "y": 980.0,  "to": DEPTHS,   "tx": 220.0,  "ty": 650.0, "label": "▶ The Depths"},
	],
	DEPTHS: [
		{"x": 120.0,  "y": 650.0,  "to": FRONTIER, "tx": 1900.0, "ty": 1000.0, "label": "▶ Frontier"},
	],
	ARENA: [
		{"x": 110.0,  "y": 400.0,  "to": HOME,     "tx": 480.0,  "ty": 300.0, "label": "▶ Home Base"},
	],
}

# Mob camps per combat world, spread so engaging one doesn't pull the next (> AGGRO_RANGE apart, with a
# difficulty gradient from the arrival side). Tougher zones lean on higher `level` + tier (minion/elite/
# boss) — _scale_mob handles the scaling, no new stat blocks. The Arena has none (it is a PvP space).
const MOBS := {
	# Glitchyard Phase 1: the Combat camp is re-skinned to the new sports-equipment mobs to prove the
	# mob-framework pipeline end-to-end (the full 5-subzone glitchyard_1..5 rebuild is Phase 3). The *2
	# GLBs (foam/shooting) are alternate cosmetic skins picked per-spawn client-side. tackle_brute fills
	# the elite slot for now (no dedicated elites until Phase 2's summon/hazard work).
	COMBAT: [
		{"class": "cone_swarmer",   "level": 1, "tier": "minion", "x": 600.0,  "y": 300.0},
		{"class": "cone_swarmer",   "level": 1, "tier": "minion", "x": 600.0,  "y": 780.0},
		{"class": "foam_dummy",     "level": 2, "tier": "minion", "x": 1150.0, "y": 300.0},
		{"class": "shooting_dummy", "level": 2, "tier": "minion", "x": 1150.0, "y": 780.0},
		{"class": "tackle_brute",   "level": 3, "tier": "elite",  "x": 1700.0, "y": 540.0},
	],
	# Glitchyard Phase 2: Frontier re-skinned to the new mobs + the 3 elites (summon + hazard zones live).
	# The Drill Sergeant (deepest) summons cone adds + drops a Conditioning Drill hazard; Sled Juggernaut
	# pushes/slams; Ball Machine is a stationary turret. (The head_coach boss replaces the endpoint in P4.)
	FRONTIER: [
		{"class": "foam_dummy",      "level": 4, "tier": "minion", "x": 520.0,  "y": 420.0},
		{"class": "cone_swarmer",    "level": 4, "tier": "minion", "x": 520.0,  "y": 860.0},
		{"class": "shooting_dummy",  "level": 5, "tier": "minion", "x": 1080.0, "y": 420.0},
		{"class": "sled_juggernaut", "level": 5, "tier": "elite",  "x": 1080.0, "y": 860.0},
		{"class": "ball_machine",    "level": 6, "tier": "elite",  "x": 1600.0, "y": 640.0},
		{"class": "drill_sergeant",  "level": 7, "tier": "elite",  "x": 2000.0, "y": 640.0},
	],
	DEPTHS: [
		{"class": "quarterback", "level": 8,  "tier": "minion", "x": 560.0,  "y": 430.0},
		{"class": "spiker",      "level": 8,  "tier": "minion", "x": 560.0,  "y": 870.0},
		{"class": "pitcher",     "level": 9,  "tier": "minion", "x": 1100.0, "y": 430.0},
		{"class": "striker",     "level": 9,  "tier": "minion", "x": 1100.0, "y": 870.0},
		{"class": "goalkeeper",  "level": 10, "tier": "elite",  "x": 1650.0, "y": 650.0},
		{"class": "linebacker",  "level": 12, "tier": "boss",   "x": 2150.0, "y": 650.0},
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
	# Panels run perpendicular to the player's approach (yaw≈PI/2 = a N–S wall blocking the eastward push),
	# split into lanes so the camps stay reachable. Bags are square pillars (len = footprint, single circle).
	COMBAT: [
		{"x": 900.0,  "y": 300.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 900.0,  "y": 780.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1150.0, "y": 540.0, "prop": "bag", "len": 36.0, "yaw": 0.0},     # heavy-bag pillar among the mid camps
		{"x": 1425.0, "y": 420.0, "prop": "rack", "len": 130.0, "yaw": 1.5708}, {"x": 1425.0, "y": 660.0, "prop": "rack", "len": 130.0, "yaw": 1.5708},
		{"x": 1700.0, "y": 330.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1700.0, "y": 750.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # bag pillars flanking the elite
		{"x": 380.0,  "y": 540.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
	],
	FRONTIER: [
		{"x": 800.0,  "y": 420.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708}, {"x": 800.0,  "y": 860.0, "prop": "barrier", "len": 130.0, "yaw": 1.5708},
		{"x": 1340.0, "y": 520.0, "prop": "rack", "len": 140.0, "yaw": 1.5708}, {"x": 1340.0, "y": 760.0, "prop": "rack", "len": 140.0, "yaw": 1.5708},
		{"x": 1600.0, "y": 400.0, "prop": "bag", "len": 36.0, "yaw": 0.0}, {"x": 1600.0, "y": 880.0, "prop": "bag", "len": 36.0, "yaw": 0.0},  # bag pillars flanking the ball machine
		{"x": 1820.0, "y": 640.0, "prop": "rack", "len": 130.0, "yaw": 1.5708},
		{"x": 360.0,  "y": 640.0, "prop": "barrier", "len": 120.0, "yaw": 1.5708},
	],
}

static func obstacles_for(map: String) -> Array:
	return OBSTACLES.get(map, [])

# Phase 3 — purely-visual decoration (no sim effect): painted drill rings ("ring") + scattered traffic
# cones ("cone") that give each zone its training-camp identity. Read CLIENT-side from the current map (the
# client preloads World.gd) and drawn by Client._render_decals — NOT sent over the wire.
const DECALS := {
	COMBAT: [
		{"kind": "ring", "x": 960.0,  "y": 540.0, "r": 150.0},
		{"kind": "ring", "x": 600.0,  "y": 540.0, "r": 95.0},  {"kind": "ring", "x": 1150.0, "y": 540.0, "r": 95.0},
		{"kind": "ring", "x": 1700.0, "y": 540.0, "r": 120.0},
		{"kind": "cone", "x": 760.0,  "y": 420.0}, {"kind": "cone", "x": 760.0,  "y": 660.0},
		{"kind": "cone", "x": 1300.0, "y": 410.0}, {"kind": "cone", "x": 1300.0, "y": 670.0},
		{"kind": "cone", "x": 1560.0, "y": 540.0}, {"kind": "cone", "x": 420.0,  "y": 540.0},
	],
	FRONTIER: [
		{"kind": "ring", "x": 1100.0, "y": 640.0, "r": 150.0},
		{"kind": "ring", "x": 520.0,  "y": 640.0, "r": 95.0},  {"kind": "ring", "x": 1080.0, "y": 640.0, "r": 95.0},
		{"kind": "ring", "x": 1600.0, "y": 640.0, "r": 110.0}, {"kind": "ring", "x": 2000.0, "y": 640.0, "r": 110.0},
		{"kind": "cone", "x": 720.0,  "y": 520.0}, {"kind": "cone", "x": 720.0,  "y": 760.0},
		{"kind": "cone", "x": 1300.0, "y": 520.0}, {"kind": "cone", "x": 1300.0, "y": 760.0},
		{"kind": "cone", "x": 1830.0, "y": 540.0}, {"kind": "cone", "x": 1830.0, "y": 740.0},
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
