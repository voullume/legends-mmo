extends RefCounted
## World layout for the shared zone. Each map has a TYPE that drives gameplay:
##   safe   — no mob aggro, strong health regen (the home base, future towns).
##   combat — mobs chase, weak out-of-combat regen, bigger arena (the testing/mob zones).
## Worlds are independent sims; a portal pad in each teleports the player to the other. Arena size is
## per-map (each fighter carries its world's bounds), so maps can differ in size.

const HOME := "home"
const COMBAT := "combat"

# Per-map config. w/h = arena size; regen = max-HP fraction healed per second; regen_delay = seconds
# after taking damage before regen resumes (0 = always); aggro = whether mobs chase players here.
const MAPS := {
	HOME:   {"type": "safe",   "w": 960,  "h": 540,  "regen": 0.12, "regen_delay": 0.0, "aggro": false},
	COMBAT: {"type": "combat", "w": 1920, "h": 1080, "regen": 0.012, "regen_delay": 6.0, "aggro": true},
}

const HOME_SPAWN := Vector2(480, 300)        # players appear / return here in the home base
const COMBAT_SPAWN := Vector2(200, 540)      # the home portal drops you here (west, clear of the camps)
const DUMMY_POS := Vector2(660, 300)         # the training dummy
const DUMMY_CLASS := "linebacker"            # a tanky punching bag
const PORTAL_RADIUS := 42.0                  # stepping this close to a pad teleports you

# Portal pads per world: within PORTAL_RADIUS of {x,y} → teleport to world `to` at (tx,ty).
const PORTALS := {
	HOME:   [{"x": 300.0, "y": 300.0, "to": COMBAT, "tx": 200.0, "ty": 540.0, "label": "▶ Combat Zone"}],
	COMBAT: [{"x": 200.0, "y": 760.0, "to": HOME, "tx": 480.0, "ty": 300.0, "label": "▶ Home Base"}],
}

# Mob camps (COMBAT only), spread across the big arena so engaging one doesn't pull the next
# (each camp is > AGGRO_RANGE from its neighbours). A difficulty gradient from the arrival (west) east.
const MOBS := [
	{"class": "setter", "level": 1, "tier": "minion", "x": 600.0, "y": 300.0},
	{"class": "spiker", "level": 1, "tier": "minion", "x": 600.0, "y": 780.0},
	{"class": "striker", "level": 2, "tier": "minion", "x": 1150.0, "y": 300.0},
	{"class": "batter", "level": 2, "tier": "minion", "x": 1150.0, "y": 780.0},
	{"class": "linebacker", "level": 3, "tier": "elite", "x": 1700.0, "y": 540.0},
]

static func cfg(map: String) -> Dictionary:
	return MAPS.get(map, MAPS[HOME])

# slim portal list for snapshots (the client only needs to draw them)
static func portals_for(map: String) -> Array:
	var out := []
	for p in PORTALS.get(map, []):
		out.append({"x": p["x"], "y": p["y"], "label": p["label"]})
	return out
