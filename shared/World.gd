extends RefCounted
## World layout for the shared zone. Each map has a TYPE that drives spawn behaviour:
##   safe   — no mob aggro, strong health regen, fixed login spawn (the home base / future towns).
##   combat — mobs chase, weak out-of-combat regen, bigger arena; you resume where you logged out.
## Worlds are independent sims; portal pads teleport between them. Arena size is per-map (each fighter
## carries its world's bounds), so maps can differ in size. A per-map `pvp` flag is reserved for the
## Arena — open-PvP lands in a later phase, so it stays inert (false) until the combat engine consults it.

const HOME := "home"
const COMBAT := "combat"
const FRONTIER := "frontier"               # higher-tier PvE zone (lvl 4-7 + a boss), gated behind Combat
const ARENA := "arena"                     # dedicated PvP space (PvE-safe for now; pvp flips on in the PvP phase)

# Spawn / arrival points per world (the fixed login spawn for safe maps; the portal drop-point for the rest).
const HOME_SPAWN := Vector2(480, 300)        # players appear / return here in the home base
const COMBAT_SPAWN := Vector2(200, 540)      # the home portal drops you here (west, clear of the camps)
const FRONTIER_SPAWN := Vector2(220, 620)    # the Combat→Frontier portal drops you here (west)
const ARENA_SPAWN := Vector2(200, 400)       # the Home→Arena portal drops you here

# Per-map config. type drives spawn (safe = fixed spawn, else resume-at-logout); w/h = arena size;
# regen = max-HP fraction healed per second; regen_delay = seconds after a hit before regen resumes
# (0 = always); aggro = whether mobs chase players here; pvp = players are mutually hostile here
# (reserved — inert until the open-PvP phase); spawn = login/arrival point.
const MAPS := {
	HOME:     {"type": "safe",   "w": 960,  "h": 540,  "regen": 0.12,  "regen_delay": 0.0, "aggro": false, "pvp": false, "spawn": HOME_SPAWN},
	COMBAT:   {"type": "combat", "w": 1920, "h": 1080, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": COMBAT_SPAWN},
	FRONTIER: {"type": "combat", "w": 2200, "h": 1240, "regen": 0.012, "regen_delay": 6.0, "aggro": true,  "pvp": false, "spawn": FRONTIER_SPAWN},
	ARENA:    {"type": "combat", "w": 1200, "h": 800,  "regen": 0.012, "regen_delay": 6.0, "aggro": false, "pvp": false, "spawn": ARENA_SPAWN},
}

const DUMMY_POS := Vector2(660, 300)         # the training dummy (home only)
const DUMMY_CLASS := "linebacker"            # a tanky punching bag
const PORTAL_RADIUS := 42.0                  # stepping this close to a pad teleports you
const SHOP_POS := Vector2(700, 150)          # the shop pad (home base only) — stand near it to open the shop
const SHOP_RADIUS := 80.0
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
	],
	ARENA: [
		{"x": 110.0,  "y": 400.0,  "to": HOME,     "tx": 480.0,  "ty": 300.0, "label": "▶ Home Base"},
	],
}

# Mob camps per combat world, spread so engaging one doesn't pull the next (> AGGRO_RANGE apart, with a
# difficulty gradient from the arrival side). Tougher zones lean on higher `level` + tier (minion/elite/
# boss) — _scale_mob handles the scaling, no new stat blocks. The Arena has none (it is a PvP space).
const MOBS := {
	COMBAT: [
		{"class": "setter",      "level": 1, "tier": "minion", "x": 600.0,  "y": 300.0},
		{"class": "spiker",      "level": 1, "tier": "minion", "x": 600.0,  "y": 780.0},
		{"class": "striker",     "level": 2, "tier": "minion", "x": 1150.0, "y": 300.0},
		{"class": "batter",      "level": 2, "tier": "minion", "x": 1150.0, "y": 780.0},
		{"class": "linebacker",  "level": 3, "tier": "elite",  "x": 1700.0, "y": 540.0},
	],
	FRONTIER: [
		{"class": "spiker",      "level": 4, "tier": "minion", "x": 520.0,  "y": 420.0},
		{"class": "striker",     "level": 4, "tier": "minion", "x": 520.0,  "y": 860.0},
		{"class": "pitcher",     "level": 5, "tier": "minion", "x": 1080.0, "y": 420.0},
		{"class": "setter",      "level": 5, "tier": "minion", "x": 1080.0, "y": 860.0},
		{"class": "batter",      "level": 6, "tier": "elite",  "x": 1600.0, "y": 640.0},
		{"class": "goalkeeper",  "level": 7, "tier": "boss",   "x": 2000.0, "y": 640.0},
	],
}

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
