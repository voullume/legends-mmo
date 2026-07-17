extends SceneTree
## Part A (world-text/nameplate pass) — pins the PURE math behind the world-proportional player plate
## so a future tweak to WorldUI can't silently break the "anchored, gentle, bounded" guarantees:
##   • plate_dist_scale — clamped to [MIN,MAX]; monotone non-decreasing in distance; == 1.0 at the
##     reference distance; strictly between the extremes inside the supported zoom band → the plate
##     breathes with zoom but never snaps to constant-screen or vanishes.
##   • clamp_name — bounded long-name policy: never exceeds the char cap, appends an ellipsis only when
##     it actually truncated, leaves short/empty names untouched.
##   • wobble_lit — 0..WOBBLE_MAX pips, ceil, clamped.
## Headless: ~/.local/bin/godot --headless --path . --script res://tools/worldui_plate_test.gd
## Exits non-zero on any failure (CI-compatible; greppable "FAIL").

const WorldUIS := preload("res://client/ui/WorldUI.gd")

# Client camera-distance band (Client.DIST_MIN … DIST_MAX) — the supported zoom extremes.
const DIST_MIN := 10.0
const DIST_MAX := 55.0

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)
	else:
		print("  ok: %s" % what)

func approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001

func _init() -> void:
	print("[worldui_plate_test] running")

	# --- plate_dist_scale ---------------------------------------------------------------------------
	var s_ref := WorldUIS.plate_dist_scale(WorldUIS.PLATE_SCALE_REF)
	ok(approx(s_ref, 1.0), "scale == 1.0 at the reference distance (got %.4f)" % s_ref)

	var s_near := WorldUIS.plate_dist_scale(DIST_MIN)
	var s_far := WorldUIS.plate_dist_scale(DIST_MAX)
	ok(s_near < 1.0, "closest zoom shrinks the plate below 1.0 (got %.4f)" % s_near)
	ok(s_far > 1.0, "farthest zoom grows the plate above 1.0 (got %.4f)" % s_far)

	# clamp band — nothing ever escapes [MIN, MAX], even far past the supported extremes
	for d in [0.0, 0.001, 1.0, DIST_MIN, WorldUIS.PLATE_SCALE_REF, DIST_MAX, 500.0, 100000.0]:
		var sc := WorldUIS.plate_dist_scale(float(d))
		ok(sc >= WorldUIS.PLATE_SCALE_MIN - 0.0001 and sc <= WorldUIS.PLATE_SCALE_MAX + 0.0001,
			"scale stays in [%.2f,%.2f] at dist %.3f (got %.4f)" % [WorldUIS.PLATE_SCALE_MIN, WorldUIS.PLATE_SCALE_MAX, float(d), sc])

	# within the real zoom band the plate never pins to a constant screen size (both extremes off 1.0)
	ok(not approx(s_near, s_far), "scale actually varies across the zoom band (near %.4f far %.4f)" % [s_near, s_far])
	ok(s_near > WorldUIS.PLATE_SCALE_MIN - 0.0001, "near-extreme not below the floor")

	# monotone non-decreasing in distance (farther never shrinks the plate) + degenerate input safe
	var prev := WorldUIS.plate_dist_scale(0.0)
	var d2 := 0.5
	while d2 <= 80.0:
		var cur := WorldUIS.plate_dist_scale(d2)
		ok(cur >= prev - 0.0001, "monotone non-decreasing at dist %.1f (%.4f >= %.4f)" % [d2, cur, prev])
		prev = cur
		d2 += 2.0
	ok(WorldUIS.plate_dist_scale(-5.0) >= WorldUIS.PLATE_SCALE_MIN - 0.0001, "negative/zero distance is safe (no NaN/crash)")

	# --- clamp_name (bounded long-name policy) ------------------------------------------------------
	var cap := WorldUIS.PLATE_NAME_MAX_CHARS
	ok(WorldUIS.clamp_name("") == "", "empty name unchanged")
	ok(WorldUIS.clamp_name("Ramirez") == "Ramirez", "short name unchanged")
	var atcap := "A".repeat(cap)
	ok(WorldUIS.clamp_name(atcap) == atcap, "name exactly at the cap is not truncated")
	var over := "A".repeat(cap + 20)
	var clamped := WorldUIS.clamp_name(over)
	ok(clamped.length() <= cap, "over-long name clamped to <= cap (%d <= %d)" % [clamped.length(), cap])
	ok(clamped.ends_with("…"), "truncated name gets an ellipsis")
	ok(not atcap.ends_with("…"), "a non-truncated name gets NO ellipsis")

	# --- wobble_lit ---------------------------------------------------------------------------------
	ok(WorldUIS.wobble_lit(0.0) == 0, "no wobble → 0 pips")
	ok(WorldUIS.wobble_lit(0.1) == 1, "a sliver of wobble → 1 pip (ceil)")
	ok(WorldUIS.wobble_lit(2.4) == 3, "2.4 wobble → 3 pips (ceil)")
	ok(WorldUIS.wobble_lit(float(WorldUIS.PLATE_WOBBLE_PIPS)) == WorldUIS.PLATE_WOBBLE_PIPS, "max wobble → all pips")
	ok(WorldUIS.wobble_lit(99.0) == WorldUIS.PLATE_WOBBLE_PIPS, "over-max wobble clamps to the pip count")

	print("[worldui_plate_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
