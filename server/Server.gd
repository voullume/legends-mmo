extends Node
## SHARED ZONE SERVER (Phase 4 + 5). Persistent, server-authoritative overworld for several accounts.
## Several worlds run side by side (see shared/World.gd — one independent sim each):
##   home          — a safe base: roam freely + a passive training dummy that instantly respawns.
##   glitchyard_1-5 — the chained Glitchyard training-camp zones (lvl 1→8 gradient, XP + loot + elites).
##   arena         — a dedicated open-PvP space (free-for-all).
## Portal pads teleport between worlds; each world carries its own arena bounds. Players only
## see/affect entities in their own world.
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
const Quests := preload("res://shared/Quests.gd")

const PORT := 7777
const MAP_ID := "stadium"
const SEED := 20260621
const SIM_DT := 1.0 / 30.0
const ZONE_TEAM_SIZE := 5
const RESPAWN_DELAY := 4.0            # player respawn delay
const MOB_RESPAWN_DELAY := 6.0        # mobs respawn a bit slower than players (less camp churn)
const BOSS_RESPAWN_DELAY := 1800.0   # the boss is a rare ~30-min world event (anti-farm), not a respawning camp
const SUMMON_CAP := 3                 # max LIVE summoned adds per summoner (anti-snowball); adds never respawn
const ADD_SPAWN_R := 70.0             # summoned adds emerge this far from the summoner
const SAVE_INTERVAL := 15.0
const HEALTH_INTERVAL := 60.0         # log a players + CPU + RAM line once a minute (upgrade-signal)
const INTEREST_RADIUS := 450.0
const STALE_INTENT_TICKS := 30
const AGGRO_RANGE := 320.0            # a mob engages a player within this range (covers ranged basics)
const LEASH_RANGE := 1600.0           # once engaged, stays engaged until players pass this (hysteresis)
const MAX_LEASH := 1600.0             # a mob chases up to this far from its camp before it resets (big combat arena)
const MOB_HP_SCALE := 0.35            # base mob HP fraction (scaled up by level + tier)
const MOB_DMG_SCALE := 0.28           # base mob damage fraction (scaled up by level + tier)
const MOB_XP_BASE := 15               # mob XP = base × level × tier mult (minion 1 / elite 4 / boss 6)
const MOB_ELITE_HP := 2.2
const MOB_ELITE_DMG := 1.6
const MOB_ELITE_XP := 4
const MOB_BOSS_HP := 22.0             # a raid-style boss tuned for a full party of 5 (NOT soloable) — a long fight
const MOB_BOSS_DMG := 2.1             # hits hard enough that ignoring its mechanics (ult/adds) wipes a careless group
const MOB_BOSS_XP := 6                # ≈ 0.9 of a level at its tier — rewarding but kept under a full level
const LEVEL_HP := 60.0                # bonus max HP per player level
const DUMMY_HP := 500.0               # the training dummy's fixed HP (no mob scaling)
const TP_GRACE_MS := 1500             # after a teleport/spawn, brief immunity to re-triggering a pad

# --- loot ---
# 10 item-TYPE slots. There are 11 EQUIP slots because `ring` has equip capacity 2 (see SLOT_CAP) — the
# stored item.slot only needs the 10 type strings; the second ring is a capacity, not a separate type.
const LOOT_SLOTS := {
	"head":      ["Helmet", "Cap", "Visor", "Headguard"],
	"chest":     ["Jersey", "Chest Pad", "Vest", "Breastplate"],
	"legs":      ["Leggings", "Shin Guards", "Trousers", "Greaves"],
	"hands":     ["Gauntlets", "Gloves", "Wraps", "Mitts"],
	"feet":      ["Cleats", "Boots", "Sneakers", "Treads"],
	"main_hand": ["Bat", "Racket", "Club", "Driver"],
	"off_hand":  ["Glove", "Shield", "Buckler", "Catcher's Mitt"],
	"neck":      ["Medal", "Chain", "Pendant", "Amulet"],
	"ring":      ["Ring", "Band", "Signet", "Loop"],
	"trinket":   ["Lucky Charm", "Whistle", "Captain's Band", "Token"],
}
# rarity: weight (drop chance, float) + mult (scales item budgets). legendary/mythic stay rare so their
# higher ceilings are aspirational, not routine.
const RARITIES := [
	{"name": "common",    "weight": 60.0, "mult": 1},
	{"name": "uncommon",  "weight": 27.0, "mult": 2},
	{"name": "rare",      "weight": 9.0,  "mult": 4},
	{"name": "epic",      "weight": 3.0,  "mult": 8},
	{"name": "legendary", "weight": 0.9,  "mult": 14},
	{"name": "mythic",    "weight": 0.1,  "mult": 20},
]
const LOOT_STATS := ["PWR", "PRE", "SPD", "END", "INS", "CLU"]
const SLOT_CAP := {"ring": 2}                # equip-slot capacity per item type (default 1; rings stack 2)
const AFFIX_COUNT_BY_RARITY := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4, "mythic": 4}
const SHOP_ILVL := 8                         # the shop catalog/roll's fixed item level (a reliable baseline)
# economy (Credits): buy from a fixed catalog, gamble a random roll, or sell inventory back
const BUY_PRICE := {"common": 40, "uncommon": 110, "rare": 280, "epic": 650}     # shop sells common..epic only
const ROLL_PRICE := {"common": 50, "uncommon": 130, "rare": 320, "epic": 720}
const SELL_PRICE := {"common": 14, "uncommon": 38, "rare": 95, "epic": 230, "legendary": 560, "mythic": 1200}
const SHOP_SLOT_STAT := {"head": "END", "chest": "END", "legs": "SPD", "hands": "PWR", "feet": "SPD",
	"main_hand": "PWR", "off_hand": "PRE", "neck": "INS", "ring": "CLU", "trinket": "INS"}
const SHOP_RARITIES := ["common", "uncommon", "rare", "epic"]
# RARITY_CAP caps EACH equipped item's EACH stat (primary + every affix) independently — the single
# anti-forge chokepoint (see _apply_equipment). ABS_CAP is the hard ceiling P4 upgrades climb toward.
const RARITY_CAP := {"common": 4, "uncommon": 10, "rare": 20, "epic": 40, "legendary": 60, "mythic": 80}
const ABS_CAP := 100
# Per-item RARITY_CAP gives items flavor (higher rarity = bigger single-item numbers), but with 11 equip
# slots the SUMMED bonus per stat would reach ~+200 at full epic — which the AI-duel balance harness shows
# blows the class win-rate spread from ~17 to ~50. EQUIP_STAT_CAP bounds the TOTAL equipment bonus per
# stat so full gear stays balance-neutral (harness: +60/stat → spread 13 ≤ the no-gear baseline). Every
# power source (primary, affixes, and later upgrades/gems/sets) funnels through this aggregate ceiling.
const EQUIP_STAT_CAP := 60
# --- Phase 4 progression sinks (single generic material "scrap") ---
const SALVAGE_YIELD := {"common": 1, "uncommon": 2, "rare": 5, "epic": 12, "legendary": 30, "mythic": 75}
const MAX_UPGRADE := 10                       # also CHECKed in the DB (0..10)
const UPGRADE_STEP := 2                       # each upgrade level raises an item's PER-ITEM cap by this
                                              # (bounded by ABS_CAP per item AND EQUIP_STAT_CAP in aggregate)
const RARITY_RANK := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4, "mythic": 5}
const SET_MIN_RANK := 3                       # only EPIC+ pieces count toward a set bonus (gates above-cap power)
# Set bonus STACKS ABOVE EQUIP_STAT_CAP (a set can push its signature stat past 60) — but only from EPIC+
# pieces, so the balance impact is limited to high-tier gear. Capped here; harness-tuned.
const SET_BONUS_CAP := 20                     # raised so the vendor-only Rookie Camp 4pc (20) actually lands; the sport sets stay 15 (their own th caps them)
const UNIQUE_DROP_CHANCE := 0.15              # P6: fraction of BOSS drops that are a unique instead

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
var _health_t := 0.0
var _tick_us_peak := 0                # peak server compute time per frame this minute (CPU headroom)

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
	for mapname in World.MAPS:                   # one independent sim per zone (home/combat/frontier/arena)
		_worlds[mapname] = _new_world(mapname)
	_spawn_world_actors()                        # the home dummy + every combat zone's mob camps
	print("[zone] online on UDP %d  (%d zones, %d mobs%s)" % [port, _worlds.size(), _mob_count(), "  · DTLS" if use_dtls else ""])
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
	# own map dict per world (NOT the shared GameData venue): the cover-panel rows expand into collision
	# circles here, which unlock cover/LOS/projectile-block. The client renders the panel props from World.
	w["map"] = {"id": map, "name": map, "obstacles": World.obstacle_circles(map)}
	var c := World.cfg(map)                      # per-map size + regen + aggro + pvp
	w["arenaW"] = int(c["w"])
	w["arenaH"] = int(c["h"])
	w["regen"] = float(c["regen"])
	w["regenDelay"] = float(c["regen_delay"])
	w["aggro"] = bool(c["aggro"])
	w["pvp"] = bool(c.get("pvp", false))         # open-PvP: Combat.is_hostile/is_ally consult this per world
	return w

# spawn the home training dummy + every combat zone's mob camps. Shared by boot and the admin
# Reset Mobs command so the two can't drift (a desync used to mean reset repopulated the wrong set).
func _spawn_world_actors() -> void:
	var did := _spawn_fighter(World.DUMMY_CLASS, 1, World.DUMMY_POS, World.HOME)
	var dummy = _find(did)
	if dummy != null:
		dummy["dummy"] = true
		dummy["maxHP"] = DUMMY_HP
		dummy["hp"] = DUMMY_HP
	for mapname in World.MOBS:                    # MOBS is keyed by world → spawn each zone's camps
		for m in World.MOBS[mapname]:
			var fid := _spawn_fighter(str(m["class"]), 1, Vector2(float(m["x"]), float(m["y"])), mapname)
			var f = _find(fid)
			f["mobLevel"] = int(m["level"])
			f["mobTier"] = str(m["tier"])
			_scale_mob(f)
			if GameData.CLASSES.get(str(m["class"]), {}).get("isCore", false):
				f["isCore"] = true                   # destructible power core: no loot/XP, gates the boss ult, respawns

func _mob_count() -> int:
	var n := 0
	for mapname in World.MOBS:
		n += (World.MOBS[mapname] as Array).size()
	return n

# ---- connection / auth ----
func _on_peer_connected(pid: int) -> void:
	print("[zone] peer %d connected — awaiting auth" % pid)

func _on_peer_disconnected(pid: int) -> void:
	_authing.erase(pid)
	if not _session.has(pid):
		return
	var s = _session[pid]                        # capture before erasing (the save coroutine holds it)
	if not bool(_sellmany_busy.get(pid, false)) and not bool(_forge_busy.get(pid, false)) and not bool(_vendor_busy.get(pid, false)):
		_save_one(s, _find(s["fid"]))            # an in-flight bulk-sell / upgrade / vendor-buy owns its OWN terminal
		                                         # its OWN terminal save; saving here too would race that credit
		                                         # write (a stale absolute write could clobber it). Skip it.
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
	_shop_busy.erase(pid)
	_shop_next.erase(pid)
	_sellmany_busy.erase(pid)
	_sellmany_next.erase(pid)
	_vendor_busy.erase(pid)
	_vendor_next.erase(pid)
	_lock_busy.erase(pid)
	_lock_next.erase(pid)
	_salvage_busy.erase(pid)
	_salvage_next.erase(pid)
	_forge_busy.erase(pid)
	_forge_next.erase(pid)
	_craft_busy.erase(pid)
	_craft_next.erase(pid)
	_quest_busy.erase(pid)
	_quest_next.erase(pid)
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
		"map": str(pf["map"]) if pf != null else World.HOME, "party": [], "credits": int(ch.get("credits", 0)),
		"scrap": 0, "tokens": int(ch.get("practice_tokens", 0)), "quests": {}}
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	net.assign_fighter.rpc_id(pid, fid)
	net.recv_shop_info.rpc_id(pid, {"catalog": _catalog(), "roll": ROLL_PRICE, "sell": SELL_PRICE})
	net.recv_vendor_info.rpc_id(pid, {"catalog": _token_catalog()})   # the Practice Vendor (Rookie Camp set)
	var mr = await supa.get_mats_as(access)           # load the player's salvage materials into the session
	if _session.has(pid):
		_session[pid]["scrap"] = int(mr.get("scrap", 0))
	await _apply_equipment(pid)                       # re-derive stats from saved equipment
	await _load_quests(pid)                           # load + push the player's quest progress
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
	if not GameData.CLASSES.has(cls) or GameData.is_mob(cls):   # never let a mob id spawn as a player (HUD reads c["role"])
		cls = "striker"
	var map: String = str(ch.get("last_map", World.HOME))
	if not _worlds.has(map):                       # stale/unknown map (e.g. the DB default 'stadium') → home
		map = World.HOME
	var c := World.cfg(map)
	var pos: Vector2 = World.spawn_for(map)        # safe maps (hubs) always spawn at the fixed point
	if str(c.get("type", "")) != "safe":           # combat zones resume where you logged out
		pos = Vector2(float(ch.get("last_x", pos.x)), float(ch.get("last_y", pos.y)))
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
	_mob_engaged.erase(fid)        # else summoned adds (removed on death) leak _mob_engaged entries forever

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

# a stable party key shared by all members (sorted member fids); "" = solo. Stamped on each player
# fighter every tick so the deterministic engine's is_hostile/is_ally can treat party-mates as allies
# (and everyone else as hostile) in a PvP zone.
func _party_key(pid: int) -> String:
	if not _session.has(pid):
		return ""
	var party: Array = _session[pid]["party"]
	if party.size() < 2:
		return ""
	var fids := []
	for m in party:
		if _session.has(m):
			fids.append(str(_session[m]["fid"]))
	fids.sort()
	return ",".join(fids)

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

# ---- economy (Credits): earn from kills, spend at the home-zone shop, sell inventory back ----
func _is_uuid(s: String) -> bool:
	if s.length() != 36:
		return false
	for i in s.length():
		var c := s[i]
		if i == 8 or i == 13 or i == 18 or i == 23:
			if c != "-":
				return false
		elif not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
			return false
	return true

func _mob_credits(mob) -> int:
	var base := 8 + int(mob.get("mobLevel", 1)) * 5
	var tier := str(mob.get("mobTier", ""))
	if tier == "boss":
		base *= 4
	elif tier == "elite":
		base *= 2
	return base

func _award_credits(pid: int, amt: int) -> void:
	if _session.has(pid):
		_session[pid]["credits"] = int(_session[pid]["credits"]) + amt

# Practice Tokens (Glitchyard reward loop). Awarded in-session; persistence rides the _save_one in the
# _award_xp call that follows every kill (practice_tokens is in the saved fields). Tier-scaled.
func _award_tokens(pid: int, amt: int) -> void:
	if amt > 0 and _session.has(pid):
		_session[pid]["tokens"] = int(_session[pid].get("tokens", 0)) + amt

func _mob_tokens(mob) -> int:
	var tier := str(mob.get("mobTier", "minion"))
	if tier == "boss": return 60
	if tier == "elite": return 5
	return 1

# the single item builder — loot, the shop catalog, and the gamble roll all go through this so power is
# consistent (replaces the old divergent mult*6 / mult*(qty+lvl) formulas). rng-driven (deterministic via
# _loot_rng) when picking a stat/affixes/base; pass a fixed primary_stat + base_name + with_affixes=false
# for the STABLE shop catalog (then it makes ZERO rng calls, so loot determinism is untouched). Returns
# primary_* and mirrors them to the legacy bonus_* (kept one release), plus ilvl/affixes/item_power.
func _make_item(slot: String, rarity: String, ilvl: int, primary_stat: String = "", with_affixes: bool = true, base_name: String = "") -> Dictionary:
	var mult := 1
	for r in RARITIES:
		if r["name"] == rarity:
			mult = int(r["mult"])
			break
	var lv := clampi(ilvl, 1, 80)
	var ps: String = primary_stat if primary_stat != "" else LOOT_STATS[_loot_rng.next_int(LOOT_STATS.size())]
	var pamt := int(round(mult * (3.0 + lv * 0.4)))
	var affixes := []
	if with_affixes:
		var n := int(AFFIX_COUNT_BY_RARITY.get(rarity, 0))
		if n > 0:
			var budget := int(round(mult * (1.0 + lv * 0.18)))
			if budget < n:
				budget = n                                   # guarantee at least +1 per affix
			var pool: Array = LOOT_STATS.duplicate()         # prefer affix stats distinct from the primary
			pool.erase(ps)
			for i in range(pool.size() - 1, 0, -1):          # Fisher-Yates with the deterministic loot rng
				var j: int = _loot_rng.next_int(i + 1)
				var t = pool[i]; pool[i] = pool[j]; pool[j] = t
			var each := budget / n                           # split the budget evenly, remainder to the first
			var rem := budget - each * n
			for i in n:
				var st: String = str(pool[i]) if i < pool.size() else LOOT_STATS[_loot_rng.next_int(LOOT_STATS.size())]
				var amt := each + (1 if i < rem else 0)
				if amt < 1:
					amt = 1
				affixes.append({"stat": st, "amt": amt})
	var atotal := 0
	for a in affixes:
		atotal += int(a["amt"])
	var bases: Array = LOOT_SLOTS.get(slot, ["Relic"])
	var base: String = base_name if base_name != "" else str(bases[_loot_rng.next_int(bases.size())])
	# every item belongs to a sport set (P5). The catalog path (base_name given) must stay deterministic →
	# derive the set from a hash; drops/rolls/craft (rng path) roll a random set.
	var sid: String
	if base_name != "":
		sid = GameData.SET_IDS[abs(hash(slot + rarity)) % GameData.SET_IDS.size()]
	else:
		sid = GameData.SET_IDS[_loot_rng.next_int(GameData.SET_IDS.size())]
	return {
		"name": "%s %s" % [rarity.capitalize(), base], "rarity": rarity, "slot": slot, "ilvl": lv,
		"primary_stat": ps, "primary_amt": pamt, "bonus_stat": ps, "bonus_amt": pamt,
		"affixes": affixes, "item_power": pamt + atotal + lv, "set_id": sid,
	}

# the fixed shop catalog: one CLEAN (affix-free) item per slot × shop-rarity, built deterministically so
# it stays stable across calls + the recv_shop_info push. Drops/rolls carry the affixes; the shop is the
# reliable baseline.
func _catalog() -> Array:
	var out := []
	for slot in LOOT_SLOTS:
		var bases: Array = LOOT_SLOTS[slot]
		var stat: String = str(SHOP_SLOT_STAT.get(slot, "PWR"))
		for i in SHOP_RARITIES.size():
			var rar: String = SHOP_RARITIES[i]
			var item := _make_item(slot, rar, SHOP_ILVL, stat, false, str(bases[i % bases.size()]))
			item["price"] = int(BUY_PRICE[rar])
			out.append(item)
	return out

# The Practice Vendor catalog (reward loop): the 5 EPIC Rookie Camp set pieces, bought with Practice Tokens.
# Deterministic (base_name given → _make_item draws no rng), set_id forced to "rookie_camp" (the vendor-only set).
const ROOKIE_PIECES := {"head": "Rookie Helm", "chest": "Rookie Pads", "hands": "Rookie Gloves",
	"legs": "Rookie Leggings", "trinket": "Rookie Whistle"}
const TOKEN_PRICE := 120

func _token_catalog() -> Array:
	var out := []
	for slot in ROOKIE_PIECES:
		var stat: String = str(SHOP_SLOT_STAT.get(slot, "END"))
		var item := _make_item(slot, "epic", SHOP_ILVL, stat, false, str(ROOKIE_PIECES[slot]))
		item["set_id"] = "rookie_camp"
		item["price"] = TOKEN_PRICE
		out.append(item)
	return out

func _give_and_charge(pid: int, item: Dictionary, price: int) -> void:
	var s = _session[pid]
	s["credits"] = int(s["credits"]) - price                  # deduct up front; refund if the write fails
	var r = await supa.add_item_as(s["access"], s["char_id"], item)
	if not r.get("ok"):
		s["credits"] = int(s["credits"]) + price              # refund + persist even if the peer left mid-buy
		_save_one(s, _find(s["fid"]))
		return
	_save_one(s, _find(s["fid"]))                             # success: the deduction is now durable
	if net != null and _session.has(pid):
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		net.recv_inventory_changed.rpc_id(pid)

# Practice Vendor buy — the reward-loop mirror of _give_and_charge, spending Practice Tokens. Its own dupe-
# safe lock (_vendor_lock, set BEFORE the await), deduct-before-write + refund-on-fail, persist, notify.
var _vendor_busy := {}                            # pid -> a vendor op is in flight
var _vendor_next := {}                            # pid -> earliest next vendor op (ms)

func _vendor_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_vendor_busy.get(pid, false)) or now < int(_vendor_next.get(pid, 0)):
		return false
	_vendor_busy[pid] = true
	_vendor_next[pid] = now + 300
	return true

func vendor_buy(pid: int, slot: String) -> void:
	if not _vendor_lock(pid):
		return
	await _do_vendor_buy(pid, slot)
	_vendor_busy.erase(pid)

func _do_vendor_buy(pid: int, slot: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                                # the Practice Vendor only exists in the home base
	var entry = null
	for e in _token_catalog():
		if str(e["slot"]) == slot:
			entry = e
			break
	if entry == null or int(_session[pid].get("tokens", 0)) < int(entry["price"]):
		return                                                # unknown piece or not enough tokens — no-op
	var item: Dictionary = (entry as Dictionary).duplicate()
	item.erase("price")                                       # "price" is display-only, not an inventory column
	await _give_and_charge_tokens(pid, item, int(entry["price"]))

func _give_and_charge_tokens(pid: int, item: Dictionary, price: int) -> void:
	var s = _session[pid]
	s["tokens"] = int(s.get("tokens", 0)) - price             # deduct up front; refund if the write fails
	var r = await supa.add_item_as(s["access"], s["char_id"], item)
	if not r.get("ok"):
		s["tokens"] = int(s["tokens"]) + price                # refund + persist even if the peer left mid-buy (s survives the session erase)
		_save_one(s, _find(s["fid"]))
		return
	_save_one(s, _find(s["fid"]))                             # success: the token spend is now durable
	if net != null and _session.has(pid):
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		net.recv_inventory_changed.rpc_id(pid)

# shop actions are serialized + rate-limited per peer (like equip), so a flood of RPCs can't interleave
# across the DB awaits to double-spend on a buy or get paid twice for one sell.
var _shop_busy := {}                              # pid -> a shop op is in flight
var _shop_next := {}                              # pid -> earliest next shop op (ms)

func _shop_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_shop_busy.get(pid, false)) or now < int(_shop_next.get(pid, 0)):
		return false
	_shop_busy[pid] = true
	_shop_next[pid] = now + 300
	return true

# selling and lock-toggling each get their OWN lock pair (not _shop_busy) — per the dupe-safety contract,
# a bulk-sell job must not block (nor be blocked by) a single buy/roll, and each mutating RPC owns its gate.
var _sellmany_busy := {}                          # pid -> a sell (single or bulk) is in flight
var _sellmany_next := {}                          # pid -> earliest next sell op (ms)
var _lock_busy := {}                              # pid -> a lock-toggle is in flight
var _lock_next := {}                              # pid -> earliest next lock op (ms)

func _sellmany_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_sellmany_busy.get(pid, false)) or now < int(_sellmany_next.get(pid, 0)):
		return false
	_sellmany_busy[pid] = true
	_sellmany_next[pid] = now + 300
	return true

func _setlocked_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_lock_busy.get(pid, false)) or now < int(_lock_next.get(pid, 0)):
		return false
	_lock_busy[pid] = true
	_lock_next[pid] = now + 300
	return true

# Phase 4 sinks each own their gate too (salvage = bulk gear→scrap; forge = single upgrade).
var _salvage_busy := {}                           # pid -> a salvage batch is in flight
var _salvage_next := {}
var _forge_busy := {}                             # pid -> an upgrade is in flight
var _forge_next := {}
var _craft_busy := {}                             # pid -> a craft is in flight (P5)
var _craft_next := {}

func _craft_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_craft_busy.get(pid, false)) or now < int(_craft_next.get(pid, 0)):
		return false
	_craft_busy[pid] = true
	_craft_next[pid] = now + 300
	return true

func _salvage_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_salvage_busy.get(pid, false)) or now < int(_salvage_next.get(pid, 0)):
		return false
	_salvage_busy[pid] = true
	_salvage_next[pid] = now + 300
	return true

func _forge_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_forge_busy.get(pid, false)) or now < int(_forge_next.get(pid, 0)):
		return false
	_forge_busy[pid] = true
	_forge_next[pid] = now + 300
	return true

func _rarity_mult(rarity: String) -> int:
	for r in RARITIES:
		if r["name"] == rarity:
			return int(r["mult"])
	return 1

func shop_buy(pid: int, slot: String, rarity: String) -> void:
	if not _shop_lock(pid):
		return
	await _do_shop_buy(pid, slot, rarity)
	_shop_busy.erase(pid)

func shop_roll(pid: int, rarity: String) -> void:
	if not _shop_lock(pid):
		return
	await _do_shop_roll(pid, rarity)
	_shop_busy.erase(pid)

# selling runs under its own _sellmany lock (not _shop_busy). A single sell is just a 1-element bulk sell,
# so there is ONE sell code path = one dupe surface (kept for back-compat with the old single-sell RPC).
func shop_sell(pid: int, item_id: String) -> void:
	await shop_sell_many(pid, [item_id])

func shop_sell_many(pid: int, item_ids: Array) -> void:
	if not _sellmany_lock(pid):
		return
	await _do_shop_sell_many(pid, item_ids)
	_sellmany_busy.erase(pid)

func _do_shop_buy(pid: int, slot: String, rarity: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                                # the shop only exists in the home base
	var entry = null
	for e in _catalog():
		if e["slot"] == slot and e["rarity"] == rarity:
			entry = e
			break
	if entry == null or int(_session[pid]["credits"]) < int(entry["price"]):
		return
	var item: Dictionary = (entry as Dictionary).duplicate()
	item.erase("price")                                       # "price" is display-only, not an inventory column
	await _give_and_charge(pid, item, int(entry["price"]))

func _do_shop_roll(pid: int, rarity: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME or not ROLL_PRICE.has(rarity):
		return
	if int(_session[pid]["credits"]) < int(ROLL_PRICE[rarity]):
		return
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	await _give_and_charge(pid, _make_item(slot, rarity, SHOP_ILVL), int(ROLL_PRICE[rarity]))   # rolls carry affixes

# bulk sell: ONE locked, serialized loop of atomic per-row deletes, crediting each row the instant it's
# removed, then ONE save + push. Dupe-safe by construction — see the per-row note below and the §2 contract.
func _do_shop_sell_many(pid: int, item_ids: Array) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                                # the shop only exists in the home base
	if typeof(item_ids) != TYPE_ARRAY or item_ids.size() > 200:
		return                                                # bound the work — a legit client sends ≤ 50 ids
	var s = _session[pid]
	var seen := {}                                            # sanitize: dedup, well-formed ids, cap at 50
	var ids := []
	for raw in item_ids:
		var id := str(raw)
		if _is_uuid(id) and not seen.has(id):
			seen[id] = true
			ids.append(id)
			if ids.size() >= 50:
				break
	if ids.is_empty():
		return
	var sold := 0
	for id in ids:
		# atomic delete: refuses equipped/locked IN the filter and returns the rarity ONLY to the call
		# that actually removed the row — so a duplicate/concurrent sell of the same id can't double-pay,
		# and an equipped or locked item is never removed (server-side enforcement, not just the client).
		var r = await supa.sell_item_safe_as(s["char_id"], id)
		if r.get("ok"):
			s["credits"] = int(s["credits"]) + int(SELL_PRICE.get(str(r["rarity"]), 10))  # credit on removal
			sold += 1
		if not _session.has(pid):                             # peer left mid-loop: stop removing more items
			break
	if _session.has(pid) and sold > 0:
		await _apply_equipment(pid)                           # re-derive (defensive: equipped is never sold)
	# Persist if we credited anything, OR if the peer left mid-op: _on_peer_disconnected deferred its save to
	# us (it saw _sellmany_busy), so we own persisting xp/level/credits here (single writer → no racing PATCH).
	if sold > 0 or not _session.has(pid):
		_save_one(s, _find(s["fid"]))
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# toggle an item's persistent locked flag (protects it from selling/salvage). Own lock pair; no HOME gate
# (locking is harmless anywhere, no economy effect). Ownership is scoped by character_id in the DB call.
func inv_set_locked(pid: int, item_id: String, val: bool) -> void:
	if not _setlocked_lock(pid):
		return
	await _do_set_locked(pid, item_id, val)
	_lock_busy.erase(pid)

func _do_set_locked(pid: int, item_id: String, val: bool) -> void:
	if not _session.has(pid) or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var r = await supa.inv_set_locked_as(s["access"], s["char_id"], item_id, bool(val))
	if not _session.has(pid):
		return
	if not r.get("ok"):                              # no owned row matched, or the write was rejected
		print("[zone] lock write failed for %s — is SUPABASE_SERVICE_KEY set?" % s["name"])
		return
	if net != null:
		net.recv_inventory_changed.rpc_id(pid)

# Phase 4 salvage: the bulk-sell worker, but pays SCRAP not credits. ONE locked, serialized loop of atomic
# per-row deletes (equipped/locked excluded by sell_item_safe_as), then ONE atomic mats_add. Dupe-safe.
func salvage_many(pid: int, item_ids: Array) -> void:
	if not _salvage_lock(pid):
		return
	await _do_salvage_many(pid, item_ids)
	_salvage_busy.erase(pid)

func _do_salvage_many(pid: int, item_ids: Array) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                                # the forge lives in the home base
	if typeof(item_ids) != TYPE_ARRAY or item_ids.size() > 200:
		return
	var s = _session[pid]
	var seen := {}
	var ids := []
	for raw in item_ids:
		var id := str(raw)
		if _is_uuid(id) and not seen.has(id):
			seen[id] = true
			ids.append(id)
			if ids.size() >= 50:
				break
	if ids.is_empty():
		return
	for id in ids:
		var r = await supa.sell_item_safe_as(s["char_id"], id)   # same atomic delete → no double-yield
		if r.get("ok"):
			# credit THIS item's scrap immediately (atomic), so a transient credit failure can lose at most
			# ONE item's yield — never the whole batch — and it lands in the DB even if the peer has left.
			var mr = await supa.mats_add_as(s["char_id"], int(SALVAGE_YIELD.get(str(r["rarity"]), 1)))
			if mr.get("ok") and _session.has(pid):
				s["scrap"] = int(mr["total"])
		if not _session.has(pid):                             # peer left mid-loop: stop removing more items
			break
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# Phase 4 upgrade: +1 upgrade level on an item (raises its per-item cap; aggregate still bounded by
# EQUIP_STAT_CAP). Cost = credits + scrap, escalating by level × rarity. Deduct-before-write, refund on
# failure; atomic PATCH gated on the old upgrade_level so a duplicate/concurrent call can't double-apply.
func forge_upgrade(pid: int, item_id: String) -> void:
	if not _forge_lock(pid):
		return
	await _do_forge_upgrade(pid, item_id)
	_forge_busy.erase(pid)

func _do_forge_upgrade(pid: int, item_id: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var inv = await supa.get_inventory_as(s["access"])
	if not _session.has(pid):                                # peer left during the read (nothing spent yet);
		_save_one(s, _find(s["fid"]))                        # the disconnect handler deferred its save to us
		return
	if not inv.get("ok"):
		return
	var item = null
	for it in inv["items"]:
		if str(it["id"]) == item_id:
			item = it
			break
	if item == null:
		return
	var rarity := str(item.get("rarity", "common"))
	var lvl := int(item.get("upgrade_level", 0))
	if lvl >= MAX_UPGRADE:
		return
	var credit_cost := _rarity_mult(rarity) * 25 * (lvl + 1)
	var scrap_cost := _rarity_mult(rarity) * (lvl + 1)
	if int(s["credits"]) < credit_cost:
		return
	var mr = await supa.mats_add_as(s["char_id"], -scrap_cost)   # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return                                                  # nothing was spent → safe to bail
	# Do NOT bail here if the peer left: scrap is already committed to the DB, so we must run the
	# upgrade-or-refund flow below (it uses the captured char_id + session dict, not a live connection).
	s["scrap"] = int(mr["total"])
	s["credits"] = int(s["credits"]) - credit_cost              # deduct credits before the write
	var new_ip := int(item.get("item_power", 0)) + UPGRADE_STEP
	var r = await supa.inv_upgrade_as(s["char_id"], item_id, lvl, lvl + 1, new_ip)
	if not r.get("ok"):                                         # write lost the race / item gone → refund both
		s["credits"] = int(s["credits"]) + credit_cost
		var rb = await supa.mats_add_as(s["char_id"], scrap_cost)
		if rb.get("ok"):
			s["scrap"] = int(rb["total"])
		_save_one(s, _find(s["fid"]))                          # persist the refund (even if the peer left)
		return
	_save_one(s, _find(s["fid"]))                              # success: persist the spend (paid even if peer left)
	if _session.has(pid):
		await _apply_equipment(pid)                            # the item may be equipped → raised cap applies
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# Phase 4b reforge: reroll an item's affixes for credits + scrap (escalating by reforge_count). Shares the
# _forge lock with upgrade (same op class → mutually exclusive per player). Same deduct-before-write /
# refund-on-fail / atomic-gated-PATCH / disconnect-reconcile shape as forge_upgrade.
func forge_reforge(pid: int, item_id: String) -> void:
	if not _forge_lock(pid):
		return
	await _do_forge_reforge(pid, item_id)
	_forge_busy.erase(pid)

func _do_forge_reforge(pid: int, item_id: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var inv = await supa.get_inventory_as(s["access"])
	if not _session.has(pid):                                  # peer left during the read (nothing spent yet)
		_save_one(s, _find(s["fid"]))
		return
	if not inv.get("ok"):
		return
	var item = null
	for it in inv["items"]:
		if str(it["id"]) == item_id:
			item = it
			break
	if item == null:
		return
	var rarity := str(item.get("rarity", "common"))
	if int(AFFIX_COUNT_BY_RARITY.get(rarity, 0)) <= 0:
		return                                                # common items have no affixes → nothing to reroll
	var rc := int(item.get("reforge_count", 0))
	var credit_cost := _rarity_mult(rarity) * 30 * (rc + 1)
	var scrap_cost := _rarity_mult(rarity) * 2 * (rc + 1)
	if int(s["credits"]) < credit_cost:
		return
	var mr = await supa.mats_add_as(s["char_id"], -scrap_cost)   # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return                                                # nothing spent → safe to bail
	s["scrap"] = int(mr["total"])
	s["credits"] = int(s["credits"]) - credit_cost
	# reroll affixes, KEEPING the existing primary: roll a fresh item of the same slot/rarity/ilvl (its
	# affixes exclude the given primary) and take just its affixes; recompute item_power from the kept primary.
	var ilvl := int(item.get("ilvl", 1))
	var rolled := _make_item(str(item.get("slot", "trinket")), rarity, ilvl, str(item.get("primary_stat", "")))
	var new_affixes: Array = rolled.get("affixes", [])
	var atot := 0
	for a in new_affixes:
		atot += int(a.get("amt", 0))
	var new_ip := int(item.get("primary_amt", 0)) + atot + ilvl
	var r = await supa.inv_reforge_as(s["char_id"], item_id, rc, rc + 1, new_affixes, new_ip)
	if not r.get("ok"):                                        # lost the race / item gone → refund both
		s["credits"] = int(s["credits"]) + credit_cost
		var rb = await supa.mats_add_as(s["char_id"], scrap_cost)
		if rb.get("ok"):
			s["scrap"] = int(rb["total"])
		_save_one(s, _find(s["fid"]))
		return
	_save_one(s, _find(s["fid"]))                             # success: persist the spend (paid even if peer left)
	if _session.has(pid):
		await _apply_equipment(pid)                           # equipped item → new affixes apply (still capped)
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# Phase 5 craft: spend scrap → a random item of the recipe's rarity (a scrap sink + gear faucet). Spend
# (atomic) BEFORE the insert, refund on failure — mirrors _give_and_charge but with scrap, not credits.
func craft(pid: int, recipe_id: String) -> void:
	if not _craft_lock(pid):
		return
	await _do_craft(pid, recipe_id)
	_craft_busy.erase(pid)

func _do_craft(pid: int, recipe_id: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                                # crafting happens at the home forge
	var recipe = null
	for r in GameData.RECIPES:
		if str(r["id"]) == recipe_id:
			recipe = r
			break
	if recipe == null:
		return
	var s = _session[pid]
	var cost := int(recipe["scrap"])
	var mr = await supa.mats_add_as(s["char_id"], -cost)      # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return
	if _session.has(pid):
		s["scrap"] = int(mr["total"])
	var item: Dictionary
	if bool(recipe.get("unique", false)):                    # forge_unique → a random unique (P6)
		item = _make_unique(GameData.UNIQUE_IDS[_loot_rng.next_int(GameData.UNIQUE_IDS.size())], int(recipe.get("ilvl", SHOP_ILVL)))
	else:
		var slot: String = (LOOT_SLOTS.keys())[_loot_rng.next_int(LOOT_SLOTS.size())]
		item = _make_item(slot, str(recipe["rarity"]), int(recipe.get("ilvl", SHOP_ILVL)))
	if item.is_empty():                                      # unknown unique def → refund + bail
		var rfb = await supa.mats_add_as(s["char_id"], cost)
		if rfb.get("ok") and _session.has(pid):
			s["scrap"] = int(rfb["total"])
		return
	var ar = await supa.add_item_as(s["access"], s["char_id"], item)
	if not ar.get("ok"):                                      # insert failed → refund the scrap
		var rb = await supa.mats_add_as(s["char_id"], cost)
		if rb.get("ok") and _session.has(pid):
			s["scrap"] = int(rb["total"])
		return
	if net != null and _session.has(pid):
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		net.recv_inventory_changed.rpc_id(pid)

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
	var work_t0 := Time.get_ticks_usec()         # measure the server's compute this frame (CPU signal)
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
	_tick_us_peak = maxi(_tick_us_peak, int(Time.get_ticks_usec() - work_t0))
	_health_t += delta
	if _health_t >= HEALTH_INTERVAL:
		_health_t = 0.0
		_health_log()

# Once a minute: players + the two signals that decide an upgrade — CPU (host 1-min load average +
# peak per-frame compute vs the 33ms tick budget) and RAM (host free + this server's footprint), read
# from /proc (the server runs on Linux/Docker; reads no-op gracefully off-Linux). Read the log with
# `docker logs -f legends-zone | grep health`. RAM tight (free_ram low) → more RAM; load near/over 1.00
# or peak_tick near 33ms while players are on → more vCPU (or shard zones).
func _health_log() -> void:
	var players := _peers.size()
	var counts := []
	for mapname in _worlds:
		var np := 0
		for f in _worlds[mapname]["fighters"]:
			if f["team"] == 0:
				np += 1
		if np > 0:
			counts.append("%s:%d" % [mapname, np])
	var zones: String = " ".join(counts) if not counts.is_empty() else "-"
	var load := _proc_first_token("/proc/loadavg")
	var free_mb := _proc_kb("/proc/meminfo", "MemAvailable:") / 1024
	var rss_mb := _proc_kb("/proc/self/status", "VmRSS:") / 1024
	print("[health] players=%d [%s]  load=%s (1 vCPU)  peak_tick=%.1fms/33ms  free_ram=%dMB  server_rss=%dMB" % [
		players, zones, load, _tick_us_peak / 1000.0, free_mb, rss_mb])
	_tick_us_peak = 0

func _proc_first_token(path: String) -> String:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	var line := f.get_line()
	f.close()
	var parts := line.split(" ", false)
	return parts[0] if parts.size() > 0 else "?"

func _proc_kb(path: String, key: String) -> int:                  # value (kB) of a "Key:  N kB" line
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	# /proc files report length 0, so read line-by-line (get_as_text reads `length` bytes → empty)
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with(key):
			var nums := line.replace("\t", " ").split(" ", false)
			for i in range(1, nums.size()):
				if nums[i].is_valid_int():
					f.close()
					return int(nums[i])
	f.close()
	return 0

func _tick_world(w: Dictionary, mapname: String) -> void:
	_update_mob_ai(w)                             # aggro / leash before the sim resolves actions
	w["winner"] = null
	w["controlled"] = {}
	for pid in _peers:
		if str(_session[pid].get("map", World.HOME)) != mapname:
			continue
		var fid: String = _session[pid]["fid"]
		var pfr = _find(fid)
		if pfr != null:
			pfr["party"] = _party_key(pid)            # party-aware PvP hostility (read by Sim.sim_tick below)
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
	_consume_summons(w, mapname)                  # spawn any adds the sim requested this tick (summon bridge)
	_apply_regen(w)                               # out-of-combat health regen (rate/delay per map type)
	for f in w["fighters"]:                       # queue the dead for respawn (dummy instant; mobs slower than players)
		if not f["alive"] and not _respawn.has(f["id"]):
			if f.get("dummy", false):
				_respawn[f["id"]] = 0.0
			elif f["team"] == 1:
				# the boss is a rare ~30-min event; its cones/cores + normal mobs churn at the usual rate
				_respawn[f["id"]] = BOSS_RESPAWN_DELAY if GameData.CLASSES.get(str(f["classId"]), {}).get("phased", false) else MOB_RESPAWN_DELAY
			else:
				_respawn[f["id"]] = RESPAWN_DELAY

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
		var f = _find(id)
		if f == null:
			continue
		if f.get("isAdd", false):                      # summoned adds despawn — they never respawn
			_remove_fighter(id)
			continue
		if f["team"] == 0 and bool(_worlds.get(str(f["map"]), {}).get("pvp", false)):
			var s = _session_by_fid(id)               # died in a PvP zone → respawn at the home safe zone
			if s != null:
				_relocate(f, s, World.HOME, World.HOME_SPAWN)
		_revive(f)

# Summon bridge: the sim emits {type:"summon",...} events; the server spawns the adds (it owns fighter
# lifecycle). Adds are tagged isAdd (never respawn — removed on death in _advance_respawns) + summoner, give
# no loot/XP (anti-farm, see _award_kills), and are capped at SUMMON_CAP live per summoner (anti-snowball).
func _consume_summons(w: Dictionary, mapname: String) -> void:
	if w["events"].is_empty():
		return
	var had_summon := false
	for ev in w["events"]:
		if ev.get("type") != "summon":
			continue
		had_summon = true
		var owner = _find(str(ev.get("owner", "")))
		if owner == null or not owner["alive"] or str(owner.get("map", "")) != mapname:
			continue
		var mob_type := str(ev.get("mobType", ""))
		if not GameData.CLASSES.has(mob_type) or not GameData.is_mob(mob_type):
			continue
		var live := 0
		for f in w["fighters"]:
			if str(f.get("summoner", "")) == owner["id"] and f["alive"]:
				live += 1
		var want: int = clampi(int(ev.get("count", 1)), 0, maxi(0, SUMMON_CAP - live))
		for i in want:
			var ang: float = TAU * (float(i) + 0.5) / float(maxi(1, want)) + float(live) * 0.7
			var pos := Vector2(float(ev["x"]) + cos(ang) * ADD_SPAWN_R, float(ev["y"]) + sin(ang) * ADD_SPAWN_R)
			var aid := _spawn_fighter(mob_type, 1, pos, mapname)
			var add = _find(aid)
			if add == null:
				continue
			add["summoner"] = owner["id"]
			add["isAdd"] = true
			add["mobLevel"] = maxi(1, int(owner.get("mobLevel", 1)) - 1)
			add["mobTier"] = "minion"
			_scale_mob(add)
	if had_summon:                # drop consumed summon events so the multi-sim-step catch-up loop (up to
		var kept := []            # 5 _tick_world calls/frame, events not cleared until _broadcast) can't re-spawn them
		for ev in w["events"]:
			if ev.get("type") != "summon":
				kept.append(ev)
		w["events"] = kept

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
				if portal.has("gate") and not _portal_unlocked(pid, str(portal["gate"])):
					continue                          # gated + locked (e.g. the secret boss) — no teleport (it's also hidden in the snapshot)
				_portal_teleport(f, s, portal)
				_tp_next[f["id"]] = now + TP_GRACE_MS
				break

# A character UNLOCKS a gated portal (the secret boss) by completing EVERY Glitchyard quest — the chain ends
# with headcoach_down (= beating Boss1), so "all quests done" means "all quests AND Boss1 beaten".
func _all_quests_done(pid: int) -> bool:
	if not _session.has(pid):
		return false
	var q: Dictionary = _session[pid].get("quests", {})
	for qid in Quests.ORDER:
		if not bool((q.get(qid, {}) as Dictionary).get("completed", false)):
			return false
	return true

func _portal_unlocked(pid: int, gate: String) -> bool:
	if gate == "all_quests":
		return _all_quests_done(pid)
	return true

# per-player portal list for the snapshot: gated portals the player hasn't unlocked are HIDDEN (the secret
# zone's entrance doesn't render until you've earned it).
func _portals_for_player(map: String, pid: int) -> Array:
	var out := []
	for p in World.PORTALS.get(map, []):
		if p.has("gate") and not _portal_unlocked(pid, str(p["gate"])):
			continue
		out.append({"x": p["x"], "y": p["y"], "label": p["label"]})
	return out

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
				f["phase"] = 0                                  # boss: a leashed boss re-runs its phases + re-fires threshold summons on the next pull
				f["_threshSummoned"] = {}
				f["casting"] = null                             # drop any in-progress ult telegraph (else a leashed boss shows a phantom Full Camp Reset countdown)
	w["frozenIds"] = frozen

func _award_kills() -> void:
	for mapname in _worlds:
		for ev in _worlds[mapname]["events"]:
			if ev.get("type") != "kill":
				continue
			var victim = _find(ev["victim"])
			if victim == null or victim["team"] != 1 or victim.get("dummy", false) or victim.get("isAdd", false) or victim.get("isCore", false):  # mobs only; not the dummy, summoned adds, or power cores (anti-farm)
				continue
			var gy := str(mapname).begins_with("glitchyard")   # the reward loop: Practice Tokens drop in the Glitchyard
			for pid in _peers:
				if _session[pid]["fid"] == ev["killer"]:
					_award_credits(pid, _mob_credits(victim))   # credits before xp's save persists both
					if gy:
						_award_tokens(pid, _mob_tokens(victim))
					_award_xp(pid, _mob_xp(victim))
					_grant_loot(pid, victim)
					_quest_on_kill(pid, victim)             # advance any matching kill-quest
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
	f["dots"] = []                                # P6: clear lingering DOTs / proc cooldowns on respawn
	f["_procT"] = {}
	f["_procDmg"] = 0.0
	f["_procWin"] = 1.0
	if f.get("dummy", false):                     # training dummy: fixed HP, no scaling
		f["maxHP"] = DUMMY_HP
		f["hp"] = DUMMY_HP
	elif f["team"] == 0:                          # re-derive from base stats + level + equipped gear
		var s = _session_by_fid(orig_id)
		if s != null:
			_recompute_player_stats(f, int(s["level"]), s.get("equip_bonus", {}))
			f["procs"] = s.get("procs", [])       # P6: re-apply equipped procs (the fresh copy wiped them)
	elif f["team"] == 1:                          # re-apply mob level/tier scaling
		_scale_mob(f)

func _scale_mob(f) -> void:
	var lvl := int(f.get("mobLevel", 1))
	var tier := str(f.get("mobTier", "minion"))
	var hp_t := MOB_BOSS_HP if tier == "boss" else (MOB_ELITE_HP if tier == "elite" else 1.0)
	var dmg_t := MOB_BOSS_DMG if tier == "boss" else (MOB_ELITE_DMG if tier == "elite" else 1.0)
	var hp_s := MOB_HP_SCALE * (1.0 + (lvl - 1) * 0.3) * hp_t
	var dmg_s := MOB_DMG_SCALE * (1.0 + (lvl - 1) * 0.2) * dmg_t
	var bdef: Dictionary = GameData.CLASSES.get(str(f["classId"]), {})
	f["maxHP"] = f["maxHP"] * hp_s * float(bdef.get("hpMult", 1.0))   # per-boss HP multiplier (the secret raid boss)
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s * float(bdef.get("dmgScale", 1.0))   # per-boss damage multiplier (the secret raid boss is tuned for a long survivable fight)

func _mob_xp(mob) -> int:
	var lvl := int(mob.get("mobLevel", 1))
	var tier := str(mob.get("mobTier", "minion"))
	var mult := MOB_BOSS_XP if tier == "boss" else (MOB_ELITE_XP if tier == "elite" else 1)
	return MOB_XP_BASE * lvl * mult

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
	var tier := str(mob.get("mobTier", "minion"))
	var lvl := int(mob.get("mobLevel", 1))
	var chance := 1.0 if tier != "minion" else 0.65    # elites and bosses always drop
	if _loot_rng.next() > chance:
		return {}
	var rar := _roll_rarity(tier)
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	var tbonus := 12 if tier == "boss" else (5 if tier == "elite" else 0)   # drop ilvl = mob level + tier
	var ilvl := clampi(lvl + tbonus, 1, 80)
	if tier == "boss" and _loot_rng.next() < UNIQUE_DROP_CHANCE:             # bosses rarely drop a UNIQUE instead
		return _make_unique(GameData.UNIQUE_IDS[_loot_rng.next_int(GameData.UNIQUE_IDS.size())], ilvl)
	return _make_item(slot, str(rar["name"]), ilvl)

# build a unique: epic-tier stats (RARITY_CAP-bound — identity is the PROC, not bigger numbers) stamped with
# the unique's fixed name + signature proc + a small proc_tier roll. Dropped by bosses or crafted.
func _make_unique(unique_id: String, ilvl: int) -> Dictionary:
	var ud = GameData.UNIQUE_DEFS.get(unique_id, null)
	if ud == null:
		return {}
	var item := _make_item(str(ud["slot"]), "epic", ilvl)
	item["name"] = str(ud["name"])
	item["unique_id"] = unique_id
	item["proc_id"] = str(ud["proc_id"])
	item["proc_tier"] = _loot_rng.next_int(3)                                # 0..2
	return item

func _roll_rarity(tier: String) -> Dictionary:
	var total := 0.0
	for r in RARITIES:
		total += float(r["weight"])
	var roll: float = _loot_rng.next() * total
	var acc := 0.0
	var idx := 0
	for i in RARITIES.size():
		acc += float(RARITIES[i]["weight"])
		if roll < acc:
			idx = i
			break
	# tiers bump the rolled rarity up (bosses floor at epic) WITHOUT auto-granting the top tier — the
	# upper tail must still roll, so legendary/mythic stay special even on bosses.
	if tier == "boss":
		idx = clampi(idx + 2, 3, RARITIES.size() - 1)  # floor at epic (index 3)
	elif tier == "elite":
		idx = clampi(idx + 1, 0, RARITIES.size() - 1)
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
		var cap_n := int(SLOT_CAP.get(islot, 1))     # most slots hold 1; rings hold 2
		var ok: bool
		if bool(item["equipped"]):                   # toggle OFF: unequip this item
			ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq." + item_id, false)).get("ok"))
		else:                                        # toggle ON: equip it FIRST, then trim the slot to capacity
			ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq." + item_id, true)).get("ok"))
			var trim_ok := true                      # a failed trim could strand >cap equipped in the DB
			if ok and cap_n <= 1:                    # 1-per-slot: clear every other item in this slot
				trim_ok = bool((await supa.inv_set_equipped_as(s["access"], "character_id=eq.%s&slot=eq.%s&id=neq.%s" % [s["char_id"], islot, item_id], false)).get("ok"))
			elif ok:                                 # multi (rings): keep the newest cap_n-1 OTHERS, unequip older excess
				var others := []                     # from the pre-toggle read: other equipped items of this slot
				for it2 in inv["items"]:
					if str(it2["slot"]) == islot and bool(it2["equipped"]) and str(it2["id"]) != item_id:
						others.append(it2)
				others.sort_custom(func(a, b): return str(a.get("created_at", "")) > str(b.get("created_at", "")))  # newest first
				for i in range(cap_n - 1, others.size()):
					trim_ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq." + str(others[i]["id"]), false)).get("ok")) and trim_ok
			if ok and not trim_ok:                   # equip stuck but a trim write failed → DB may hold >cap equipped
				print("[zone] equip slot-trim failed for %s (%s) — equipped set may exceed capacity until the next toggle" % [s["name"], islot])
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
	var used := {}                                       # slot -> how many equipped items of it we've counted
	var ip_total := 0                                    # gear score = sum of counted equipped items' item_power
	var set_counts := {}                                 # set_id -> equipped EPIC+ piece count (for set bonuses)
	var procs := []                                      # P6: this fighter's active procs (from equipped uniques)
	for it in inv["items"]:
		if not bool(it["equipped"]):
			continue
		var slot := str(it["slot"])
		var cap_n := int(SLOT_CAP.get(slot, 1))          # respect the per-slot equip capacity (rings: 2)
		var n := int(used.get(slot, 0))
		if n >= cap_n:                                   # defensive: ignore any extras beyond capacity
			continue
		ip_total += int(it.get("item_power", 0))
		used[slot] = n + 1
		var procidv = it.get("proc_id")                  # P6: an equipped unique contributes its signature proc
		var procid: String = "" if procidv == null else str(procidv)
		if procid != "" and GameData.PROC_CATALOG.has(procid):
			var pdef = GameData.PROC_CATALOG[procid]
			var pamt2: float = GameData.proc_amt(procid, int(it.get("proc_tier", 0)))
			var dup := false                             # dedup by proc id (two copies of one unique don't stack
			for ep in procs:                             # the effect — esp. zero-icd lifesteal); keep the higher tier
				if str(ep["id"]) == procid:
					dup = true
					if pamt2 > float(ep["amt"]):
						ep["amt"] = pamt2
					break
			if not dup:
				procs.append({"id": procid, "effect": str(pdef["effect"]), "trigger": str(pdef["trigger"]),
					"amt": pamt2, "icd": float(pdef.get("icd", 0.0)), "dur": float(pdef.get("dur", 3.0))})
		if int(RARITY_RANK.get(str(it.get("rarity", "common")), 0)) >= SET_MIN_RANK:  # only EPIC+ count
			var sid := str(it.get("set_id", ""))
			if sid != "":
				set_counts[sid] = int(set_counts.get(sid, 0)) + 1
		var rcap := int(RARITY_CAP.get(str(it.get("rarity", "common")), 4))
		rcap = min(rcap + int(it.get("upgrade_level", 0)) * UPGRADE_STEP, ABS_CAP)   # P4: upgrades raise this item's cap
		# primary stat (fall back to the legacy bonus_* for pre-P2 / quest-reward items). Coerce JSON null
		# to "" — a nullable column comes back as null, and str(null) is "<null>", which would defeat the fallback.
		var psv = it.get("primary_stat")
		var ps: String = "" if psv == null else str(psv)
		if ps == "":
			var bsv = it.get("bonus_stat")
			ps = "" if bsv == null else str(bsv)
		var pa := int(it.get("primary_amt", 0))
		if pa == 0:
			pa = int(it.get("bonus_amt", 0))
		if ps != "":
			bonus[ps] = int(bonus.get(ps, 0)) + min(pa, rcap)            # primary capped independently
		var affs = it.get("affixes", [])                                 # each affix capped independently too
		if affs is Array:
			for a in affs:
				if typeof(a) != TYPE_DICTIONARY:
					continue
				var ast := str(a.get("stat", ""))
				if ast != "":
					bonus[ast] = int(bonus.get(ast, 0)) + min(int(a.get("amt", 0)), rcap)
	for st in bonus.keys():                              # aggregate per-stat ceiling — the equipment balance bound
		bonus[st] = min(int(bonus[st]), EQUIP_STAT_CAP)
	# set bonuses (P5): stack ABOVE the EQUIP_STAT_CAP, capped by SET_BONUS_CAP, from EPIC+ pieces only.
	var set_active := {}                                 # set_id -> {count, bonus} for the character sheet
	for sid in set_counts:
		var sd = GameData.SET_DEFS.get(sid, null)
		if sd == null:
			continue
		var cnt := int(set_counts[sid])
		var sb := _set_bonus(sd, cnt)
		if sb > 0:
			var st := str(sd["stat"])
			bonus[st] = int(bonus.get(st, 0)) + sb
		set_active[sid] = {"count": cnt, "bonus": sb, "stat": str(sd["stat"])}
	_session[pid]["equip_bonus"] = bonus                 # cache for fast re-apply on respawn
	_session[pid]["item_power"] = ip_total               # gear score for the character sheet (P3)
	_session[pid]["set_bonus"] = set_active              # active set bonuses for the character sheet (P5)
	_session[pid]["procs"] = procs                       # P6: active procs, cached for re-apply on respawn
	var pf2 = _find(_session[pid]["fid"])
	if pf2 != null:
		pf2["procs"] = procs                             # the fighter reads this in Combat._resolve_procs
	_recompute_player_stats(pf2, int(_session[pid]["level"]), bonus)

# the highest set threshold this piece-count reaches → its stat bonus (capped by SET_BONUS_CAP)
func _set_bonus(sd: Dictionary, cnt: int) -> int:
	var best := 0
	for k in sd.get("th", {}):
		if cnt >= int(k):
			best = max(best, int(sd["th"][k]))
	return min(best, SET_BONUS_CAP)

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

# ---- quests (server-authoritative kill-quest progress; see shared/Quests.gd) ----
var _quest_busy := {}                             # pid -> a quest accept/turn-in is in flight
var _quest_next := {}                             # pid -> earliest next quest op (ms)

# load this character's quest progress from the DB into the session, then push the full state.
func _load_quests(pid: int) -> void:
	if not _session.has(pid):
		return
	var r = await supa.get_quests_as(_session[pid]["access"])
	if not _session.has(pid):
		return
	var q := {}
	if r.get("ok"):
		for row in r["items"]:
			q[str(row["quest_id"])] = {"progress": int(row.get("progress", 0)),
				"completed": bool(row.get("completed", false)), "rewarded": bool(row.get("rewarded", false))}
	_session[pid]["quests"] = q
	if net != null:
		net.recv_quest_state.rpc_id(pid, q.duplicate(true))
	for qid in q:                                  # recover a turn-in whose reward didn't fully grant (disconnect)
		if bool(q[qid].get("completed", false)) and not bool(q[qid].get("rewarded", false)):
			await _grant_quest_rewards(pid, qid)

# upsert one quest row. Fire-and-forget from _quest_on_kill: the progress/completed values are read
# before the await, so a mid-write disconnect still persists the right numbers.
func _persist_quest(pid: int, qid: String) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	var st = s["quests"].get(qid)
	if st == null:
		return
	await supa.quest_progress_as(s["char_id"], qid, int(st["progress"]))   # progress only — never clobbers completed/rewarded

# advance any active kill-quest whose objective matches the slain mob. Called from _award_kills in
# the same tick (before events are cleared), once per (killer, victim).
func _quest_on_kill(pid: int, victim) -> void:
	if not _session.has(pid):
		return
	var qs: Dictionary = _session[pid]["quests"]
	var v := {"tier": str(victim.get("mobTier", "minion")), "map": str(victim.get("map", "")),
		"class": str(victim.get("classId", "")), "level": int(victim.get("mobLevel", 1))}
	for qid in qs:
		var st = qs[qid]
		if bool(st.get("completed", false)):
			continue
		var quest = Quests.get_quest(qid)
		if quest == null:
			continue
		var count := int(quest["objective"]["count"])
		if int(st["progress"]) >= count:              # already ready to turn in
			continue
		if not Quests.kill_matches(quest, v):
			continue
		st["progress"] = int(st["progress"]) + 1
		_persist_quest(pid, qid)                      # fire-and-forget DB save (like _grant_loot)
		if net != null:
			net.recv_quest_update.rpc_id(pid, qid, int(st["progress"]), bool(st["completed"]))

# accept / turn-in are mutating + DB-backed → rate-limited AND serialized (mirrors the shop), so a
# flood of RPCs can't interleave across the awaits to double-grant a turn-in reward.
func _quest_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_quest_busy.get(pid, false)) or now < int(_quest_next.get(pid, 0)):
		return false
	_quest_busy[pid] = true
	_quest_next[pid] = now + 300
	return true

# quests are accepted / turned in only at the quest giver in the home base (an NPC interaction),
# re-validated server-side: in HOME and within QUESTGIVER_RADIUS of the giver. (Reward RECOVERY on
# reconnect goes through _grant_quest_rewards directly and is NOT gated by this.)
func _at_questgiver(pid: int) -> bool:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return false
	var f = _find(_session[pid]["fid"])
	if f == null:
		return false
	return Vector2(f["x"] - World.QUESTGIVER_POS.x, f["y"] - World.QUESTGIVER_POS.y).length() <= World.QUESTGIVER_RADIUS

func quest_action(pid: int, action: String, qid: String) -> void:
	if not _quest_lock(pid):
		return
	if not _at_questgiver(pid):                    # must be standing at the home-base quest giver
		_quest_busy.erase(pid)
		return
	if action == "accept":
		await _do_quest_accept(pid, qid)
	elif action == "turnin":
		await _do_quest_turnin(pid, qid)
	_quest_busy.erase(pid)

func _do_quest_accept(pid: int, qid: String) -> void:
	if not _session.has(pid):
		return
	var quest = Quests.get_quest(qid)
	if quest == null:
		return
	var s = _session[pid]
	var qs: Dictionary = s["quests"]
	if qs.has(qid):                                       # already accepted (active or completed)
		return
	if int(s["level"]) < int(quest.get("min_level", 1)):
		return
	var prereq := str(quest.get("prereq", ""))
	if prereq != "" and not (qs.has(prereq) and bool(qs[prereq].get("completed", false))):
		return                                            # prerequisite not completed
	qs[qid] = {"progress": 0, "completed": false, "rewarded": false}   # optimistic in memory; persist next
	var wr = await supa.quest_save_as(s["char_id"], qid, 0, false, false)
	if not _session.has(pid):
		return
	if not wr.get("ok"):                                  # write failed → roll back so it can be retried
		(s["quests"] as Dictionary).erase(qid)
		return
	if net != null:
		net.recv_quest_update.rpc_id(pid, qid, 0, false)
	print("[quest] %s accepted '%s'" % [s["name"], qid])

func _do_quest_turnin(pid: int, qid: String) -> void:
	if not _session.has(pid):
		return
	var quest = Quests.get_quest(qid)
	if quest == null:
		return
	var s = _session[pid]
	var qs: Dictionary = s["quests"]
	var st = qs.get(qid)
	if st == null or bool(st.get("completed", false)):    # not active / already turned in
		return
	if int(st["progress"]) < int(quest["objective"]["count"]):
		return                                            # objective not finished
	st["completed"] = true                                # set BEFORE the await; blocks re-entry this session
	var wr = await supa.quest_save_as(s["char_id"], qid, int(st["progress"]), true, false)
	if not _session.has(pid):
		return                                            # completed durable → reconnect recovery grants it
	if not wr.get("ok"):                                  # not durable → roll back, grant nothing (no dupe)
		st["completed"] = false
		return
	await _grant_quest_rewards(pid, qid)
	print("[quest] %s turned in '%s'" % [s["name"], qid])

# grant a completed quest's rewards exactly once (turn-in OR reconnect recovery). rewarded=true is
# persisted BEFORE granting, so a re-grant can never double-pay; the item write uses char_id so it
# still lands if the peer drops. A grant that partially completes on disconnect is a rare loss, never
# a dupe — recovery only fires while rewarded is still false.
func _grant_quest_rewards(pid: int, qid: String) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	var st = s["quests"].get(qid)
	if st == null or not bool(st.get("completed", false)) or bool(st.get("rewarded", false)):
		return
	var quest = Quests.get_quest(qid)
	if quest == null:
		return
	var char_id := str(s["char_id"])
	var access := str(s["access"])
	st["rewarded"] = true
	var wr = await supa.quest_save_as(char_id, qid, int(st["progress"]), true, true)
	if not wr.get("ok"):                                  # not durable → let recovery retry on next login
		if _session.has(pid):
			st["rewarded"] = false
		return
	var rw: Dictionary = quest.get("rewards", {})
	if rw.has("item"):                                    # item first: service-role write, survives a disconnect
		await _grant_quest_item(pid, char_id, access, rw["item"])
	if _session.has(pid):                                 # xp/credits live in the session → only while connected
		if int(rw.get("credits", 0)) > 0:
			_award_credits(pid, int(rw["credits"]))
			_save_one(_session[pid], _find(_session[pid]["fid"]))
		if int(rw.get("tokens", 0)) > 0:                  # reward loop: quest turn-ins grant Practice Tokens
			_award_tokens(pid, int(rw["tokens"]))
			_save_one(_session[pid], _find(_session[pid]["fid"]))
		if int(rw.get("xp", 0)) > 0:
			_award_xp(pid, int(rw["xp"]))
		if net != null:
			net.recv_quest_update.rpc_id(pid, qid, int(st["progress"]), true)

func _grant_quest_item(pid: int, char_id: String, access: String, item: Dictionary) -> void:
	var it := item.duplicate()                             # quest defs are legacy-shaped {bonus_*}; fill the deep model
	if str(it.get("primary_stat", "")) == "":
		it["primary_stat"] = str(it.get("bonus_stat", ""))
	if int(it.get("primary_amt", 0)) == 0:
		it["primary_amt"] = int(it.get("bonus_amt", 0))
	if int(it.get("ilvl", 0)) == 0:
		it["ilvl"] = 1
	if int(it.get("item_power", 0)) == 0:
		it["item_power"] = int(it["primary_amt"]) + int(it["ilvl"])
	var r = await supa.add_item_as(access, char_id, it)     # service-role write; no live session required
	item = it                                              # so the recv_loot below reads the normalized dict
	if r.get("ok") and _session.has(pid) and net != null:
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		net.recv_inventory_changed.rpc_id(pid)

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
		"add_credits":
			s["credits"] = int(s["credits"]) + int(args.get("amt", 500))
			_save_one(s, f)
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
		"goto":
			var m := str(args.get("map", ""))
			if _worlds.has(m):
				_relocate(f, s, m, World.spawn_for(m))
		"spawn_mob":
			var scls := str(args.get("class", "tackle_brute"))      # parameterized: spawn/test any (mob or class) id
			if not GameData.CLASSES.has(scls):
				scls = "tackle_brute"
			var stier := str(args.get("tier", "elite"))
			if not ["minion", "elite", "boss"].has(stier):
				stier = "elite"
			var mid := _spawn_fighter(scls, 1, Vector2(f["x"] + 100.0, f["y"]), str(s["map"]))
			var mf = _find(mid)
			mf["mobLevel"] = clampi(int(args.get("level", 3)), 1, 10)
			mf["mobTier"] = stier
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
	_spawn_world_actors()                         # rebuild the dummy + every zone's camps (same as boot)

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
	var item := _make_item(slot, str(rar["name"]), SHOP_ILVL)
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
		"last_map": str(session.get("map", World.HOME)), "credits": int(session.get("credits", 0)),
		"practice_tokens": int(session.get("tokens", 0))}
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
			"name": str(s["name"]), "credits": int(s.get("credits", 0)),
			"dmgMult": float(pf["dmgMult"]) if pf != null else 1.0,
			"crit": float(pf["crit"]) if pf != null else 0.0,
			"critMult": float(pf["critMult"]) if pf != null else 1.5}
	for pid in _peers:
		var s = _session[pid]
		var f = _find(s["fid"])
		if f == null or not _worlds.has(s["map"]):
			continue
		var snap: Dictionary = _snapshot_for(_worlds[s["map"]], str(s["map"]), Vector2(f["x"], f["y"]), pinfo)
		snap["portals"] = _portals_for_player(str(s["map"]), pid)   # hide gated (secret) portals until unlocked
		snap["party"] = _party_roster(pid)        # roster (with live HP) for the party HUD
		if str(s["map"]) == World.HOME:           # the shop / forge pads + quest giver only exist in the home base
			snap["shop"] = {"x": World.SHOP_POS.x, "y": World.SHOP_POS.y}
			snap["forge"] = {"x": World.FORGE_POS.x, "y": World.FORGE_POS.y}
			snap["questgiver"] = {"x": World.QUESTGIVER_POS.x, "y": World.QUESTGIVER_POS.y}
			snap["practice"] = {"x": World.PRACTICE_POS.x, "y": World.PRACTICE_POS.y}   # the Practice Vendor (reward loop)
		# self stat block for the character sheet (P3) — only the recipient's own APPLIED (capped, post-
		# FORMAT_MODS) finals + the capped 6-stat equip_bonus + gear score, so the sheet never overstates power.
		snap["self"] = {
			"classId": str(f["classId"]), "level": int(s["level"]), "item_power": int(s.get("item_power", 0)), "scrap": int(s.get("scrap", 0)), "tokens": int(s.get("tokens", 0)),
			"set_bonus": (s.get("set_bonus", {}) as Dictionary).duplicate(),
			"procs": (s.get("procs", []) as Array).duplicate(),
			"maxHP": float(f["maxHP"]), "dmgMult": float(f["dmgMult"]), "crit": float(f["crit"]), "critMult": float(f["critMult"]),
			"ms": float(f["ms"]), "cdr": float(f["cdr"]), "clutchDmg": float(f["clutchDmg"]), "clutchDR": float(f["clutchDR"]),
			"equip_bonus": (s.get("equip_bonus", {}) as Dictionary).duplicate(),
		}
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
		var any_t: float = _worlds[_worlds.keys()[0]]["t"]   # every world ticks in lockstep — read any
		print("[zone] t=%.0f  %s" % [any_t, " ".join(counts)])

func _snapshot_for(w: Dictionary, mapname: String, center: Vector2, pinfo: Dictionary) -> Dictionary:
	var fs := []
	for f in w["fighters"]:
		# always ship the BOSS (phased) regardless of interest distance — its arena-wide ult can hit you from
		# the far edge (> INTEREST_RADIUS), so its telegraph/phase/scoreboard must always reach every client here.
		if Vector2(f["x"] - center.x, f["y"] - center.y).length() <= INTEREST_RADIUS or GameData.CLASSES.get(str(f["classId"]), {}).get("phased", false):
			var d := {
				"id": f["id"], "classId": f["classId"], "team": f["team"],
				"x": f["x"], "y": f["y"], "hp": f["hp"], "maxHP": f["maxHP"],
				"alive": f["alive"], "flash": f["flash"], "cds": f["cds"].duplicate(),
			}
			if str(f.get("party", "")) != "":         # party key → client mirrors party-aware hostility
				d["party"] = str(f["party"])
			if pinfo.has(f["id"]):
				var pi = pinfo[f["id"]]
				d["level"] = pi["level"]
				d["name"] = pi["name"]
				d["credits"] = pi["credits"]
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
				if f.get("isCore", false):
					d["isCore"] = true            # client renders the destructible power core
				if GameData.CLASSES.get(str(f["classId"]), {}).get("phased", false):
					d["phase"] = int(f.get("phase", 0))   # boss: drives per-phase emissive + the scoreboard
					var cst = f.get("casting", null)       # Full Camp Reset telegraph countdown (scoreboard + screen tint)
					if cst != null and str((cst.get("ab", {}) as Dictionary).get("type", "")) == "campreset":   # match the ult TYPE (Boss2's key is "totalreset")
						d["ultCast"] = maxf(0.0, float(cst["total"]) - float(cst["t"]))
			fs.append(d)
	var ps := []
	for p in w["projectiles"]:
		if Vector2(p["x"] - center.x, p["y"] - center.y).length() <= INTEREST_RADIUS:
			ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0)})
	var hz := []                                  # hazard zones only (dmg/slow) — buff zones stay invisible
	for z in w["zones"]:
		if float(z.get("dmg", 0.0)) <= 0.0 and z.get("slow", null) == null:
			continue
		if Vector2(z["x"] - center.x, z["y"] - center.y).length() <= INTEREST_RADIUS + float(z["radius"]):
			hz.append({"x": z["x"], "y": z["y"], "radius": z["radius"], "dmg": float(z.get("dmg", 0.0))})
	return {"fighters": fs, "projectiles": ps, "zones": hz,   # cover-panel props are read client-side from World.OBSTACLES by map name
		"events": w["events"].duplicate(true), "t": w["t"],
		"map": mapname, "portals": World.portals_for(mapname), "pvp": bool(w.get("pvp", false)),
		"arenaW": int(w.get("arenaW", GameData.ARENA_W)), "arenaH": int(w.get("arenaH", GameData.ARENA_H))}
