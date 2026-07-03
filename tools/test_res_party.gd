extends SceneTree
## RP2 party test: recruiting an AI resident into your party (server-side; no net/supa). Proves the fid↔pid
## bridge — a resident bonds to its recruiter, snaps to + follows the leader BETWEEN zones, shows in the party
## roster with live HP, can't be stolen, respects the party cap, won't follow into the PvP arena, and is
## released on Leave / disconnect. Determinism is untouched (all glue is server-side; no shared/ change).
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

func _fake_player(srv, pid: int, mapname: String) -> String:
	var pfid = srv._spawn_fighter("striker", 0, Vector2(300, 300), mapname)   # a connected human, minus the net
	srv._session[pid] = {"fid": str(pfid), "name": "P%d" % pid, "map": mapname, "party": [], "char_id": "c%d" % pid}
	return str(pfid)

func _map_of(srv, fid: String) -> String:
	var f: Dictionary = srv._find(fid)
	return str(f["map"])

func _init() -> void:
	var srv = ServerScript.new()
	for mapname in World.MAPS:
		if World.is_instance_template(mapname):
			continue
		srv._worlds[mapname] = srv._new_world(mapname)
	srv._spawn_world_actors()
	srv._spawn_residents()

	var sarge := _res_fid(srv, "sarge")
	ok(sarge != "", "found sarge")

	# --- recruit: an invite whose target fid is a resident routes to a server-side auto-join ---
	var PID := 77
	var pfid := _fake_player(srv, PID, "glitchyard_1")
	srv.party_invite(PID, sarge)
	ok(srv._res_party.has(sarge) and int(srv._res_party[sarge]) == PID, "recruiting bonds the resident to the leader")

	# --- immediate follow: the companion snaps to the leader's zone the moment it's recruited ---
	ok(_map_of(srv, sarge) == "glitchyard_1", "companion follows the leader's zone on recruit")

	# --- roster: the companion shows in the party HUD roster alongside you, with the keys the client renders ---
	var roster := srv._party_roster(PID)
	var in_roster := false
	var has_self := false
	var keys_ok := true
	for e in roster:
		var d: Dictionary = e
		if str(d["fid"]) == sarge: in_roster = true
		if str(d["fid"]) == pfid: has_self = true
		for k in ["fid", "name", "hp", "maxHP", "alive"]:
			if not d.has(k): keys_ok = false
	ok(in_roster and has_self, "party roster shows you + the companion (HUD frames)")
	ok(keys_ok, "roster entries carry every key the client hard-indexes")

	# --- can't steal: a bonded companion rejects another player's invite ---
	var PID2 := 88
	_fake_player(srv, PID2, "glitchyard_1")
	srv._party_invite_next.erase(PID2)
	srv.party_invite(PID2, sarge)
	ok(int(srv._res_party[sarge]) == PID, "a bonded companion can't be stolen by another player")

	# --- cross-zone follow: move the leader; the companion follows on the next tick ---
	srv._relocate(srv._find(pfid), srv._session[PID], "glitchyard_3", World.spawn_for("glitchyard_3"))
	srv._tick_residents(0.1)
	ok(_map_of(srv, sarge) == "glitchyard_3", "companion follows the leader across zones")

	# --- gate: never follow the leader into the PvP arena ---
	srv._relocate(srv._find(pfid), srv._session[PID], "arena", World.spawn_for("arena"))
	srv._tick_residents(0.1)
	ok(_map_of(srv, sarge) != "arena", "companion won't follow the leader into the PvP arena")

	# --- release: the Leave Party button dismisses your companion ---
	srv.party_leave(PID)
	ok(not srv._res_party.has(sarge), "Leave Party releases the companion")

	# --- release: a disconnect drops the bond (via the helper _on_peer_disconnected calls) ---
	srv._relocate(srv._find(pfid), srv._session[PID], "glitchyard_1", World.spawn_for("glitchyard_1"))
	srv._party_invite_next.erase(PID)
	srv.party_invite(PID, sarge)
	ok(srv._res_party.has(sarge), "re-recruited after leaving")
	srv._release_residents_of(PID)
	ok(not srv._res_party.has(sarge), "disconnect release drops the bond")

	# --- cap: a solo player can recruit up to MAX_PARTY-1 companions (1 human + N = MAX_PARTY) ---
	for rf in srv._res_party.keys():
		srv._release_resident(rf)
	for fid in srv._residents:
		srv._party_invite_next.erase(PID)
		srv.party_invite(PID, str(fid))
	var bonded := 0
	for fid in srv._residents:
		if srv._res_party.has(fid) and int(srv._res_party[fid]) == PID:
			bonded += 1
	ok(bonded == ServerScript.MAX_PARTY - 1, "party cap holds: %d companions bonded (MAX_PARTY %d)" % [bonded, ServerScript.MAX_PARTY])

	# --- cap across a human merge: A (full companion roster) + a human would exceed MAX_PARTY → blocked ---
	var PID3 := 99
	_fake_player(srv, PID3, "glitchyard_1")
	srv._party_invite_next.erase(PID)
	srv.party_invite(PID, str(srv._session[PID3]["fid"]))          # A invites a human while holding MAX_PARTY-1 companions
	ok(not srv._party_invites.has(PID3), "invite-side cap blocks inviting a human when your companions fill the party")
	srv._party_invites[PID3] = {"from": PID, "t": Time.get_ticks_msec()}   # force the handshake to test the authoritative gate
	srv.party_accept(PID3, str(srv._session[PID]["fid"]))
	ok((srv._session[PID3]["party"] as Array).is_empty() and (srv._session[PID]["party"] as Array).is_empty(),
		"party_accept's authoritative cap rejects the over-cap humans+companions merge")

	print("=== residents party (RP2): %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
