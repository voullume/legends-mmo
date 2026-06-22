extends Node
## SHARED ZONE SERVER (Phase 4 + 5). Persistent, server-authoritative overworld for several accounts.
## TWO worlds run side by side (see shared/World.gd):
##   home   — a safe base: roam freely + a passive training dummy that instantly respawns.
##   combat — aggressive mobs, XP, and loot. A portal pad in each world teleports you to the other.
## Each world is an independent sim in the same 960×540 arena space; players only see/affect their own.
##
## - Players are team 0 (they coexist — abilities target enemies, so they don't hit each other).
## - Mobs are team 1 with aggro/leash; killing one grants XP + a loot roll. Progression persists.
## - Per-client snapshots are interest-managed (only entities near the client's fighter, in its world).
##
## SECURITY NOTE: pass --dtls (server AND clients) to encrypt the ENet transport; without it it's
## plaintext. Only the short-lived access token crosses the wire (the refresh token stays on the
## client). DTLS encrypts but doesn't verify server identity — prefer a VPN or a host you control.
## Inventory is server-authoritative: the server writes the inventory table with the service_role key
## (SUPABASE_SERVICE_KEY env var) — clients are denied direct writes, so items can't be forged.

const Sim := preload("res://shared/Sim.gd")
const GameData := preload("res://shared/GameData.gd")
const Geom := preload("res://shared/Geom.gd")
const Rng := preload("res://shared/Rng.gd")
const World := preload("res://shared/World.gd")

const PORT := 7777
const MAP_ID := "stadium"
const SEED := 20260621
const SIM_DT := 1.0 / 30.0
const ZONE_TEAM_SIZE := 5
const RESPAWN_DELAY := 4.0
const SAVE_INTERVAL := 15.0
const INTEREST_RADIUS := 450.0
const STALE_INTENT_TICKS := 30
const AGGRO_RANGE := 320.0            # a mob engages a player within this range (covers ranged basics)
const LEASH_RANGE := 1600.0           # once engaged, stays engaged until players pass this (hysteresis)
const MAX_LEASH := 1600.0             # a mob chases up to this far from its camp before it resets (big combat arena)
const MOB_HP_SCALE := 0.35            # base mob HP fraction (scaled up by level + tier)
const MOB_DMG_SCALE := 0.28           # base mob damage fraction (scaled up by level + tier)
const MOB_XP_BASE := 15               # mob XP = base × level × (elite ? 4 : 1)
const MOB_ELITE_HP := 2.2
const MOB_ELITE_DMG := 1.6
const MOB_ELITE_XP := 4
const LEVEL_HP := 60.0                # bonus max HP per player level
const DUMMY_HP := 500.0               # the training dummy's fixed HP (no mob scaling)
const TP_GRACE_MS := 1500             # after a teleport/spawn, brief immunity to re-triggering a pad

# --- loot ---
const LOOT_SLOTS := {
	"weapon": ["Bat", "Cleats", "Gauntlets", "Glove", "Racket"],
	"armor": ["Jersey", "Shoulder Pads", "Helmet", "Shin Guards"],
	"trinket": ["Medal", "Lucky Charm", "Whistle", "Captain's Band"],
}
const RARITIES := [
	{"name": "common", "weight": 60, "mult": 1},
	{"name": "uncommon", "weight": 28, "mult": 2},
	{"name": "rare", "weight": 10, "mult": 4},
	{"name": "epic", "weight": 2, "mult": 8},
]
const LOOT_STATS := ["PWR", "PRE", "SPD", "END", "INS", "CLU"]
const RARITY_CAP := {"common": 4, "uncommon": 10, "rare": 20, "epic": 40}   # caps an equipped bonus (anti-forge)

var net: Node = null
var supa: Node = null
var _loot_rng = null

var _worlds: Dictionary = {}        # map name → independent sim state
var _peers: Array = []
var _authing := {}
var _session := {}                  # peer id → {fid, access, char_id, name, xp, level, map}
var _move := {}
var _pending_ability := {}
var _last_aseq := {}
var _intent_age := {}
var _spawn_pos := {}
var _respawn := {}
var _mob_engaged := {}              # mob id → currently engaged (for leash hysteresis + heal-once)
var _tp_next := {}                 # fighter id → earliest ms it may use a portal (grace after teleport/spawn)
var _chat_next := {}               # peer id → earliest ms it may chat again (rate limit)
var _equipping := {}               # peer ids with an equip() toggle in flight (race guard)
var _equip_next := {}              # peer id → earliest ms it may equip again (rate limit)
var _fseq := 0
var _acc := 0.0
var _save_t := 0.0
var _snap_count := 0

static func _xp_to_next(level: int) -> int:
	return level * 100

func start(port := PORT, use_dtls := false, bind_ip := "") -> bool:
	var peer := ENetMultiplayerPeer.new()
	if bind_ip != "":                            # some UDP hosts (e.g. Fly) need a specific bind addr
		peer.set_bind_ip(bind_ip)
	var err := peer.create_server(port)
	if err != OK:
		push_error("[zone] create_server(%d) failed: %d" % [port, err])
		return false
	if use_dtls:                                 # encrypt the transport with a fresh self-signed cert
		var crypto := Crypto.new()
		var key := crypto.generate_rsa(2048)
		var cert := crypto.generate_self_signed_certificate(key, "CN=legends-zone,O=Legends,C=US")
		var derr := peer.host.dtls_server_setup(TLSOptions.server(key, cert))
		if derr != OK:
			push_error("[zone] DTLS setup failed: %d" % derr)
			return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	# vary loot per launch with process-unique, high-res entropy (no same-second seed collisions)
	_loot_rng = Rng.new(int(Time.get_unix_time_from_system()) ^ Time.get_ticks_usec() ^ (OS.get_process_id() << 13))
	Engine.max_fps = 60
	_worlds[World.HOME] = _new_world(World.HOME)
	_worlds[World.COMBAT] = _new_world(World.COMBAT)
	# home: a single passive training dummy
	var did := _spawn_fighter(World.DUMMY_CLASS, 1, World.DUMMY_POS, World.HOME)
	var dummy = _find(did)
	if dummy != null:
		dummy["dummy"] = true
		dummy["maxHP"] = DUMMY_HP
		dummy["hp"] = DUMMY_HP
	# combat: the mob gradient
	for m in World.MOBS:
		var fid := _spawn_fighter(str(m["class"]), 1, Vector2(float(m["x"]), float(m["y"])), World.COMBAT)
		var f = _find(fid)
		f["mobLevel"] = int(m["level"])
		f["mobTier"] = str(m["tier"])
		_scale_mob(f)
	print("[zone] online on UDP %d  (home + combat worlds, %d mobs%s)" % [port, World.MOBS.size(), "  · DTLS" if use_dtls else ""])
	_check_service_key()                         # verify loot/equip will be able to save
	return true

# On boot, confirm the service_role key can actually write our inventory table (loot/equip).
# Logs a clear ✓/✗ in `docker logs` so a wrong/stale key is obvious instead of silent 0-loot.
func _check_service_key() -> void:
	if supa == null or supa.service_key == "":
		print("[zone] ✗ SUPABASE_SERVICE_KEY not set — loot/equip will NOT save.")
		return
	var r = await supa._http(HTTPClient.METHOD_GET, "/rest/v1/inventory?select=id&limit=1", "", PackedStringArray(), supa.service_key)
	if int(r.get("code", 0)) == 200:
		print("[zone] ✓ SUPABASE_SERVICE_KEY valid for this project — loot/equip will save.")
	else:
		print("[zone] ✗ SUPABASE_SERVICE_KEY INVALID (HTTP %s) — loot/equip will NOT save. Redeploy with the correct service_role key." % str(r.get("code")))

func _new_world(map: String) -> Dictionary:
	var w: Dictionary = Sim.create_match([], [], SEED, MAP_ID)
	w["zone"] = true                             # persistent: no match-end / no overtime ramp
	var c := World.cfg(map)                      # per-map size + regen + aggro
	w["arenaW"] = int(c["w"])
	w["arenaH"] = int(c["h"])
	w["regen"] = float(c["regen"])
	w["regenDelay"] = float(c["regen_delay"])
	w["aggro"] = bool(c["aggro"])
	return w

# ---- connection / auth ----
func _on_peer_connected(pid: int) -> void:
	print("[zone] peer %d connected — awaiting auth" % pid)

func _on_peer_disconnected(pid: int) -> void:
	_authing.erase(pid)
	if not _session.has(pid):
		return
	var s = _session[pid]                        # capture before erasing (the save coroutine holds it)
	_save_one(s, _find(s["fid"]))                # persist xp/level (+ position if alive), even on a corpse
	_party_leave(pid)                            # drop out of any party (and disband if it falls below 2)
	_remove_fighter(s["fid"])
	_peers.erase(pid)
	_session.erase(pid)
	_move.erase(pid)
	_pending_ability.erase(pid)
	_last_aseq.erase(pid)
	_intent_age.erase(pid)
	_chat_next.erase(pid)
	_equipping.erase(pid)
	_equip_next.erase(pid)
	_party_invite_next.erase(pid)
	print("[zone] peer %d left" % pid)

func authenticate(pid: int, access: String, _refresh: String = "") -> void:
	if pid in _peers or _authing.has(pid) or supa == null:
		return
	_authing[pid] = true
	var res = await supa.get_character_as(access)
	_authing.erase(pid)
	if not (pid in multiplayer.get_peers()) or pid in _peers:
		return
	if not res.get("ok") or res.get("character") == null:
		print("[zone] peer %d auth failed (%s) — kicking" % [pid, res.get("error", "no character")])
		multiplayer.multiplayer_peer.disconnect_peer(pid)
		return
	var ch = res["character"]
	var lvl := int(ch.get("level", 1))
	var fid := _spawn_player(ch, lvl)
	var pf = _find(fid)
	_peers.append(pid)
	_session[pid] = {"fid": fid, "access": access, "char_id": str(ch["id"]),
		"name": str(ch.get("name", "?")), "xp": int(ch.get("xp", 0)), "level": lvl,
		"map": str(pf["map"]) if pf != null else World.HOME, "party": []}
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	net.assign_fighter.rpc_id(pid, fid)
	await _apply_equipment(pid)                       # re-derive stats from saved equipment
	if _session.has(pid):                             # admin powers, gated on the service-role admins table
		var is_admin: bool = await supa.is_admin_as(str(ch.get("user_id", "")))
		_session[pid]["admin"] = is_admin
		if is_admin and net != null:
			net.recv_admin.rpc_id(pid, true)
			print("[zone] %s authenticated as ADMIN" % ch.get("name", "?"))
	print("[zone] %s (%s, lvl %d) joined as %s in '%s' — now %d player(s)" % [ch.get("name", "?"), ch.get("class", "?"), lvl, fid, _session[pid]["map"], _peers.size()])

func reauth(pid: int, access: String) -> void:
	if _session.has(pid) and access != "":
		_session[pid]["access"] = access

# zone-wide chat relay (sanitized; named by the sender's character)
func chat(pid: int, text: String) -> void:
	if not _session.has(pid):
		return
	var now := Time.get_ticks_msec()             # rate limit ~1.4 msgs/sec/player (anti-flood)
	if now < int(_chat_next.get(pid, 0)):
		return
	_chat_next[pid] = now + 700
	var msg := text.strip_edges().replace("\n", " ").replace("\r", " ")
	if msg.is_empty():
		return
	if msg.length() > 120:
		msg = msg.substr(0, 120)
	var who: String = str(_session[pid]["name"])
	print("[chat] %s: %s" % [who, msg])
	for p in _peers:
		net.recv_chat.rpc_id(p, who, msg)

func _spawn_player(ch, level: int) -> String:
	var cls: String = str(ch.get("class", "striker"))
	if not GameData.CLASSES.has(cls):
		cls = "striker"
	var map: String = str(ch.get("last_map", World.HOME))
	if not _worlds.has(map):
		map = World.HOME
	var pos: Vector2 = World.HOME_SPAWN           # home is a hub: always spawn at the safe pad-free point
	if map == World.COMBAT:                        # in combat, resume where you logged out
		pos = Vector2(float(ch.get("last_x", World.COMBAT_SPAWN.x)), float(ch.get("last_y", World.COMBAT_SPAWN.y)))
	var fid := _spawn_fighter(cls, 0, pos, map)
	var f = _find(fid)
	if f != null:
		f["maxHP"] += (level - 1) * LEVEL_HP       # progression: bonus HP per level
		f["hp"] = f["maxHP"]
		_tp_next[fid] = Time.get_ticks_msec() + TP_GRACE_MS   # don't instantly portal on spawn near a pad
	return fid

func _spawn_fighter(cls: String, team: int, pos: Vector2, map: String) -> String:
	var w = _worlds[map]
	var slot := 0
	for f in w["fighters"]:
		if f["team"] == team:
			slot += 1
	_fseq += 1
	var f := GameData.create_fighter(cls, team, slot, Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	f["id"] = ("p" if team == 0 else "m") + str(_fseq)
	f["x"] = pos.x
	f["y"] = pos.y
	f["map"] = map
	f["arenaW"] = int(w.get("arenaW", GameData.ARENA_W))   # carry the world's bounds (per-map clamp)
	f["arenaH"] = int(w.get("arenaH", GameData.ARENA_H))
	Geom.clamp_arena(f)
	w["fighters"].append(f)
	_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])
	return f["id"]

func _remove_fighter(fid: String) -> void:
	for mapname in _worlds:
		var w = _worlds[mapname]
		var keep := []
		for f in w["fighters"]:
			if f["id"] != fid:
				keep.append(f)
		w["fighters"] = keep
	_spawn_pos.erase(fid)
	_respawn.erase(fid)
	_tp_next.erase(fid)

func _session_by_fid(fid: String) -> Variant:
	for pid in _session:
		if _session[pid]["fid"] == fid:
			return _session[pid]
	return null

# ---- parties (social group + heal/buff targeting; XP stays solo) ----
const MAX_PARTY := 5
const INVITE_COOLDOWN_MS := 1000                  # per-sender anti-spam (mirrors chat)
const INVITE_TTL_MS := 30000                      # a pending invite expires (and stops blocking) after 30s
var _party_invites := {}                          # target_pid -> {from: inviter_pid, t: ms}
var _party_invite_next := {}                      # inviter_pid -> earliest next-invite ms

func _pid_by_fid(fid: String) -> int:
	for pid in _session:
		if str(_session[pid]["fid"]) == fid:
			return pid
	return -1

# invite the clicked player (by fighter id); they get a prompt
func party_invite(pid: int, target_fid: String) -> void:
	if not _session.has(pid):
		return
	var now := Time.get_ticks_msec()
	if now < int(_party_invite_next.get(pid, 0)):    # rate-limit per sender (anti-spam/DoS)
		return
	var tpid := _pid_by_fid(target_fid)
	if tpid < 0 or tpid == pid:
		return
	var party: Array = _session[pid]["party"]
	if tpid in party or max(party.size(), 1) >= MAX_PARTY:
		return
	var pend = _party_invites.get(tpid)              # don't stomp a still-fresh invite from someone else
	if pend != null and int(pend.get("from", -1)) != pid and now - int(pend.get("t", 0)) < INVITE_TTL_MS:
		return
	_party_invite_next[pid] = now + INVITE_COOLDOWN_MS
	_party_invites[tpid] = {"from": pid, "t": now}
	if net != null:
		net.recv_party_invite.rpc_id(tpid, str(_session[pid]["name"]), str(_session[pid]["fid"]))

# accept the pending invite (validated against _party_invites so it can't be forged)
func party_accept(pid: int, inviter_fid: String) -> void:
	if not _session.has(pid) or not _party_invites.has(pid):
		return
	var inv = _party_invites[pid]
	_party_invites.erase(pid)
	if Time.get_ticks_msec() - int(inv.get("t", 0)) >= INVITE_TTL_MS:
		return                                       # expired
	var ipid: int = int(inv.get("from", -1))
	if not _session.has(ipid) or str(_session[ipid]["fid"]) != inviter_fid or ipid == pid:
		return
	_party_leave(pid)                             # drop any old party first
	var members: Array = (_session[ipid]["party"] as Array).duplicate()
	if members.is_empty():
		members = [ipid]
	if pid not in members:
		members.append(pid)
	if members.size() > MAX_PARTY:
		return
	_party_set(members)
	var names := []
	for m in members:
		if _session.has(m):
			names.append(str(_session[m]["name"]))
	print("[zone] party formed: %s" % ", ".join(names))

func party_decline(pid: int) -> void:
	_party_invites.erase(pid)

func party_leave(pid: int) -> void:
	_party_leave(pid)

# set each member's party to the shared list (disband if < 2 left); the roster rides the snapshot
func _party_set(members: Array) -> void:
	if members.size() < 2:
		for m in members:
			if _session.has(m):
				_session[m]["party"] = []
		return
	for m in members:
		if _session.has(m):
			_session[m]["party"] = members.duplicate()

func _party_leave(pid: int) -> void:
	_party_invites.erase(pid)
	if not _session.has(pid):
		return
	var party: Array = (_session[pid]["party"] as Array).duplicate()
	_session[pid]["party"] = []
	if party.is_empty():
		return
	var rest := []
	for m in party:
		if m != pid and _session.has(m):
			rest.append(m)
	_party_set(rest)                              # rebuild the remainder (disbands at < 2)

# the party roster for a player's snapshot: live HP so the HUD frames stay current
func _party_roster(pid: int) -> Array:
	var out := []
	if not _session.has(pid):
		return out
	for m in _session[pid]["party"]:
		if not _session.has(m):
			continue
		var mf = _find(_session[m]["fid"])
		out.append({"fid": str(_session[m]["fid"]), "name": str(_session[m]["name"]),
			"hp": int(round(mf["hp"])) if mf != null else 0, "maxHP": int(mf["maxHP"]) if mf != null else 1,
			"alive": bool(mf["alive"]) if mf != null else false, "map": str(_session[m]["map"])})
	return out

# ---- intents ----
func submit_intent(pid: int, mv: Dictionary) -> void:
	if not _move.has(pid):
		return
	var v := Vector2(clampf(float(mv.get("mx", 0.0)), -1.0, 1.0), clampf(float(mv.get("my", 0.0)), -1.0, 1.0))
	if v.length() > 1.0:
		v = v.normalized()
	_move[pid] = {"mx": v.x, "my": v.y, "target": str(mv.get("target", "")), "friend": str(mv.get("friend", ""))}
	_intent_age[pid] = 0

func submit_ability(pid: int, key, seq) -> void:
	if not _session.has(pid) or typeof(key) != TYPE_STRING:
		return
	if int(seq) > int(_last_aseq.get(pid, 0)):
		_last_aseq[pid] = int(seq)
		_pending_ability[pid] = key

# ---- authoritative tick ----
func _physics_process(delta: float) -> void:
	if _worlds.is_empty():
		return
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		for mapname in _worlds:
			_tick_world(_worlds[mapname], mapname)
		_advance_respawns(SIM_DT)                 # respawn countdown runs once per tick (not per world)
		_check_portals()                          # move players between worlds after the sims resolve
		_apply_godmode()                          # keep god-mode players invulnerable (after damage resolves)
		_acc -= SIM_DT
		steps += 1
	if steps == 5:
		_acc = 0.0
	_save_t += delta                              # save clock runs every frame, not just on sim steps
	if _save_t >= SAVE_INTERVAL:
		_save_t = 0.0
		_save_all()
	if steps > 0:
		_award_kills()                            # grant XP for mob kills before events are cleared
		_broadcast()

func _tick_world(w: Dictionary, mapname: String) -> void:
	_update_mob_ai(w)                             # aggro / leash before the sim resolves actions
	w["winner"] = null
	w["controlled"] = {}
	for pid in _peers:
		if str(_session[pid].get("map", World.HOME)) != mapname:
			continue
		var fid: String = _session[pid]["fid"]
		_intent_age[pid] = int(_intent_age.get(pid, 0)) + 1
		var mv = _move.get(pid, {"mx": 0.0, "my": 0.0})
		var mx: float = mv["mx"]
		var my: float = mv["my"]
		if _intent_age[pid] > STALE_INTENT_TICKS:
			mx = 0.0
			my = 0.0
		w["controlled"][fid] = {"mx": mx, "my": my, "ability": _pending_ability.get(pid, ""), "target": str(mv.get("target", "")), "friend": str(mv.get("friend", ""))}
		_pending_ability[pid] = ""
	Sim.sim_tick(w, SIM_DT)
	_apply_regen(w)                               # out-of-combat health regen (rate/delay per map type)
	for f in w["fighters"]:                       # queue the dead for respawn (instant for the dummy)
		if not f["alive"] and not _respawn.has(f["id"]):
			_respawn[f["id"]] = 0.0 if f.get("dummy", false) else RESPAWN_DELAY

# heal living players toward max HP; fast on safe maps, slow + delayed-after-damage on combat maps.
# Gate on the engine's noDmgT (seconds since the last hit) — it resets on ANY hit, even one fully
# absorbed by a shield/DR, so a shielded-but-attacked player doesn't regen "out of combat".
func _apply_regen(w: Dictionary) -> void:
	var rate := float(w.get("regen", 0.0))
	if rate <= 0.0:
		return
	var delay := float(w.get("regenDelay", 0.0))
	for f in w["fighters"]:
		if f["team"] != 0 or not f["alive"] or f["hp"] >= f["maxHP"]:
			continue
		if float(f.get("noDmgT", 0.0)) >= delay:
			f["hp"] = minf(f["maxHP"], f["hp"] + f["maxHP"] * rate * SIM_DT)

func _advance_respawns(dt: float) -> void:
	var done := []
	for id in _respawn:
		_respawn[id] -= dt
		if _respawn[id] <= 0.0:
			done.append(id)
	for id in done:
		_respawn.erase(id)
		_revive(_find(id))

# step into a portal pad → move the player's fighter to the other world at the pad's destination
func _check_portals() -> void:
	var now := Time.get_ticks_msec()
	for pid in _peers:
		var s = _session[pid]
		var f = _find(s["fid"])
		if f == null or not f["alive"] or now < int(_tp_next.get(f["id"], 0)):
			continue
		for portal in World.PORTALS.get(s["map"], []):
			if Vector2(f["x"] - float(portal["x"]), f["y"] - float(portal["y"])).length() <= World.PORTAL_RADIUS:
				_portal_teleport(f, s, portal)
				_tp_next[f["id"]] = now + TP_GRACE_MS
				break

func _portal_teleport(f, s, portal) -> void:
	var from_map: String = str(f["map"])
	var to_map: String = str(portal["to"])
	if not _worlds.has(to_map):
		return
	_worlds[from_map]["fighters"].erase(f)
	f["x"] = float(portal["tx"])
	f["y"] = float(portal["ty"])
	f["map"] = to_map
	f["arenaW"] = int(_worlds[to_map].get("arenaW", GameData.ARENA_W))   # adopt the destination world's bounds
	f["arenaH"] = int(_worlds[to_map].get("arenaH", GameData.ARENA_H))
	_worlds[to_map]["fighters"].append(f)
	_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])    # respawn at the arrival point in the new world
	s["map"] = to_map
	print("[zone] %s → %s" % [s["name"], to_map])

# mob behaviour: engage players near the camp; otherwise hold/reset home (frozen via the seam).
# the training dummy is always frozen — it never moves or attacks (just takes hits).
func _update_mob_ai(w: Dictionary) -> void:
	var frozen := {}
	var aggro_on := bool(w.get("aggro", true))   # safe maps never aggro/chase
	for f in w["fighters"]:
		if f["team"] != 1:
			continue
		if f.get("dummy", false) or not aggro_on:
			frozen[f["id"]] = true
			continue
		var here := Vector2(f["x"], f["y"])
		var spawn: Vector2 = _spawn_pos.get(f["id"], here)
		var was := bool(_mob_engaged.get(f["id"], false))
		var radius: float = LEASH_RANGE if was else AGGRO_RANGE   # hysteresis: harder to drop than to start
		var engaged := false
		if (here - spawn).length() <= MAX_LEASH:                 # stays tethered to its camp
			for p in w["fighters"]:
				if p["team"] == 0 and p["alive"] and (Vector2(p["x"], p["y"]) - here).length() < radius:
					engaged = true
					break
		_mob_engaged[f["id"]] = engaged
		frozen[f["id"]] = not engaged
		if not engaged and f["alive"]:
			f["x"] = spawn.x                                     # disengaged → return to camp
			f["y"] = spawn.y
			if was:                                             # heal to full only on the engage→disengage edge
				f["hp"] = f["maxHP"]
	w["frozenIds"] = frozen

func _award_kills() -> void:
	for mapname in _worlds:
		for ev in _worlds[mapname]["events"]:
			if ev.get("type") != "kill":
				continue
			var victim = _find(ev["victim"])
			if victim == null or victim["team"] != 1 or victim.get("dummy", false):  # mobs only, not the dummy
				continue
			for pid in _peers:
				if _session[pid]["fid"] == ev["killer"]:
					_award_xp(pid, _mob_xp(victim))
					_grant_loot(pid, victim)
					break

func _award_xp(pid: int, amt: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	s["xp"] = int(s["xp"]) + amt
	while s["xp"] >= _xp_to_next(int(s["level"])):
		s["xp"] -= _xp_to_next(int(s["level"]))
		s["level"] = int(s["level"]) + 1
		var f = _find(s["fid"])
		if f != null:
			f["maxHP"] += LEVEL_HP
			f["hp"] = f["maxHP"]
	_save_one(s, _find(s["fid"]))                # persist xp/level on every kill (durable progression)
	print("[zone] %s +%d xp → lvl %d (%d/%d)" % [s["name"], amt, s["level"], s["xp"], _xp_to_next(int(s["level"]))])

func _revive(f) -> void:
	if f == null:
		return
	var orig_id = f["id"]
	var fresh := GameData.create_fighter(f["classId"], f["team"], f["slot"], Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	_fseq += 1
	for k in fresh:                               # custom fields (map/dummy/mobLevel/mobTier) aren't in fresh → preserved
		f[k] = fresh[k]
	f["id"] = orig_id
	var sp = _spawn_pos.get(orig_id, Vector2(f["x"], f["y"]))
	f["x"] = sp.x
	f["y"] = sp.y
	if f.get("dummy", false):                     # training dummy: fixed HP, no scaling
		f["maxHP"] = DUMMY_HP
		f["hp"] = DUMMY_HP
	elif f["team"] == 0:                          # re-derive from base stats + level + equipped gear
		var s = _session_by_fid(orig_id)
		if s != null:
			_recompute_player_stats(f, int(s["level"]), s.get("equip_bonus", {}))
	elif f["team"] == 1:                          # re-apply mob level/tier scaling
		_scale_mob(f)

func _scale_mob(f) -> void:
	var lvl := int(f.get("mobLevel", 1))
	var elite: bool = str(f.get("mobTier", "minion")) == "elite"
	var hp_s := MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * (MOB_ELITE_HP if elite else 1.0)
	var dmg_s := MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * (MOB_ELITE_DMG if elite else 1.0)
	f["maxHP"] = f["maxHP"] * hp_s
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s

func _mob_xp(mob) -> int:
	var lvl := int(mob.get("mobLevel", 1))
	var elite: bool = str(mob.get("mobTier", "minion")) == "elite"
	return MOB_XP_BASE * lvl * (MOB_ELITE_XP if elite else 1)

func _grant_loot(pid: int, mob) -> void:
	if not _session.has(pid):
		return
	var item := _roll_loot(mob)
	if item.is_empty():
		return
	var s = _session[pid]
	var r = await supa.add_item_as(s["access"], s["char_id"], item)
	if not r.get("ok"):                                  # never tell the client it looted something we didn't save
		print("[loot] %s drop NOT saved (code %s)" % [s["name"], r.get("code", "?")])
		return
	if _session.has(pid):                                # still connected after the write
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		print("[loot] %s looted [%s] %s (+%d %s)" % [s["name"], item["rarity"], item["name"], item["bonus_amt"], item["bonus_stat"]])

func _roll_loot(mob) -> Dictionary:
	var elite: bool = str(mob.get("mobTier", "minion")) == "elite"
	var lvl := int(mob.get("mobLevel", 1))
	var chance := 1.0 if elite else 0.65
	if _loot_rng.next() > chance:
		return {}
	var rar := _roll_rarity(elite)
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	var bases: Array = LOOT_SLOTS[slot]
	var base: String = bases[_loot_rng.next_int(bases.size())]
	var stat: String = LOOT_STATS[_loot_rng.next_int(LOOT_STATS.size())]
	return {"name": base, "rarity": str(rar["name"]), "slot": slot, "bonus_stat": stat, "bonus_amt": int(rar["mult"]) * (2 + lvl)}

func _roll_rarity(elite: bool) -> Dictionary:
	var total := 0
	for r in RARITIES:
		total += int(r["weight"])
	var roll: float = _loot_rng.next() * total
	var acc := 0.0
	var idx := 0
	for i in RARITIES.size():
		acc += float(RARITIES[i]["weight"])
		if roll < acc:
			idx = i
			break
	if elite:
		idx = min(idx + 2, RARITIES.size() - 1)
	return RARITIES[idx]

# ---- equipment ----
# client → server: toggle an item equipped (one item per slot). Re-derives the fighter's stats.
func equip(pid: int, item_id: String, _slot: String) -> void:
	if not _session.has(pid) or _equipping.has(pid):
		return
	var now := Time.get_ticks_msec()
	if now < int(_equip_next.get(pid, 0)):           # rate limit rapid clicks
		return
	_equip_next[pid] = now + 300
	_equipping[pid] = true                           # serialize: one toggle at a time per player
	var s = _session[pid]
	var inv = await supa.get_inventory_as(s["access"])
	var item = null
	if inv.get("ok"):
		for it in inv["items"]:
			if str(it["id"]) == item_id:
				item = it
				break
	if item != null:                                 # only if it's this player's item
		var islot: String = str(item["slot"])
		var ok: bool
		if bool(item["equipped"]):                   # toggle OFF: unequip this item
			ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq." + item_id, false)).get("ok"))
		else:                                        # toggle ON: equip it FIRST, then clear others in the slot
			ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq." + item_id, true)).get("ok"))
			if ok:                                   # (so a failed clear can't strand the slot empty)
				await supa.inv_set_equipped_as(s["access"], "character_id=eq.%s&slot=eq.%s&id=neq.%s" % [s["char_id"], islot, item_id], false)
		if not ok:                                   # surface the failure (e.g. SUPABASE_SERVICE_KEY unset → 403)
			print("[zone] equip write failed for %s — is SUPABASE_SERVICE_KEY set?" % s["name"])
		await _apply_equipment(pid)                  # re-derive from the actually-persisted DB state either way
	_equipping.erase(pid)
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# read the player's equipped items and re-derive its fighter's stats (one item per slot, capped)
func _apply_equipment(pid: int) -> void:
	if not _session.has(pid):
		return
	var f = _find(_session[pid]["fid"])
	if f == null:
		return
	var inv = await supa.get_inventory_as(_session[pid]["access"])
	if not inv.get("ok") or not _session.has(pid):
		return
	var bonus := {}
	var used := {}
	for it in inv["items"]:
		if not bool(it["equipped"]):
			continue
		var slot := str(it["slot"])
		if used.has(slot):                           # defensive: only one item per slot counts
			continue
		used[slot] = true
		var st := str(it.get("bonus_stat", ""))
		if st == "":
			continue
		var cap := int(RARITY_CAP.get(str(it.get("rarity", "common")), 4))
		bonus[st] = int(bonus.get(st, 0)) + min(int(it.get("bonus_amt", 0)), cap)
	_session[pid]["equip_bonus"] = bonus                 # cache for fast re-apply on respawn
	_recompute_player_stats(_find(_session[pid]["fid"]), int(_session[pid]["level"]), bonus)

# re-derive maxHP/dmgMult/crit/ms/… from base stats + equipped bonuses, preserving HP fraction
func _recompute_player_stats(f, level: int, bonus: Dictionary) -> void:
	if f == null:
		return
	var c = GameData.CLASSES[f["classId"]]
	var stats: Dictionary = c["stats"].duplicate()
	for st in LOOT_STATS:
		if bonus.has(st):
			stats[st] = int(stats[st]) + int(bonus[st])
	var d = GameData.derive(stats)
	var bm: Dictionary = GameData.FORMAT_MODS.get(ZONE_TEAM_SIZE, {}).get(f["classId"], {})
	var maxhp: float = d["maxHP"]
	var dmg: float = d["dmgMult"]
	if bm.has("dmg"): dmg *= bm["dmg"]
	if bm.has("hp"): maxhp = round(maxhp * bm["hp"])
	var frac: float = clampf(f["hp"] / f["maxHP"], 0.0, 1.0) if f["maxHP"] > 0 else 1.0
	f["maxHP"] = maxhp + (level - 1) * LEVEL_HP
	f["dmgMult"] = dmg
	f["crit"] = d["crit"]
	f["critMult"] = d["critMult"]
	f["ms"] = d["ms"]
	f["cdr"] = d["cdr"]
	f["clutchDmg"] = d["clutchDmg"]
	f["clutchDR"] = d["clutchDR"]
	f["hp"] = f["maxHP"] * frac

# ---- admin / god-mode (gated: only sessions flagged admin via the service-role admins table) ----
func admin_cmd(pid: int, cmd: String, args: Dictionary) -> void:
	if not _session.has(pid) or not bool(_session[pid].get("admin", false)):
		return                                       # not an admin → ignore (authoritative gate)
	var s = _session[pid]
	var f = _find(s["fid"])
	if f == null:
		return
	match cmd:
		"level_up", "level_down":
			s["level"] = clampi(int(s["level"]) + (1 if cmd == "level_up" else -1), 1, 99)
			_recompute_player_stats(f, int(s["level"]), s.get("equip_bonus", {}))
			f["hp"] = f["maxHP"]
			_save_one(s, f)
		"add_xp":
			_award_xp(pid, int(args.get("amt", 100)))
		"give_item":
			_admin_give_item(pid)
		"clear_items":
			await supa.clear_inventory_as(s["char_id"])
			await _apply_equipment(pid)
			if net != null and _session.has(pid):
				net.recv_inventory_changed.rpc_id(pid)
		"god":
			s["god"] = not bool(s.get("god", false))
			if bool(s["god"]):
				f["maxHP"] = 999999.0
				f["hp"] = 999999.0
				f["dmgMult"] = 50.0
			else:
				_recompute_player_stats(f, int(s["level"]), s.get("equip_bonus", {}))
				f["hp"] = f["maxHP"]
		"heal":
			f["hp"] = f["maxHP"]
		"to_home":
			_relocate(f, s, World.HOME, World.HOME_SPAWN)
		"to_combat":
			_relocate(f, s, World.COMBAT, World.COMBAT_SPAWN)
		"spawn_mob":
			var mid := _spawn_fighter("linebacker", 1, Vector2(f["x"] + 100.0, f["y"]), str(s["map"]))
			var mf = _find(mid)
			mf["mobLevel"] = clampi(int(args.get("level", 3)), 1, 10)
			mf["mobTier"] = "elite"
			_scale_mob(mf)
		"clear_mobs":
			var w = _worlds[str(s["map"])]
			var keep := []
			for ff in w["fighters"]:
				if ff["team"] == 1 and not ff.get("dummy", false):
					_spawn_pos.erase(ff["id"])
					_mob_engaged.erase(ff["id"])
					_respawn.erase(ff["id"])
				else:
					keep.append(ff)
			w["fighters"] = keep
		"reset_mobs":
			_reset_mobs()
	print("[admin] %s ran '%s'" % [s["name"], cmd])

# wipe every mob and re-spawn the original roster (combat camps + the home dummy) — fixes a map
# whose mobs were cleared and never came back (cleared mobs aren't queued for respawn).
func _reset_mobs() -> void:
	for mapname in _worlds:
		var w = _worlds[mapname]
		var keep := []
		for ff in w["fighters"]:
			if ff["team"] == 1:
				_spawn_pos.erase(ff["id"])
				_mob_engaged.erase(ff["id"])
				_respawn.erase(ff["id"])
			else:
				keep.append(ff)
		w["fighters"] = keep
	var did := _spawn_fighter(World.DUMMY_CLASS, 1, World.DUMMY_POS, World.HOME)
	var dummy = _find(did)
	dummy["dummy"] = true
	dummy["maxHP"] = DUMMY_HP
	dummy["hp"] = DUMMY_HP
	for m in World.MOBS:
		var fid := _spawn_fighter(str(m["class"]), 1, Vector2(float(m["x"]), float(m["y"])), World.COMBAT)
		var f = _find(fid)
		f["mobLevel"] = int(m["level"])
		f["mobTier"] = str(m["tier"])
		_scale_mob(f)

# real god-mode: keep flagged players topped up + alive every tick so they take hits (flash/numbers)
# but can't be drained or one-shot — and clear stun/slow so they're never locked.
func _apply_godmode() -> void:
	for pid in _peers:
		if not bool(_session[pid].get("god", false)):
			continue
		var f = _find(_session[pid]["fid"])
		if f == null:
			continue
		f["hp"] = f["maxHP"]
		f["alive"] = true
		f["stun"] = 0.0
		f["slowT"] = 0.0
		_respawn.erase(f["id"])

func _admin_give_item(pid: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	var rar = RARITIES[_loot_rng.next_int(RARITIES.size())]
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	var bases: Array = LOOT_SLOTS[slot]
	var item := {"name": str(bases[_loot_rng.next_int(bases.size())]), "rarity": str(rar["name"]), "slot": slot,
		"bonus_stat": LOOT_STATS[_loot_rng.next_int(LOOT_STATS.size())], "bonus_amt": int(rar["mult"]) * 6}
	var r = await supa.add_item_as(s["access"], s["char_id"], item)
	if r.get("ok") and net != null and _session.has(pid):
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))

func _relocate(f, s, to_map: String, pos: Vector2) -> void:
	if not _worlds.has(to_map):
		return
	_worlds[str(f["map"])]["fighters"].erase(f)
	f["x"] = pos.x
	f["y"] = pos.y
	f["map"] = to_map
	f["arenaW"] = int(_worlds[to_map].get("arenaW", GameData.ARENA_W))
	f["arenaH"] = int(_worlds[to_map].get("arenaH", GameData.ARENA_H))
	_worlds[to_map]["fighters"].append(f)
	_spawn_pos[f["id"]] = pos
	s["map"] = to_map
	_tp_next[f["id"]] = Time.get_ticks_msec() + TP_GRACE_MS

func _find(id) -> Variant:
	for mapname in _worlds:
		for f in _worlds[mapname]["fighters"]:
			if f["id"] == id:
				return f
	return null

# ---- persistence ----
func _save_all() -> void:
	for pid in _peers.duplicate():
		if _session.has(pid):
			_save_one(_session[pid], _find(_session[pid]["fid"]))

func _save_one(session: Dictionary, f) -> void:
	if supa == null:
		return
	# xp/level + the current world are always valid (they live on the session), so persist them even
	# for a corpse. Position is the live spot when alive, else the respawn point — never the death
	# spot — so last_map and last_x/last_y always stay consistent (you resume in the world you were in).
	var fields := {"xp": int(session["xp"]), "level": int(session["level"]),
		"last_map": str(session.get("map", World.HOME))}
	if f != null:
		if f["alive"]:
			fields["last_x"] = f["x"]
			fields["last_y"] = f["y"]
		else:
			var sp: Vector2 = _spawn_pos.get(f["id"], Vector2(f["x"], f["y"]))
			fields["last_x"] = sp.x
			fields["last_y"] = sp.y
	await supa.save_character_as(session["access"], session["char_id"], fields)

# ---- interest-managed snapshots (per world) ----
func _broadcast() -> void:
	var pinfo := {}
	for pid in _peers:
		var s = _session[pid]
		var pf = _find(s["fid"])                  # include derived combat stats for skill-bar tooltips
		pinfo[s["fid"]] = {"level": int(s["level"]), "xp": int(s["xp"]), "xpNext": _xp_to_next(int(s["level"])),
			"name": str(s["name"]),
			"dmgMult": float(pf["dmgMult"]) if pf != null else 1.0,
			"crit": float(pf["crit"]) if pf != null else 0.0,
			"critMult": float(pf["critMult"]) if pf != null else 1.5}
	for pid in _peers:
		var s = _session[pid]
		var f = _find(s["fid"])
		if f == null or not _worlds.has(s["map"]):
			continue
		var snap: Dictionary = _snapshot_for(_worlds[s["map"]], str(s["map"]), Vector2(f["x"], f["y"]), pinfo)
		snap["party"] = _party_roster(pid)        # roster (with live HP) for the party HUD
		net.receive_snapshot.rpc_id(pid, snap)
	for mapname in _worlds:
		_worlds[mapname]["events"].clear()
	_snap_count += 1
	if _snap_count % 300 == 0:                    # concise heartbeat every ~10s
		var counts := []
		for mapname in _worlds:
			var np := 0
			for f in _worlds[mapname]["fighters"]:
				if f["team"] == 0:
					np += 1
			counts.append("%s:%dp" % [mapname, np])
		print("[zone] t=%.0f  %s" % [_worlds[World.COMBAT]["t"], " ".join(counts)])

func _snapshot_for(w: Dictionary, mapname: String, center: Vector2, pinfo: Dictionary) -> Dictionary:
	var fs := []
	for f in w["fighters"]:
		if Vector2(f["x"] - center.x, f["y"] - center.y).length() <= INTEREST_RADIUS:
			var d := {
				"id": f["id"], "classId": f["classId"], "team": f["team"],
				"x": f["x"], "y": f["y"], "hp": f["hp"], "maxHP": f["maxHP"],
				"alive": f["alive"], "flash": f["flash"], "cds": f["cds"].duplicate(),
			}
			if pinfo.has(f["id"]):
				var pi = pinfo[f["id"]]
				d["level"] = pi["level"]
				d["name"] = pi["name"]
				d["xp"] = pi["xp"]
				d["xpNext"] = pi["xpNext"]
				d["dmgMult"] = pi["dmgMult"]
				d["crit"] = pi["crit"]
				d["critMult"] = pi["critMult"]
			if f["team"] == 1:
				d["mobLevel"] = int(f.get("mobLevel", 1))
				d["mobTier"] = str(f.get("mobTier", "minion"))
				if f.get("dummy", false):
					d["dummy"] = true
			fs.append(d)
	var ps := []
	for p in w["projectiles"]:
		if Vector2(p["x"] - center.x, p["y"] - center.y).length() <= INTEREST_RADIUS:
			ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0)})
	return {"fighters": fs, "projectiles": ps, "events": w["events"].duplicate(true), "t": w["t"],
		"map": mapname, "portals": World.portals_for(mapname),
		"arenaW": int(w.get("arenaW", GameData.ARENA_W)), "arenaH": int(w.get("arenaH", GameData.ARENA_H))}
