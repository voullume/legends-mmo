extends Node
## SHARED ZONE SERVER (Phase 4 + 5). One persistent, server-authoritative overworld that several
## accounts' characters share. A joining client authenticates with its Supabase access token; the
## server loads that account's character (class, position, level, xp) and spawns it.
##
## - Players are team 0 (they coexist — abilities target enemies, so they don't hit each other).
## - Mobs are team 1 with aggro/leash (Phase 5): they engage players who enter their camp and
##   reset to spawn when the camp empties. Killing a mob grants XP; XP levels you up (+max HP),
##   and level/xp/position persist to the account.
## - Per-client snapshots are interest-managed (only entities near the client's fighter).
##
## SECURITY NOTE: pass --dtls (on the server AND clients) to encrypt the ENet transport; without
## it the link is plaintext. Only the short-lived access token crosses the wire (the refresh token
## stays on the client, re-issued via reauth). DTLS here encrypts but does not verify the server
## identity (no MITM protection yet), so prefer a VPN or a host you control.

const Sim := preload("res://shared/Sim.gd")
const GameData := preload("res://shared/GameData.gd")
const Geom := preload("res://shared/Geom.gd")
const Rng := preload("res://shared/Rng.gd")

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
const LEASH_RANGE := 480.0            # once engaged, stays engaged until players pass this (hysteresis)
const MAX_LEASH := 520.0              # a mob never strays further than this from its camp
const MOB_HP_SCALE := 0.35            # base mob HP fraction (scaled up by level + tier)
const MOB_DMG_SCALE := 0.28           # base mob damage fraction (scaled up by level + tier)
const MOB_XP_BASE := 15               # mob XP = base × level × (elite ? 4 : 1)
const MOB_ELITE_HP := 2.2
const MOB_ELITE_DMG := 1.6
const MOB_ELITE_XP := 4
const LEVEL_HP := 60.0                # bonus max HP per player level
# Camps form a difficulty gradient from the player's start (left) toward the elite (right).
const MOBS := [
	{"class": "setter", "level": 1, "tier": "minion", "x": 400.0, "y": 175.0},
	{"class": "spiker", "level": 1, "tier": "minion", "x": 400.0, "y": 365.0},
	{"class": "striker", "level": 2, "tier": "minion", "x": 620.0, "y": 200.0},
	{"class": "batter", "level": 2, "tier": "minion", "x": 620.0, "y": 340.0},
	{"class": "linebacker", "level": 3, "tier": "elite", "x": 830.0, "y": 270.0},
]

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

var _state: Dictionary = {}
var _peers: Array = []
var _authing := {}
var _session := {}                  # peer id → {fid, access, char_id, name, xp, level}
var _move := {}
var _pending_ability := {}
var _last_aseq := {}
var _intent_age := {}
var _spawn_pos := {}
var _respawn := {}
var _mob_engaged := {}              # mob id → currently engaged (for leash hysteresis + heal-once)
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
	_state = Sim.create_match([], [], SEED, MAP_ID)
	_state["zone"] = true                        # persistent: no match-end / no overtime ramp
	for m in MOBS:
		var fid := _spawn_fighter(m["class"], 1, Vector2(m["x"], m["y"]))
		var f = _find(fid)
		f["mobLevel"] = int(m["level"])
		f["mobTier"] = str(m["tier"])
		_scale_mob(f)
	print("[zone] online on UDP %d  (map=%s, %d mobs%s)" % [port, MAP_ID, MOBS.size(), "  · DTLS" if use_dtls else ""])
	return true

# ---- connection / auth ----
func _on_peer_connected(pid: int) -> void:
	print("[zone] peer %d connected — awaiting auth" % pid)

func _on_peer_disconnected(pid: int) -> void:
	_authing.erase(pid)
	if not _session.has(pid):
		return
	var s = _session[pid]                        # capture before erasing (the save coroutine holds it)
	_save_one(s, _find(s["fid"]))                # persist xp/level (+ position if alive), even on a corpse
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
	_peers.append(pid)
	_session[pid] = {"fid": fid, "access": access, "char_id": str(ch["id"]),
		"name": str(ch.get("name", "?")), "xp": int(ch.get("xp", 0)), "level": lvl}
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	net.assign_fighter.rpc_id(pid, fid)
	await _apply_equipment(pid)                       # re-derive stats from saved equipment
	print("[zone] %s (%s, lvl %d) joined as %s — now %d player(s)" % [ch.get("name", "?"), ch.get("class", "?"), lvl, fid, _peers.size()])

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
	var pos := Vector2(float(ch.get("last_x", 480.0)), float(ch.get("last_y", 270.0)))
	var fid := _spawn_fighter(cls, 0, pos)
	var f = _find(fid)
	if f != null:
		f["maxHP"] += (level - 1) * LEVEL_HP       # progression: bonus HP per level
		f["hp"] = f["maxHP"]
	return fid

func _spawn_fighter(cls: String, team: int, pos: Vector2) -> String:
	var slot := 0
	for f in _state["fighters"]:
		if f["team"] == team:
			slot += 1
	_fseq += 1
	var f := GameData.create_fighter(cls, team, slot, Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	f["id"] = ("p" if team == 0 else "m") + str(_fseq)
	f["x"] = pos.x
	f["y"] = pos.y
	Geom.clamp_arena(f)
	_state["fighters"].append(f)
	_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])
	return f["id"]

func _remove_fighter(fid: String) -> void:
	var keep := []
	for f in _state["fighters"]:
		if f["id"] != fid:
			keep.append(f)
	_state["fighters"] = keep
	_spawn_pos.erase(fid)
	_respawn.erase(fid)

func _session_by_fid(fid: String) -> Variant:
	for pid in _session:
		if _session[pid]["fid"] == fid:
			return _session[pid]
	return null

# ---- intents ----
func submit_intent(pid: int, mv: Dictionary) -> void:
	if not _move.has(pid):
		return
	var v := Vector2(clampf(float(mv.get("mx", 0.0)), -1.0, 1.0), clampf(float(mv.get("my", 0.0)), -1.0, 1.0))
	if v.length() > 1.0:
		v = v.normalized()
	_move[pid] = {"mx": v.x, "my": v.y}
	_intent_age[pid] = 0

func submit_ability(pid: int, key, seq) -> void:
	if not _session.has(pid) or typeof(key) != TYPE_STRING:
		return
	if int(seq) > int(_last_aseq.get(pid, 0)):
		_last_aseq[pid] = int(seq)
		_pending_ability[pid] = key

# ---- authoritative tick ----
func _physics_process(delta: float) -> void:
	if _state.is_empty():
		return
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		_update_mob_ai()                          # aggro / leash before the sim resolves actions
		_state["winner"] = null
		_state["controlled"] = {}
		for pid in _peers:
			var fid: String = _session[pid]["fid"]
			_intent_age[pid] = int(_intent_age.get(pid, 0)) + 1
			var mv = _move.get(pid, {"mx": 0.0, "my": 0.0})
			var mx: float = mv["mx"]
			var my: float = mv["my"]
			if _intent_age[pid] > STALE_INTENT_TICKS:
				mx = 0.0
				my = 0.0
			_state["controlled"][fid] = {"mx": mx, "my": my, "ability": _pending_ability.get(pid, "")}
			_pending_ability[pid] = ""
		Sim.sim_tick(_state, SIM_DT)
		_tick_respawns(SIM_DT)
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

# mob behaviour: engage players near the camp; otherwise hold/reset home (frozen via the seam)
func _update_mob_ai() -> void:
	var frozen := {}
	for f in _state["fighters"]:
		if f["team"] != 1:
			continue
		var here := Vector2(f["x"], f["y"])
		var spawn: Vector2 = _spawn_pos.get(f["id"], here)
		var was := bool(_mob_engaged.get(f["id"], false))
		var radius: float = LEASH_RANGE if was else AGGRO_RANGE   # hysteresis: harder to drop than to start
		var engaged := false
		if (here - spawn).length() <= MAX_LEASH:                 # stays tethered to its camp
			for p in _state["fighters"]:
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
	_state["frozenIds"] = frozen

func _award_kills() -> void:
	for ev in _state["events"]:
		if ev.get("type") != "kill":
			continue
		var victim = _find(ev["victim"])
		if victim == null or victim["team"] != 1:    # only mob kills grant XP
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

func _tick_respawns(dt: float) -> void:
	for f in _state["fighters"]:
		if not f["alive"] and not _respawn.has(f["id"]):
			_respawn[f["id"]] = RESPAWN_DELAY
	var done := []
	for id in _respawn:
		_respawn[id] -= dt
		if _respawn[id] <= 0.0:
			done.append(id)
	for id in done:
		_respawn.erase(id)
		_revive(_find(id))

func _revive(f) -> void:
	if f == null:
		return
	var orig_id = f["id"]
	var fresh := GameData.create_fighter(f["classId"], f["team"], f["slot"], Rng.new(SEED + _fseq), ZONE_TEAM_SIZE)
	_fseq += 1
	for k in fresh:
		f[k] = fresh[k]
	f["id"] = orig_id
	var sp = _spawn_pos.get(orig_id, Vector2(f["x"], f["y"]))
	f["x"] = sp.x
	f["y"] = sp.y
	if f["team"] == 0:                            # re-derive from base stats + level + equipped gear
		var s = _session_by_fid(orig_id)
		if s != null:
			_recompute_player_stats(f, int(s["level"]), s.get("equip_bonus", {}))
	elif f["team"] == 1:                          # re-apply mob level/tier scaling (mobLevel/Tier survive the copy)
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
	var chance := 1.0 if elite else 0.45
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
		await supa.inv_set_equipped_as(s["access"], "character_id=eq.%s&slot=eq.%s" % [s["char_id"], islot], false)
		if not bool(item["equipped"]):               # toggle: equip unless it was already equipped
			await supa.inv_set_equipped_as(s["access"], "id=eq." + item_id, true)
		await _apply_equipment(pid)
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

func _find(id) -> Variant:
	for f in _state["fighters"]:
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
	# xp/level are always valid (they live on the session) — persist them even for a corpse.
	# Position is only persisted when alive (never write a dead fighter's death-spot).
	var fields := {"xp": int(session["xp"]), "level": int(session["level"])}
	if f != null and f["alive"]:
		fields["last_x"] = f["x"]
		fields["last_y"] = f["y"]
		fields["last_map"] = MAP_ID
	await supa.save_character_as(session["access"], session["char_id"], fields)

# ---- interest-managed snapshots ----
func _broadcast() -> void:
	var pinfo := {}
	for pid in _peers:
		var s = _session[pid]
		pinfo[s["fid"]] = {"level": int(s["level"]), "xp": int(s["xp"]), "xpNext": _xp_to_next(int(s["level"]))}
	for pid in _peers:
		var f = _find(_session[pid]["fid"])
		if f == null:
			continue
		net.receive_snapshot.rpc_id(pid, _snapshot_for(Vector2(f["x"], f["y"]), pinfo))
	_state["events"].clear()
	_snap_count += 1
	if _snap_count % 60 == 0:
		var hps := []
		for f in _state["fighters"]:
			hps.append("%s=%d/%d%s" % [f["id"], int(f["hp"]), int(f["maxHP"]), ("" if f["alive"] else "(dead)")])
		print("[zone] t=%.1f  %s" % [_state["t"], hps])

func _snapshot_for(center: Vector2, pinfo: Dictionary) -> Dictionary:
	var fs := []
	for f in _state["fighters"]:
		if Vector2(f["x"] - center.x, f["y"] - center.y).length() <= INTEREST_RADIUS:
			var d := {
				"id": f["id"], "classId": f["classId"], "team": f["team"],
				"x": f["x"], "y": f["y"], "hp": f["hp"], "maxHP": f["maxHP"],
				"alive": f["alive"], "flash": f["flash"], "cds": f["cds"].duplicate(),
			}
			if pinfo.has(f["id"]):
				var pi = pinfo[f["id"]]
				d["level"] = pi["level"]
				d["xp"] = pi["xp"]
				d["xpNext"] = pi["xpNext"]
			if f["team"] == 1:
				d["mobLevel"] = int(f.get("mobLevel", 1))
				d["mobTier"] = str(f.get("mobTier", "minion"))
			fs.append(d)
	var ps := []
	for p in _state["projectiles"]:
		if Vector2(p["x"] - center.x, p["y"] - center.y).length() <= INTEREST_RADIUS:
			ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0)})
	return {"fighters": fs, "projectiles": ps, "events": _state["events"].duplicate(true), "t": _state["t"]}
