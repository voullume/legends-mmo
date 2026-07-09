extends SceneTree
## Verifies the client-side local-player prediction ALGORITHM (a faithful replica of Client._predict_local):
## integrate live input each frame, reconcile toward the authoritative server pos, hard-snap on a big error,
## clamp to arena. Checks it CONVERGES (never diverges/oscillates), leads during movement, and snaps on teleport.

const SNAP := 70.0
const RECONCILE := 8.0
const PAD := 50.0
const AW := 1800.0
const AH := 1200.0
const DT := 1.0 / 60.0

var pass_n := 0
var fail_n := 0
func ok(c: bool, l: String) -> void:
	if c: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % l)

var _pred := Vector2.ZERO
var _on := false
func step(srv: Vector2, mv: Vector2, spd: float) -> void:
	if not _on:
		_pred = srv; _on = true
	var ml := mv.length()
	if ml > 0.001:
		_pred += (mv / ml) * spd * DT
	var err := srv - _pred
	if err.length() > SNAP:
		_pred = srv
	else:
		_pred += err * clampf(DT * RECONCILE, 0.0, 1.0)
	_pred.x = clampf(_pred.x, PAD, AW - PAD)
	_pred.y = clampf(_pred.y, PAD, AH - PAD)

func _init() -> void:
	# 1. idle, seeded on server → stays put (no drift)
	_pred = Vector2.ZERO; _on = false
	for i in 30: step(Vector2(500, 500), Vector2.ZERO, 130.0)
	ok(_pred.distance_to(Vector2(500, 500)) < 0.01, "idle prediction stays exactly on the server pos")

	# 2. idle but pred starts offset from server → converges toward server (no oscillation)
	_pred = Vector2(600, 500); _on = true
	var prev := 9999.0
	var mono := true
	for i in 60:
		step(Vector2(500, 500), Vector2.ZERO, 130.0)
		var d := _pred.distance_to(Vector2(500, 500))
		if d > prev + 0.001: mono = false           # distance must never grow (no overshoot/oscillation)
		prev = d
	ok(mono, "an offset prediction converges monotonically toward the server (no oscillation)")
	ok(_pred.distance_to(Vector2(500, 500)) < 5.0, "converges close to the server pos when idle (%.1f left)" % prev)

	# 3. continuous movement, server LAGS (stays put this test) → pred LEADS but stays BOUNDED (no runaway)
	_pred = Vector2(500, 500); _on = true
	for i in 120: step(Vector2(500, 500), Vector2(1, 0), 130.0)   # holding right, server frozen (worst case)
	var lead := _pred.x - 500.0
	ok(lead > 0.0, "prediction leads the (stale) server while moving — responsive")
	ok(lead < SNAP, "the lead stays bounded below the snap threshold (%.1f < %.0f) — no runaway" % [lead, SNAP])

	# 4. teleport / dash: server jumps far → snap, not a slow crawl
	_pred = Vector2(500, 500); _on = true
	step(Vector2(1200, 900), Vector2.ZERO, 130.0)                # server teleported ~800 units
	ok(_pred.distance_to(Vector2(1200, 900)) < 1.0, "a big server jump (teleport/dash) snaps immediately")

	# 5. arena clamp: can't predict off the map edge
	_pred = Vector2(PAD + 5, 500); _on = true
	for i in 60: step(Vector2(PAD + 5, 500), Vector2(-1, 0), 200.0)   # shove left into the wall
	ok(_pred.x >= PAD - 0.01, "prediction clamps at the arena boundary (x=%.1f >= %.0f)" % [_pred.x, PAD])

	# 6. when input stops, the lead resolves back to the server (crisp stop)
	_pred = Vector2(560, 500); _on = true                        # left with a 60u lead
	for i in 90: step(Vector2(500, 500), Vector2.ZERO, 130.0)
	ok(_pred.distance_to(Vector2(500, 500)) < 2.0, "after releasing input, prediction settles onto the server pos")

	print("=== prediction: %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
