extends SceneTree
## RP4 automated-playtest reports (server-side; no net/supa). Proves the anomaly detectors: live-mob presence,
## the per-(resident,kind) report cooldown, no-combat-progress emission (stall accrues in a mob-full aggro zone
## and reports at the threshold), progress (dmgDealt change) resetting the stall, and repeated-death tallying.
## _emit_report no-ops its DB write when supa==null, so we observe emission via its state side effects.
const ServerScript = preload("res://server/Server.gd")
const World = preload("res://shared/World.gd")

var pass_n := 0
var fail_n := 0
func ok(cond: bool, label: String) -> void:
	if cond: pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func _res_fid(srv, res_id: String) -> String:
	for fid in srv._residents:
		if str((srv._residents[fid] as Dictionary).get("id", "")) == res_id:
			return str(fid)
	return ""

func _init() -> void:
	var srv = ServerScript.new()
	for mapname in World.MAPS:
		if World.is_instance_template(mapname):
			continue
		srv._worlds[mapname] = srv._new_world(mapname)
	srv._spawn_world_actors()
	srv._spawn_residents()

	# --- live-mob presence: a combat zone has mobs; home (training dummy only) does not ---
	ok(srv._zone_has_live_mobs(srv._worlds["glitchyard_2"]) == true, "a combat zone reports live mobs present")
	ok(srv._zone_has_live_mobs(srv._worlds["home"]) == false, "home (dummy only) reports no combat mobs")

	# --- report cooldown: first call passes, a second within the window is blocked ---
	ok(srv._report_ok("xtest", "k") == true, "first _report_ok passes")
	ok(srv._report_ok("xtest", "k") == false, "a second _report_ok within the cooldown is blocked")

	# --- no_progress: a resident in a mob-full aggro zone dealing no damage reports at the stall threshold ---
	var sarge := _res_fid(srv, "sarge")                    # homes in glitchyard_2 (aggro + mobs)
	ok(str((srv._find(sarge) as Dictionary)["map"]) == "glitchyard_2", "sarge is in a combat zone")
	srv._find(sarge)["dmgDealt"] = 0.0
	srv._find(sarge)["noDmgT"] = 999.0                     # not recently hit → genuinely disengaged (stuck)
	srv._res_prog[sarge] = {"last_dmg": 0.0, "stall_t": ServerScript.REPORT_STALL_S - 2.0, "zone": "glitchyard_2"}   # one tick from the threshold
	srv._rep_t = 0.0
	srv._tick_reports(2.0)                                 # >= REPORT_TICK_S → scans; stall crosses the threshold
	ok((srv._res_report_next.get(sarge, {}) as Dictionary).has("no_progress"), "no-progress anomaly reported at the stall threshold")
	ok(float((srv._res_prog[sarge] as Dictionary)["stall_t"]) == 0.0, "stall resets after reporting")

	# --- progress resets the stall: dealing damage (dmgDealt changes) clears the stall, no report ---
	var mercy := _res_fid(srv, "mercy")                    # homes in glitchyard_1 (aggro + mobs)
	srv._res_prog[mercy] = {"last_dmg": 0.0, "stall_t": ServerScript.REPORT_STALL_S - 2.0, "zone": "glitchyard_1"}
	srv._find(mercy)["dmgDealt"] = 120.0                   # dealt damage since the last scan
	srv._rep_t = 0.0
	srv._tick_reports(2.0)
	ok(float((srv._res_prog[mercy] as Dictionary)["stall_t"]) == 0.0, "combat progress resets the stall")
	ok(not (srv._res_report_next.get(mercy, {}) as Dictionary).has("no_progress"), "a progressing resident is not reported")

	# --- a resident TAKING damage (tanking/being kited) is engaged, not "stuck" — no report despite 0 dmg dealt ---
	var reaper := _res_fid(srv, "reaper")                  # homes in glitchyard_3 (aggro + mobs)
	srv._res_prog[reaper] = {"last_dmg": 0.0, "stall_t": ServerScript.REPORT_STALL_S - 2.0, "zone": "glitchyard_3"}
	srv._find(reaper)["dmgDealt"] = 0.0
	srv._find(reaper)["noDmgT"] = 0.5                      # just got hit → in a fight
	srv._rep_t = 0.0
	srv._tick_reports(2.0)
	ok(float((srv._res_prog[reaper] as Dictionary)["stall_t"]) == 0.0, "a resident taking damage counts as engaged (not stuck)")

	# --- per-zone stall clock: relocating resets it, so a report always names the zone it accrued in (review fix) ---
	var nomad := _res_fid(srv, "nomad")
	var nz := str((srv._find(nomad) as Dictionary)["map"])
	srv._res_prog[nomad] = {"last_dmg": 0.0, "stall_t": ServerScript.REPORT_STALL_S - 2.0, "zone": nz}
	srv._find(nomad)["dmgDealt"] = 0.0
	srv._find(nomad)["noDmgT"] = 999.0
	var other := "glitchyard_5" if nz != "glitchyard_5" else "glitchyard_4"
	srv._relocate(srv._find(nomad), null, other, World.spawn_for(other))   # move to a fresh combat zone
	srv._rep_t = 0.0
	srv._tick_reports(2.0)
	ok(float((srv._res_prog[nomad] as Dictionary)["stall_t"]) <= 2.0 and not (srv._res_report_next.get(nomad, {}) as Dictionary).has("no_progress"),
		"the stall clock resets on a zone change (no cross-zone misattributed report)")

	# --- repeated_death: N deaths in one zone reports and resets that zone's counter ---
	var blitz := _res_fid(srv, "blitz")
	var bf: Dictionary = srv._find(blitz)
	var bzone := str(bf["map"])
	srv._on_resident_death(bf)
	srv._on_resident_death(bf)
	ok(int((srv._res_deaths[blitz] as Dictionary).get(bzone, 0)) == 2, "two deaths tallied, no report yet")
	srv._on_resident_death(bf)                             # crosses REPORT_DEATH_THRESHOLD (3)
	ok(int((srv._res_deaths[blitz] as Dictionary).get(bzone, 0)) == 0, "the threshold death reports + resets that zone's counter")

	print("=== residents reports (RP4): %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
