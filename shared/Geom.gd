extends RefCounted
## Geometry helpers — dist / clampArena / segBlocked / hasLOS.
## Ports use Vector2.length() in place of JS Math.hypot (same math).

const GameData := preload("res://shared/GameData.gd")

static func dist(a: Dictionary, b: Dictionary) -> float:
	return Vector2(a["x"] - b["x"], a["y"] - b["y"]).length()

static func clamp_arena(f: Dictionary) -> void:
	f["x"] = clampf(f["x"], float(GameData.ARENA_PAD), float(GameData.ARENA_W - GameData.ARENA_PAD))
	f["y"] = clampf(f["y"], float(GameData.ARENA_PAD), float(GameData.ARENA_H - GameData.ARENA_PAD))

# A segment from (x1,y1)->(x2,y2) is blocked if it passes within (o.r + pad) of rig o.
static func seg_blocked(x1: float, y1: float, x2: float, y2: float, o: Dictionary, pad := 6.0) -> bool:
	var dx := x2 - x1
	var dy := y2 - y1
	var l2 := dx * dx + dy * dy
	if l2 < 1.0:
		return Vector2(o["x"] - x1, o["y"] - y1).length() < o["r"] + pad
	var t: float = ((o["x"] - x1) * dx + (o["y"] - y1) * dy) / l2
	t = clampf(t, 0.0, 1.0)
	return Vector2(o["x"] - (x1 + dx * t), o["y"] - (y1 + dy * t)).length() < o["r"] + pad

static func has_los(state: Dictionary, a: Dictionary, b: Dictionary) -> bool:
	for o in state["map"]["obstacles"]:
		if seg_blocked(a["x"], a["y"], b["x"], b["y"], o):
			return false
	return true
