extends SceneTree
## RP3 flavor test: residents speak persona lines on contextual triggers (server-side; no net). Proves the
## data is complete per persona, the rude persona differs from the polite ones, and _resident_say honors
## zone-scoping (only a player in-zone hears it), the cooldown gate, force-bypass, and alive/listener guards.
## Purely presentational — reads only fighter dict + server tables, never sim/RNG, so determinism is untouched.
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

	# --- persona coverage: every resident's persona has a full line set (no empty-pool fallbacks live) ---
	var coverage_ok := true
	for fid in srv._residents:
		var persona := str((srv._find(fid) as Dictionary).get("resPersona", ""))
		var pd: Dictionary = ServerScript.RESIDENT_LINES.get(persona, {})
		for ctx in ["join", "kill", "ambient", "dismiss"]:
			if (pd.get(ctx, []) as Array).is_empty():
				coverage_ok = false
	ok(coverage_ok, "every resident persona has join/kill/ambient/dismiss lines")

	# --- the rude persona is antagonistic: its lines differ from a polite persona's ---
	ok(ServerScript.RESIDENT_LINES["rude"]["kill"] != ServerScript.RESIDENT_LINES["support"]["kill"],
		"the rude persona's lines differ from the polite ones")
	ok(str((srv._find(_res_fid(srv, "vulture")) as Dictionary).get("resPersona", "")) == "rude", "Vulture uses the rude persona")

	var sarge := _res_fid(srv, "sarge")
	var smap := str((srv._find(sarge) as Dictionary)["map"])
	var pfid = srv._spawn_fighter("striker", 0, Vector2(300, 300), smap)   # a player standing in sarge's zone
	srv._session[77] = {"fid": str(pfid), "name": "P", "map": smap, "party": []}
	srv._peers.append(77)                                 # register as a connected peer (the listener scan reads _peers)

	# --- speaks when a player is in the zone + the cooldown is clear ---
	srv._res_chat_next[sarge] = 0
	var i0: int = srv._res_chat_i
	srv._resident_say(sarge, "ambient")
	var now := Time.get_ticks_msec()
	ok(srv._res_chat_i == i0 + 1 and int(srv._res_chat_next.get(sarge, 0)) > now, "speaks to a player in its zone (+ sets cooldown)")

	# --- the cooldown suppresses the next line ---
	var i1: int = srv._res_chat_i
	srv._resident_say(sarge, "ambient")
	ok(srv._res_chat_i == i1, "cooldown suppresses a second line")

	# --- force bypasses the cooldown (the recruit greeting) ---
	srv._resident_say(sarge, "join", true)
	ok(srv._res_chat_i == i1 + 1, "force speaks through the cooldown")

	# --- silent when no player is in the zone ---
	srv._relocate(srv._find(str(pfid)), srv._session[77], "glitchyard_5", World.spawn_for("glitchyard_5"))
	srv._res_chat_next[sarge] = 0
	var i2: int = srv._res_chat_i
	srv._resident_say(sarge, "ambient")
	ok(srv._res_chat_i == i2 and int(srv._res_chat_next.get(sarge, 0)) == 0, "stays silent with no one in its zone")

	# --- a dead resident says nothing (bring the player back first) ---
	srv._relocate(srv._find(str(pfid)), srv._session[77], smap, World.spawn_for(smap))
	srv._find(sarge)["alive"] = false
	srv._res_chat_next[sarge] = 0
	var i3: int = srv._res_chat_i
	srv._resident_say(sarge, "ambient")
	ok(srv._res_chat_i == i3, "a dead resident stays silent")

	print("=== residents chat (RP3): %d passed, %d failed ===" % [pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
