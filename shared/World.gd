extends RefCounted
## Two-world layout for the shared zone:
##   HOME   — a safe base: roam freely, a training dummy to hit (passive, instant-respawn, no rewards).
##   COMBAT — the testing zone: aggressive mobs, XP, and loot drops.
## A portal pad in each world teleports the player to the other. Both worlds use the same 960×540
## arena coordinate space but are SEPARATE sims, so players in one never see/affect the other.

const HOME := "home"
const COMBAT := "combat"

const HOME_SPAWN := Vector2(480, 300)       # where players appear / return in the home base
const COMBAT_SPAWN := Vector2(140, 300)     # where the home portal drops you in combat (safely west of the mobs)
const DUMMY_POS := Vector2(660, 300)        # the training dummy, east of the home spawn
const DUMMY_CLASS := "linebacker"           # a tanky punching bag
const PORTAL_RADIUS := 42.0                 # stepping this close to a pad teleports you

# Portal pads per world. Stepping within PORTAL_RADIUS of {x,y} teleports to world `to` at (tx,ty).
const PORTALS := {
	HOME: [{"x": 300.0, "y": 300.0, "to": COMBAT, "tx": 140.0, "ty": 300.0, "label": "▶ Combat Zone"}],
	COMBAT: [{"x": 140.0, "y": 470.0, "to": HOME, "tx": 480.0, "ty": 300.0, "label": "▶ Home Base"}],
}

# Mob camps live in the COMBAT world only — a difficulty gradient from the portal arrival (west) east.
const MOBS := [
	{"class": "setter", "level": 1, "tier": "minion", "x": 480.0, "y": 175.0},
	{"class": "spiker", "level": 1, "tier": "minion", "x": 480.0, "y": 365.0},
	{"class": "striker", "level": 2, "tier": "minion", "x": 700.0, "y": 200.0},
	{"class": "batter", "level": 2, "tier": "minion", "x": 700.0, "y": 340.0},
	{"class": "linebacker", "level": 3, "tier": "elite", "x": 870.0, "y": 270.0},
]

# slim portal list for snapshots (the client only needs to draw them)
static func portals_for(map: String) -> Array:
	var out := []
	for p in PORTALS.get(map, []):
		out.append({"x": p["x"], "y": p["y"], "label": p["label"]})
	return out
