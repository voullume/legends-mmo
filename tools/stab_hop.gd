extends "res://tools/stab/stab_base.gd"
## Stabilization — Phase 0.5 networked cosmetic hop (server authority + snapshot echo, headless, no net):
##   • submit_hop timestamps a LIVE fighter and is echoed as an additive snapshot `hopT` (interest-managed);
##   • it is PURELY cosmetic — it never moves the fighter or adds any field to the sim fighter dict;
##   • rate-limited (anti-spam) — a re-press faster than the rate window is dropped;
##   • REGRESSION: a continuous-hopper re-hop at the ~450ms client cadence IS networked (an earlier restart
##     window ≥ HOP_DUR silently dropped every other jump — the rate limit sits safely below the cadence);
##   • hopT expires from the snapshot after the echo window, then a fresh hop may arm;
##   • a DEAD fighter never hops and never echoes hopT (so a mid-hop death can't float a corpse remotely);
##   • pre-auth submit_hop is rejected; disconnect clears ALL hop state (per-pid + per-fighter).
## Run: godot --headless --path . --script res://tools/stab_hop.gd

const ECHO := 500     # mirror Server.HOP_ECHO_MS (snapshot hopT lifetime)
const RATE := 250     # mirror Server.HOP_RATE_MS (anti-spam floor; also the cadence gate)
const CADENCE := 470  # a continuous hopper's real re-hop interval: > client HOP_DUR 450ms (and < the old 500ms window)

func _init() -> void:
	_run()

# the hopT the snapshot carries for `fid` (centered so `fid` is inside interest range); null = not present
func _hopT_for(center: Vector2, fid: String):
	var snap: Dictionary = srv._snapshot_for(srv._worlds[World.HOME], World.HOME, center, {})
	for f in snap["fighters"]:
		if str(f["id"]) == fid:
			return f.get("hopT", null)
	return "MISSING"

func _run() -> void:
	await boot()
	var a: Dictionary = await login("Alice", 1)
	var af = srv._find(a["fid"])
	ok(af != null and bool(af.get("alive", false)), "setup: Alice spawned alive")
	var center := Vector2(af["x"], af["y"])
	var ax0 := float(af["x"]); var ay0 := float(af["y"]); var nkeys: int = af.keys().size()

	# ---- 1. a live fighter's hop is timestamped + echoed as hopT ----
	ok(not srv._hop_t0.has(a["fid"]), "hop: no hop state before any jump")
	srv.submit_hop(1)
	ok(srv._hop_t0.has(a["fid"]), "hop: submit_hop timestamps the fighter")
	var h = _hopT_for(center, a["fid"])
	ok(typeof(h) == TYPE_FLOAT and h >= 0.0 and h < ECHO / 1000.0,
		"hop: snapshot carries hopT within the window just after takeoff (got %s)" % str(h))

	# ---- 2. purely cosmetic: submit_hop never touches the sim fighter dict ----
	ok(is_equal_approx(float(af["x"]), ax0) and is_equal_approx(float(af["y"]), ay0),
		"hop: fighter position unchanged (the hop is not in the sim)")
	ok(af.keys().size() == nkeys and not af.has("hopT") and not af.has("z"),
		"hop: no hopT/z leaks onto the sim fighter dict")

	# ---- 3. anti-spam: a re-press faster than the rate window is dropped ----
	var t0 := int(srv._hop_t0[a["fid"]])
	srv.submit_hop(1)                                       # immediate re-press → inside the rate window
	ok(int(srv._hop_t0[a["fid"]]) == t0, "hop: an immediate re-press does not re-arm (rate limit)")
	await wait_ms(120)                                      # still < RATE (250ms)
	srv.submit_hop(1)
	ok(int(srv._hop_t0[a["fid"]]) == t0, "hop: a re-press faster than the rate limit is dropped")

	# ---- 4. REGRESSION: a re-hop at the continuous-hopper cadence IS accepted (was dropped when the restart
	#         window (≥ HOP_DUR) exceeded the ~450ms re-hop cadence → every other jump vanished from the network) ----
	await wait_ms(CADENCE - 120)                            # total ≈ CADENCE(470)ms since hop #1: > HOP_DUR, < old 500 window
	srv.submit_hop(1)
	ok(int(srv._hop_t0[a["fid"]]) > t0, "hop: a re-hop at the ~450ms cadence is accepted (regression: no every-other-hop drop)")
	var h2 = _hopT_for(center, a["fid"])
	ok(typeof(h2) == TYPE_FLOAT and h2 >= 0.0 and h2 < 0.1, "hop: the accepted re-hop restarts the arc from takeoff (fresh hopT≈0)")
	var t_rehop := int(srv._hop_t0[a["fid"]])

	# ---- 5. echo window expiry → hopT drops out, then a fresh hop may arm ----
	await wait_ms(ECHO + 80)
	ok(_hopT_for(center, a["fid"]) == null, "hop: hopT expires from the snapshot after the echo window")
	srv.submit_hop(1)
	ok(int(srv._hop_t0[a["fid"]]) > t_rehop, "hop: a fresh hop arms again once the window has elapsed")

	# ---- 6. a dead fighter never echoes hopT and never starts a hop ----
	af["alive"] = false
	ok(_hopT_for(center, a["fid"]) == null, "hop: a fighter that died mid-hop has its hopT suppressed (no floating corpse)")
	await wait_ms(RATE + ECHO + 80)                        # clear both the rate limit and the echo window
	var dead_t := int(srv._hop_t0.get(a["fid"], -1))
	srv.submit_hop(1)
	ok(int(srv._hop_t0.get(a["fid"], -1)) == dead_t, "hop: a dead fighter cannot start a new hop")
	af["alive"] = true

	# ---- 6. pre-auth submit_hop is rejected (no session) ----
	srv.connect_peer(8)                                    # transport-connected, never authenticated
	srv.submit_hop(8)
	ok(not srv._hop_next.has(8), "hop: pre-auth submit_hop rejected before any session")

	# ---- 7. disconnect clears all hop state (per-pid + per-fighter) ----
	var afid: String = a["fid"]
	ok(srv._hop_next.has(1) and srv._hop_t0.has(afid), "hop: Alice has live hop state before leaving")
	srv.drop_peer(1)
	await settle()
	ok(not srv._hop_next.has(1), "hop: disconnect clears _hop_next[pid]")
	ok(not srv._hop_t0.has(afid), "hop: disconnect clears _hop_t0[fid]")
	ok(pid_state_leaks(1).is_empty(), "hop: no per-pid state leaks after disconnect (full cleanup contract)")

	finish("stab_hop")
