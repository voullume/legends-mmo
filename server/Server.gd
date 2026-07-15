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
const NetTrust := preload("res://shared/NetTrust.gd")
const Protocol := preload("res://shared/Protocol.gd")
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
const MOB_BOSS_HP := 22.0             # a raid-style boss tuned for a full party of 5 — the BASE pool; P7c scales it DOWN for smaller groups
const MOB_BOSS_DMG := 2.1             # hits hard enough that ignoring its mechanics (ult/adds) wipes a careless group

# P7c — per-party-size boss scaling. A phased WORLD boss (Head Coach / PRIME) locks its HP pool to the engaging
# force on its FIRST hit: a lone geared attacker faces a fraction, a full group the whole raid. HP-only (full
# damage is kept, so a solo must still survive the mechanics). Server-only — a mob-stat lock, no FORMAT_MODS /
# no deterministic-sim change. All three knobs are playtest-tunable. Counting a bot as ~half a real player (v1
# nerfed them ≈ half) makes near-max-gear-solo-with-bots a tight win but a gate-minimum group a loss.
const BOSS_SOLO_HP_FRAC := 0.30       # a lone effective attacker faces this fraction of the 5-player HP pool
const BOSS_HP_PER_ATTACKER := 0.175   # + this per additional effective attacker, clamped to 1.0 (~5 attackers = full raid)
const BOSS_BOT_WEIGHT := 0.5          # an AI bot counts as this fraction of a real player toward the effective count
const BOSS_SCALE_COMMIT := 0.90       # lock only once REAL damage has driven the boss below this HP fraction (well above the 0.70 phase-1 boundary) — so the lock is anchored to an attack, not a timer; a lone tagger who leaves can't lock it (leash restores it)
const MOB_BOSS_XP := 6                # ≈ 0.9 of a level at its tier — rewarding but kept under a full level
const LEVEL_HP := 60.0                # bonus max HP per player level
const LEVEL_CAP := 30                 # endgame P1: the level ceiling (mobs scale via Intensity, not level, past here)
# --- gameplay-length P1: con / level-difference XP scaling + party XP share (see docs/gameplay-length-handoff.md) ---
const XP_CON_GRACE := 4               # a mob within ±this many levels of the killer gives full XP
const XP_CON_SPAN := 12               # levels past the grace band over which XP fades from full down to the floor
const XP_CON_FLOOR := 0.4             # a far over/under-leveled open-world mob still gives 40% — keeps GY5 a viable backup farm for high levels until Phase 8 adds 9-28 zones (avoids a punitive cliff)
const XP_SHARE_RANGE := 900.0         # same-zone party members within this range of the kill share the XP
const XP_SHARE_MAX_DELTA := 8         # a party member >this many levels from the killer doesn't share (anti power-level)
const DUMMY_HP := 500.0               # the training dummy's fixed HP (no mob scaling)
const TP_GRACE_MS := 1500             # after a teleport/spawn, brief immunity to re-triggering a pad
# --- AI residents (RP0): server-side AI "players" (team 0, driven by the AI brain — never marked `controlled`).
# Ephemeral (no account/DB/economy). `tier` emulates gear (no inventory); `polite` residents pass their
# killing-blow kills to a nearby engaged player (helping never robs you), the rude one hogs them. ---
# `route` (RP1): a routing resident JOURNEYS through those zones (like a player working content), dwelling in
# each; a home-only resident holds its zone. Routes never include the boss arena or the PvP arena.
const RESIDENTS := [
	{"id": "sarge",   "name": "Sarge",   "class": "linebacker", "persona": "grinder",  "home": "glitchyard_2",    "level": 6,  "tier": "mid",  "polite": true,  "route": ["glitchyard_2", "glitchyard_3", "glitchyard_1"]},
	{"id": "mercy",   "name": "Mercy",   "class": "setter",     "persona": "support",  "home": "glitchyard_1",    "level": 6,  "tier": "mid",  "polite": true},
	{"id": "blitz",   "name": "Blitz",   "class": "spiker",     "persona": "raider",   "home": "glitchyard_5",    "level": 10, "tier": "high", "polite": true},
	{"id": "reaper",  "name": "Reaper",  "class": "striker",    "persona": "fighter",  "home": "glitchyard_3",    "level": 9,  "tier": "high", "polite": true},
	{"id": "nomad",   "name": "Nomad",   "class": "goalkeeper", "persona": "wanderer", "home": "glitchyard_3",    "level": 5,  "tier": "mid",  "polite": true,  "route": ["glitchyard_3", "glitchyard_4", "glitchyard_5", "glitchyard_1"]},
	{"id": "vulture", "name": "Vulture", "class": "batter",     "persona": "rude",     "home": "glitchyard_4",    "level": 8,  "tier": "high", "polite": false},
	# Phase-8 S5: the new biome gets resident life too (the away/finals bands felt empty of "players").
	# Levels sit inside each zone band so they survive without carrying (same helper-not-carry tiers).
	{"id": "scout",   "name": "Scout",   "class": "pitcher",    "persona": "wanderer", "home": "away_1",          "level": 11, "tier": "mid",  "polite": true,  "route": ["away_1", "away_2"]},
	{"id": "roadie",  "name": "Roadie",  "class": "batter",     "persona": "grinder",  "home": "away_3",          "level": 15, "tier": "high", "polite": true},
	{"id": "champ",   "name": "Champ",   "class": "quarterback","persona": "fighter",  "home": "finals_1",        "level": 21, "tier": "high", "polite": true,  "route": ["finals_1", "finals_2"]},
]
const ROUTE_DWELL_MS := 75000         # a routing resident spends this long in each zone before moving on
const RESIDENT_TIERS := {"low": {"hp": 1.0, "dmg": 1.0}, "mid": {"hp": 1.3, "dmg": 1.1}, "high": {"hp": 1.8, "dmg": 1.25}}   # difficulty-pass v1: bots are helpers, not carries (was mid 1.6/1.25, high 2.6/1.55) — tunable
const RESIDENT_STRIP_ULTS := true                # difficulty-pass v1: park bonded-resident ultimates (their biggest carry burst); mercy keeps her single-target heal
const RESIDENT_ULT_LOCK := 1.0e9                 # sentinel cooldown that never decrements to 0 within a bounded fight
# --- difficulty-pass v1: gate the first boss (Head Coach Arena) on real progression so a fresh char + bots can't cheese it ---
const BOSS_GATE_LEVEL := 16                       # must be at least this level to enter GY_BOSS (tunable)
const BOSS_GATE_IP := 800                         # AND at least this aggregate equipped item-power / gear score (tunable; ~top of the fresh-quester band, just below a full-rare set)
const AWAY_GATE_LEVEL := 8                        # Phase 8: the Away Circuit opens once the Yard's on-ramp is outgrown (visible-but-locked, like boss_ready)
const FINALS_GATE_LEVEL := 17                     # Phase 8 S3: the Finals district — level AND gear, deliberately NOT the raid kill
const FINALS_GATE_IP := 800                       # (same bar as boss_ready: the away chain's graduation gear IS the Finals ticket)
const HIDDEN_GATES := ["secret_key", "all_quests"]   # gated portals HIDDEN in the snapshot; boss_ready stays VISIBLE-but-locked (a known goal, not a surprise)
const GATE_PROMPT_COOLDOWN_MS := 4000             # one "sealed pad" prompt per this interval while loitering on a locked gated pad
const RESIDENT_ASSIST_RANGE := 280.0  # a resident's kill credits a player within this range of the mob
const RESIDENT_ENGAGED_S := 6.0       # "engaged" = took a hit within this many seconds (a real participant)

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
# per-tier base chance a kill drops an item at all (minions also scale +DROP_INTENSITY_STEP per Circuit tier).
# Tuned DOWN so loot feels earned (was minion 0.65 / elite+boss 1.0).
const DROP_CHANCE := {"minion": 0.15, "elite": 0.40, "boss": 0.90}
const DROP_INTENSITY_STEP := 0.03
# party loot: a want/need/pass roll opens when a partied player (≥2 real members, same zone) gets a drop.
const LOOT_ROLL_MS := 20000                       # the roll window before it auto-resolves
var _loot_rolls := {}                             # drop_id -> {item, map, eligible:[pids], choices:{pid:choice}, leader, deadline}
var _loot_roll_ctr := 0
var _loot_roll_next := {}                         # pid -> earliest next loot_roll ms (anti-spam, like the other RPCs)
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
var _char_peer := {}                # character id → controlling peer id — the SINGLE-ACTIVE-SESSION claim
									# (stabilization P2). One character, one live peer, per server process.
var _move := {}
var _pending_ability := {}
var _last_aseq := {}
var _hop_t0 := {}                  # Phase 0.5 cosmetic hop: fighter id → server ms the current hop started (echoed as snapshot hopT)
var _hop_next := {}                # peer id → earliest ms it may hop again (anti-spam rate limit)
var _hop_n := 0                    # accepted hops this health interval — the Phase-1 gate's demand instrument
								   # (hops/min in the [health] line; re-open the verticality gate only if usage holds — see docs/jump-verticality-phase1-decision.md)
var _intent_age := {}
var _spawn_pos := {}
var _respawn := {}
var _mob_engaged := {}              # mob id → currently engaged (for leash hysteresis + heal-once)
var _tp_next := {}                 # fighter id → earliest ms it may use a portal (grace after teleport/spawn)
var _gate_prompt_next := {}        # pid → earliest ms for the next "sealed pad" prompt (difficulty-pass v1)
var _chat_next := {}               # peer id → earliest ms it may chat again (rate limit)
var _equipping := {}               # peer ids with an equip() toggle in flight (race guard)
var _equip_next := {}              # peer id → earliest ms it may equip again (rate limit)
var _fseq := 0
var _acc := 0.0
var _save_t := 0.0
var _save_fail_n := 0              # observability: count of failed character saves (never silently "ok")
var _snap_count := 0
const META_HEARTBEAT := 30            # re-ship the quasi-static snapshot META at least this often (~1s) so a
var _meta_hash := {}                  # dropped unreliable packet can't strand a client on a stale sheet/pads
var _meta_tick := {}                  # pid → last _snap_count at which META was sent (change-detected otherwise)
var _health_t := 0.0
var _tick_us_peak := 0                # peak server compute time per frame this minute (CPU headroom)

static func _xp_to_next(level: int) -> int:
	# gameplay-length P1(e): reshaped to ~the same 1→30 total (~86k XP) but FRONT-LOADED — early levels are cheaper
	# so a new character assembles its (now level-gated, P2) kit fast, shrinking the aggressive-gating barren window.
	return int(50.0 * level + 7.5 * level * level)

func start(port := PORT, use_dtls := false, bind_ip := "") -> bool:
	var peer := ENetMultiplayerPeer.new()
	if bind_ip != "":                            # some UDP hosts (e.g. Fly) need a specific bind addr
		peer.set_bind_ip(bind_ip)
	var err := peer.create_server(port)
	if err != OK:
		push_error("[zone] create_server(%d) failed: %d" % [port, err])
		return false
	if use_dtls:                                 # stabilization P4: trust policy lives in shared/NetTrust.gd
		var tls := NetTrust.server_tls_options() # production: operator cert REQUIRED; dev: self-signed fallback
		if tls == null:
			push_error("[zone] DTLS trust configuration missing/invalid — server NOT started (fail closed)")
			return false
		var derr := peer.host.dtls_server_setup(tls)
		if derr != OK:
			push_error("[zone] DTLS setup failed: %d" % derr)
			return false
	elif _is_production():
		push_error("[zone] PRODUCTION refuses to run PLAINTEXT — start with --dtls and the operator certificate (see docs/stabilization.md)")
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Engine.max_fps = 60
	init_worlds()
	print("[zone] online on UDP %d  (%d zones, %d mobs, %d residents%s)" % [port, _worlds.size(), _mob_count(), RESIDENTS.size(), "  · DTLS" if use_dtls else ""])
	_check_service_key()                         # verify loot/equip will be able to save
	_probe_atomic_econ()                         # P3: detect the DB-side atomic economy functions
	return true

# Build the in-memory game state (loot rng, one independent sim per static zone, world actors, AI
# residents) without touching the transport — split from start() so the headless stabilization tests
# (tools/stab_*.gd) can boot a complete server with no ENet peer and no live Supabase.
func init_worlds() -> void:
	# vary loot per launch with process-unique, high-res entropy (no same-second seed collisions)
	_loot_rng = Rng.new(int(Time.get_unix_time_from_system()) ^ Time.get_ticks_usec() ^ (OS.get_process_id() << 13))
	for mapname in World.MAPS:                   # one independent sim per STATIC zone (instance templates are
		if World.is_instance_template(mapname):  # spun up on demand per party, not created here)
			continue
		_worlds[mapname] = _new_world(mapname)
	_spawn_world_actors()                        # the home dummy + every combat zone's mob camps
	_spawn_residents()                           # the AI residents (RP0)

# On boot, confirm the service_role key can actually write our inventory table (loot/equip).
# Logs a clear ✓/✗ in `docker logs` (status only — NEVER the key itself). In PRODUCTION a missing or
# invalid key is fatal (stabilization P6): a zone that can't persist must not accept players.
func _check_service_key() -> void:
	if supa == null or supa.service_key == "":
		if _is_production():
			push_error("[zone] ✗ SUPABASE_SERVICE_KEY missing in PRODUCTION — a non-persisting zone must not run. Exiting.")
			get_tree().quit(1)
			return
		print("[zone] ✗ SUPABASE_SERVICE_KEY not set — loot/equip will NOT save.")
		return
	var r = await supa._http(HTTPClient.METHOD_GET, "/rest/v1/inventory?select=id&limit=1", "", PackedStringArray(), supa.service_key)
	if int(r.get("code", 0)) == 200:
		print("[zone] ✓ SUPABASE_SERVICE_KEY valid for this project — loot/equip will save.")
	elif _is_production():
		push_error("[zone] ✗ SUPABASE_SERVICE_KEY INVALID (HTTP %s) in PRODUCTION — exiting so the supervisor surfaces it." % str(r.get("code")))
		get_tree().quit(1)
	else:
		print("[zone] ✗ SUPABASE_SERVICE_KEY INVALID (HTTP %s) — loot/equip will NOT save. Redeploy with the correct service_role key." % str(r.get("code")))

# ---- stabilization P3: atomic + idempotent economy ------------------------------------------------
# When the DB-side economy functions (migration 20260714000000_stab_atomic_economy.sql) are present,
# every currency↔item exchange runs as ONE Postgres transaction keyed by a server-generated op id
# (retry-safe via the DB op ledger), and credits/practice_tokens become DB-authoritative: the session
# holds a MIRROR (last DB balance + not-yet-flushed award buckets) and _save_one stops PATCHing them
# absolutely. Without the functions: development falls back to the legacy application-level paths
# (loud warning); PRODUCTION fails closed (economy ops refused) rather than running the unsafe path.
var _atomic_econ := false             # detected at boot by _probe_atomic_econ()
var _legacy_econ_warned := false
var _crypto: Crypto = null            # op-id generator (idempotency keys)

func _is_production() -> bool:
	return NetTrust.is_production()

# a fresh UUIDv4 operation id — the idempotency key the DB op ledger dedupes on
func _op_id() -> String:
	if _crypto == null:
		_crypto = Crypto.new()
	var b := _crypto.generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]

func _probe_atomic_econ() -> void:
	if supa == null or not supa.has_method("econ_available"):
		return
	_atomic_econ = await supa.econ_available()
	if _atomic_econ:
		print("[zone] ✓ atomic economy functions live (P3) — purchases/sells/forge run in-DB")
	elif _is_production():
		print("[zone] ✗ atomic economy functions MISSING in PRODUCTION — economy ops will be REFUSED (fail closed). Apply supabase/migrations/20260714000000_stab_atomic_economy.sql, then restart.")
	else:
		print("[zone] ⚠ atomic economy functions missing — DEV fallback to the legacy application-level economy paths")

# legacy (pre-migration) economy paths are allowed only OUTSIDE production; production fails closed.
func _legacy_econ_allowed() -> bool:
	if _is_production():
		print("[zone] ✗ economy op refused — atomic economy functions missing in production (fail closed)")
		return false
	if not _legacy_econ_warned:
		_legacy_econ_warned = true
		print("[zone] ⚠ DEV: legacy (non-atomic) economy path in use — apply the stab_atomic_economy migration to exercise the atomic path")
	return true

# atomic mode: the session currency values are a MIRROR = the DB balance an econ fn just returned
# + the award deltas still waiting to flush. Every econ-fn result routes through here.
func _econ_sync_currency(s: Dictionary, r: Dictionary) -> void:
	var open: Dictionary = s.get("award_open", {})
	var pkt: Dictionary = s.get("award_packet", {})
	if r.has("credits"):
		s["credits"] = int(r["credits"]) + int(open.get("credits", 0)) + int(pkt.get("credits", 0))
	if r.has("tokens"):
		s["tokens"] = int(r["tokens"]) + int(open.get("tokens", 0)) + int(pkt.get("tokens", 0))
	if r.has("scrap"):
		s["scrap"] = int(r["scrap"])

# ---- per-session ECON GATE: at most ONE balance-returning DB op in flight per session. Without it
# an award flush and a purchase could overlap, and their returned balance snapshots would apply to
# the mirror in RESPONSE order rather than DB-commit order (transient over/under display, spurious
# insufficient refusals). Every atomic-branch econ call and every award flush holds the gate. ----
func _econ_begin(s: Dictionary) -> void:
	while bool(s.get("_econ_inflight", false)):
		await get_tree().process_frame          # WAIT (never skip): ordering is what keeps the mirror sane
	s["_econ_inflight"] = true

func _econ_end(s: Dictionary) -> void:
	s["_econ_inflight"] = false

# award packets whose owning session disconnected before their flush landed — retried from the save
# tick with the SAME op id (the DB op ledger makes every retry idempotent, so this can never double-pay)
var _orphan_awards: Array = []
const ORPHAN_AWARD_MAX_TRIES := 40             # ~10 min at the 15 s save cadence, then drop with a log

func _queue_orphan_award(s: Dictionary) -> void:
	var pkt: Dictionary = s.get("award_packet", {})
	if not pkt.is_empty():
		_orphan_awards.append({"op": str(pkt["op"]), "char_id": str(s["char_id"]),
			"credits": int(pkt.get("credits", 0)), "tokens": int(pkt.get("tokens", 0)), "tries": 0})
		s.erase("award_packet")
	var open: Dictionary = s.get("award_open", {})
	if int(open.get("credits", 0)) != 0 or int(open.get("tokens", 0)) != 0:
		_orphan_awards.append({"op": _op_id(), "char_id": str(s["char_id"]),
			"credits": int(open.get("credits", 0)), "tokens": int(open.get("tokens", 0)), "tries": 0})
		s["award_open"] = {"credits": 0, "tokens": 0}

func _retry_orphan_awards() -> void:
	if _orphan_awards.is_empty() or not _atomic_econ or supa == null:
		return
	var batch: Array = _orphan_awards          # swap so a slow retry can't race the next save tick
	_orphan_awards = []
	for e in batch:
		var r = await supa.econ_award(str(e["op"]), str(e["char_id"]), int(e["credits"]), int(e["tokens"]))
		if bool(r.get("ok", false)) or str(r.get("reason", "")) == "no_character":
			continue                            # landed (possibly as a ledger duplicate) or unrecoverable
		e["tries"] = int(e["tries"]) + 1
		if int(e["tries"]) >= ORPHAN_AWARD_MAX_TRIES:
			print("[zone] ⚠ dropping orphaned award packet for %s after %d failed retries (%d cr / %d tk)" % [
				str(e["char_id"]), int(e["tries"]), int(e["credits"]), int(e["tokens"])])
			continue
		_orphan_awards.append(e)

# flush pending kill/quest/drill awards as ONE idempotent DB delta (econ_award). A transport-failed
# packet is KEPT and retried with the SAME op id on the next flush — the op ledger makes the retry
# safe (never double-credits). New awards accrued meanwhile go to a fresh bucket/op. If the owning
# session has disconnected (_gone), a failed packet is handed to the orphan retry queue instead.
func _flush_awards(s: Dictionary) -> void:
	if not _atomic_econ or supa == null:
		return
	await _econ_begin(s)
	var pkt: Dictionary = s.get("award_packet", {})
	if pkt.is_empty():
		var open: Dictionary = s.get("award_open", {})
		var c := int(open.get("credits", 0))
		var t := int(open.get("tokens", 0))
		if c == 0 and t == 0:
			_econ_end(s)
			return
		pkt = {"op": _op_id(), "credits": c, "tokens": t}
		s["award_packet"] = pkt
		s["award_open"] = {"credits": 0, "tokens": 0}
	var r = await supa.econ_award(str(pkt["op"]), str(s["char_id"]), int(pkt["credits"]), int(pkt["tokens"]))
	_econ_end(s)
	if bool(r.get("ok", false)):
		s.erase("award_packet")
		if not bool(r.get("duplicate", false)):
			_econ_sync_currency(s, r)           # a replayed result carries the ORIGINAL commit's balance —
												# never overwrite a mirror that may have moved since
	elif bool(s.get("_gone", false)):
		_queue_orphan_award(s)                  # nobody will flush this dead session again — background retry

# atomic buy (shop / roll / vendor): debit + mint in one DB transaction — no refund path needed.
func _give_and_charge_atomic(pid: int, item: Dictionary, price_credits: int, price_tokens: int) -> void:
	var s = _session[pid]
	await _flush_awards(s)                            # make the DB balance current before the guarded debit
	await _econ_begin(s)
	var r = await supa.econ_buy_item(_op_id(), str(s["char_id"]), price_credits, price_tokens, item)
	_econ_end(s)
	if bool(r.get("ok", false)):
		_econ_sync_currency(s, r)
		if net != null and _session.has(pid):
			net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
			net.recv_inventory_changed.rpc_id(pid)
	if not _session.has(pid):
		_save_one(s, _find(s["fid"]))                 # deferred-save contract: the disconnect handler skipped
													  # its logout save while our busy-lock was held

# A world key is either a static map name ("home") or an instance key ("camp#<owner>"). The TEMPLATE is the
# static prefix — all World.gd lookups (cfg/obstacles/portals/mobs/spawn) resolve by template so every instance
# of "camp" shares the camp blueprint.
func _template(map: String) -> String:
	var i := map.find("#")
	return map.substr(0, i) if i >= 0 else map

func _is_instance(map: String) -> bool:
	return map.find("#") >= 0

func _new_world(map: String) -> Dictionary:
	var tmpl := _template(map)
	var w: Dictionary = Sim.create_match([], [], SEED, MAP_ID)
	w["zone"] = true                             # persistent: no match-end / no overtime ramp
	# own map dict per world (NOT the shared GameData venue): the cover-panel rows expand into collision
	# circles here, which unlock cover/LOS/projectile-block. The client renders the panel props from World.
	# cover panels (OBSTACLES) + decoration-prop collision (data/decals/<map>.json) — so town buildings/trees/fences
	# etc. block players + mobs, not just the authored cover. Server-side only (the client renders props as decals).
	w["map"] = {"id": map, "name": tmpl, "obstacles": World.obstacle_circles(tmpl) + World.collision_from_decals(tmpl)}
	var c := World.cfg(tmpl)                      # per-map size + regen + aggro + pvp (by template)
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
		if World.is_instance_template(mapname):   # instance templates are populated per-instance, not statically
			continue
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
		if World.is_instance_template(mapname):
			continue
		n += (World.MOBS[mapname] as Array).size()
	return n

# ---- AI residents (RP0): spawn the roster as team-0 fighters driven by the AI brain ----
var _residents := {}                             # resident fighter id → its roster def (for the director/respawn)
var _res_dir := {}                               # resident fighter id → director state {route_idx, next_move_t}
var _res_t := 0.0                                # director cadence accumulator (~2 Hz is plenty)
var _res_party := {}                             # RP2: resident fid → leader pid (a partied resident follows this player)
var _res_chat_next := {}                         # RP3: resident fid → earliest ms it may speak again
var _res_chat_i := 0                             # RP3: rotating line index (server-side only — never the sim RNG)
var _res_prog := {}                              # RP4: resident fid → {last_dmg, stall_t} (no-combat-progress tracking)
var _res_deaths := {}                            # RP4: resident fid → {zone: death count} (repeated-death signal)
var _res_report_next := {}                       # RP4: resident fid → {kind: next-report ms} (anti-spam per kind)
var _rep_t := 0.0                                # RP4: report-scan cadence accumulator
const REPORT_TICK_S := 2.0                       # how often the report scan runs
const REPORT_STALL_S := 60.0                     # disengaged in a mob-full aggro zone this long → report it
												 # (MUST stay < ROUTE_DWELL_MS/1000 so a router can reach it within one zone dwell)
const REPORT_DEATH_THRESHOLD := 3                # this many deaths in one zone → report (then reset that zone's counter)
const REPORT_COOLDOWN_MS := 300000               # don't re-report the same (resident, kind) anomaly for 5 min
const RES_CHAT_COOLDOWN_MS := 30000              # a resident speaks at most this often (kill/join/ambient share it)
# persona flavor lines by context. Vulture ("rude") is antagonistic throughout; the mechanical selfishness
# (hogging its solo kills) already lives in RP0's resPolite. Purely presentational — no sim/determinism impact.
const RESIDENT_LINES := {
	"grinder": {
		"join": ["Alright, let's clear some camps.", "Good — I could use a partner. Let's grind."],
		"kill": ["Camp's thinning out.", "Next one.", "Keep the pace up."],
		"ambient": ["Grind never stops.", "This camp respawns quick — stay sharp.", "XP's XP. Keep moving."],
		"dismiss": ["Good runs. Later.", "Back to the grind, then."],
	},
	"support": {
		"join": ["I've got your back — shout if you're hurt.", "Stick close, I'll keep you standing."],
		"kill": ["Nice one — you're clear.", "Got you covered.", "Clean work."],
		"ambient": ["Yell if anyone needs a top-off.", "Keeping an eye on everyone's health.", "Don't be a hero — I can heal."],
		"dismiss": ["Stay safe out there.", "Call me if you need patching up."],
	},
	"raider": {
		"join": ["Point me at the big one.", "Let's go bag something huge."],
		"kill": ["Down it goes.", "Too easy — where's the real fight?", "That all you've got?"],
		"ambient": ["Where's the boss at?", "I live for the big pulls.", "Small fry. I want the coach."],
		"dismiss": ["Find me a real fight next time.", "I'm off to hunt something bigger."],
	},
	"fighter": {
		"join": ["Stay behind me.", "I'll take the front."],
		"kill": ["Dropped.", "Who's next?", "Not even close."],
		"ambient": ["Nobody's dropped me yet.", "Come test me in the Arena.", "I fight better than I talk."],
		"dismiss": ["Watch yourself out there.", "Good spar. Later."],
	},
	"wanderer": {
		"join": ["Lead the way — I'll keep up.", "New company, new roads. Let's move."],
		"kill": ["One more for the road.", "Onward.", "Tidy."],
		"ambient": ["Been all over these yards.", "Always somewhere new past the next gate.", "Just passing through, same as always."],
		"dismiss": ["Off to wander again. Be well.", "See you down the road."],
	},
	"rude": {
		"join": ["Fine. Don't get in my way.", "Great, a tagalong. Keep up or don't."],
		"kill": ["Mine.", "Told you I'd get it.", "Back off — that's my kill."],
		"ambient": ["Ugh, amateurs everywhere.", "I don't share loot. Don't ask.", "Get your own kills."],
		"dismiss": ["Finally.", "Waste of my time.", "Don't call me again."],
	},
}

func _spawn_residents() -> void:
	for r in RESIDENTS:
		var home := str(r["home"])
		if not _worlds.has(home):                    # a bad home (unknown zone) → fall back to home base
			home = World.HOME
		var base := World.spawn_for(home)
		var off := Vector2(120.0 + 40.0 * float(_residents.size()), 60.0 * (float(_residents.size() % 3) - 1.0))
		var fid := _spawn_fighter(str(r["class"]), 0, base + off, home)   # team 0 → NOT in `controlled` → AI brain
		var f = _find(fid)
		if f == null:
			continue
		f["resident"] = true
		f["resId"] = str(r["id"])
		f["resName"] = str(r["name"])
		f["resLevel"] = int(r["level"])
		f["resTier"] = str(r["tier"])
		f["resPersona"] = str(r["persona"])
		f["resPolite"] = bool(r.get("polite", true))
		_scale_resident(f)
		_residents[fid] = r
		# RP1 director state — stagger each router's first move so they don't all travel at once
		_res_dir[fid] = {"route_idx": 0, "next_move_t": Time.get_ticks_msec() + ROUTE_DWELL_MS + _residents.size() * 9000}
		_res_chat_next[fid] = Time.get_ticks_msec() + _residents.size() * 4000   # RP3: stagger so they don't all speak at once
		_res_prog[fid] = {"last_dmg": 0.0, "stall_t": 0.0, "zone": ""}   # RP4: per-zone no-progress tracking
		_res_deaths[fid] = {}                                 # RP4: per-zone death counts
	print("[zone] %d AI residents spawned" % _residents.size())

# RP3: a resident speaks a persona line to its zone (only if a player's there to hear it; cooldown-gated so it
# reads as flavor, not spam). force skips the cooldown for discrete player-triggered moments (recruit). Purely
# presentational — reads only the fighter dict + server tables, never sim/RNG state, so determinism is untouched.
func _resident_say(fid: String, context: String, force := false) -> void:
	var now := Time.get_ticks_msec()
	if not force and now < int(_res_chat_next.get(fid, 0)):
		return                                       # on cooldown → bail before the O(n) _find (cheap on the hot kill path)
	var f = _find(fid)
	if f == null or not bool(f.get("alive", true)):
		return
	var rmap := str(f["map"])
	var listeners := []                              # only speak if someone in the zone can hear it
	for p in _peers:
		if _session.has(p) and str(_session[p].get("map", "")) == rmap:
			listeners.append(p)
	if listeners.is_empty():
		return
	var persona := str(f.get("resPersona", "grinder"))
	var pool: Array = (RESIDENT_LINES.get(persona, {}) as Dictionary).get(context, [])
	if pool.is_empty():
		return
	var line := str(pool[_res_chat_i % pool.size()])
	_res_chat_i += 1
	_res_chat_next[fid] = now + RES_CHAT_COOLDOWN_MS
	var who := str(f.get("resName", "resident"))
	print("[chat] %s: %s" % [who, line])
	if net != null:
		for p in listeners:
			net.recv_chat.rpc_id(p, who, line)

# RP4: automated-playtest reports. Residents play the game 24/7, so anomalies THEY hit — can't make combat
# progress in a zone full of mobs; dying over and over in one zone — are a cheap health signal for the dev.
# Detection is server-side + READ-ONLY over fighter dicts (no sim/RNG/shared change). Rows land in the
# bot_reports table (service_role) + a [report] log line; threshold + cooldown gated so a persistent problem
# reports periodically, not every tick.
func _tick_reports(dt: float) -> void:
	_rep_t += dt
	if _rep_t < REPORT_TICK_S:
		return
	var step := _rep_t
	_rep_t = 0.0
	for fid in _residents.keys():
		var f = _find(fid)
		if f == null or not f["alive"]:
			continue
		var zone := str(f["map"])
		var w = _worlds.get(zone, null)
		if w == null:
			continue
		var prog: Dictionary = _res_prog.get(fid, {"last_dmg": 0.0, "stall_t": 0.0, "zone": ""})
		var cur_dmg := float(f.get("dmgDealt", 0.0))
		if str(prog.get("zone", "")) != zone:         # the stall clock is PER-ZONE — a relocate (router/follow) starts
			prog["zone"] = zone                       # a fresh clock so a report always names the zone it accrued in
			prog["stall_t"] = 0.0
			prog["last_dmg"] = cur_dmg
		# "engaged" = dealing OR recently taking damage. dmgDealt is cumulative but RESETS to 0 on respawn, so any
		# change (up = dealt damage, down = respawned) counts; noDmgT<ENGAGED means it's in a fight (a support that
		# heals-and-tanks, or a resident trading blows). Only NEITHER for the whole window while mobs are present
		# is a real anomaly (stuck/unreachable) — this keeps the signal clean of legitimately-busy residents.
		var engaged: bool = cur_dmg != float(prog.get("last_dmg", 0.0)) or float(f.get("noDmgT", 999.0)) < RESIDENT_ENGAGED_S
		var combat: bool = bool(w.get("aggro", true)) and _zone_has_live_mobs(w)
		if not combat or engaged:
			prog["stall_t"] = 0.0
		else:
			prog["stall_t"] = float(prog.get("stall_t", 0.0)) + step
			if float(prog["stall_t"]) >= REPORT_STALL_S and _report_ok(fid, "no_progress"):
				var hpf := snappedf(float(f["hp"]) / maxf(float(f["maxHP"]), 1.0), 0.01)
				_emit_report(f, "no_progress", "stuck in %s for %ds (mobs present; neither dealing nor taking damage)" % [zone, int(prog["stall_t"])],
					{"zone": zone, "stall_s": int(prog["stall_t"]), "hp_frac": hpf})
				prog["stall_t"] = 0.0                 # reported → reset; re-reports only if it stays stuck another full window
		prog["last_dmg"] = cur_dmg
		_res_prog[fid] = prog

# tallied at the death edge in _tick_world; N deaths in one zone → a "this zone is punishing" report
func _on_resident_death(f) -> void:
	var fid := str(f["id"])
	var zone := str(f["map"])
	var byz: Dictionary = _res_deaths.get(fid, {})
	byz[zone] = int(byz.get(zone, 0)) + 1
	if int(byz[zone]) >= REPORT_DEATH_THRESHOLD:
		_emit_report(f, "repeated_death", "died %d times in %s" % [int(byz[zone]), zone], {"zone": zone, "deaths": int(byz[zone])})
		byz[zone] = 0                                 # reset so it re-reports only after another N deaths there
	_res_deaths[fid] = byz

# a live combat mob present in the zone — mirror the _award_kills exclusion set (not the dummy/adds/cores/Drill mobs)
func _zone_has_live_mobs(w: Dictionary) -> bool:
	for m in w["fighters"]:
		if int(m.get("team", 0)) == 1 and bool(m.get("alive", false)) and not m.get("dummy", false) and not m.get("isAdd", false) and not m.get("isCore", false) and not m.get("isDrill", false):
			return true
	return false

# per (resident, kind) cooldown so a persistent anomaly reports periodically, not every scan
func _report_ok(fid: String, kind: String) -> bool:
	var now := Time.get_ticks_msec()
	var byk: Dictionary = _res_report_next.get(fid, {})
	if now < int(byk.get(kind, 0)):
		return false
	byk[kind] = now + REPORT_COOLDOWN_MS
	_res_report_next[fid] = byk
	return true

# write one anomaly row (bot_reports via service_role) + a log line; fire-and-forget (never blocks the tick).
# All reads of f happen before the first await, so a later respawn/relocate can't corrupt the row.
func _emit_report(f, kind: String, detail: String, metrics: Dictionary) -> void:
	var rname := str(f.get("resName", "resident"))
	var zone := str(f["map"])
	print("[report] %s (%s) @%s — %s" % [rname, kind, zone, detail])
	if supa != null:
		await supa.bot_report_as(str(f.get("resId", "")), rname, zone, kind, detail, metrics)

# RP1: the Director — routing residents JOURNEY zone-to-zone (like a player working content); home-only
# residents are tethered to their zone. Runs at ~2 Hz (cheap; the AI brain handles local movement/combat).
func _tick_residents(dt: float) -> void:
	for res_fid in _res_party.keys():            # RP2 follow: every frame so zone-follow is snappy (bonded residents only)
		_try_follow(res_fid)
	_res_t += dt
	if _res_t < 2.0:
		return
	_res_t = 0.0
	var now := Time.get_ticks_msec()
	for fid in _residents.keys():
		_resident_say(fid, "ambient")                 # RP3: idle chatter for every resident (cooldown-gated, zone-scoped)
		if _res_party.has(fid):                       # bonded → the follow loop owns it; skip routing/tether
			continue
		var f = _find(fid)
		if f == null or not f["alive"]:
			continue                                  # dead → respawn handles it (in place)
		var r: Dictionary = _residents[fid]
		var st: Dictionary = _res_dir.get(fid, {})
		var route = r.get("route", null)
		if route is Array and (route as Array).size() > 1:
			if now >= int(st.get("next_move_t", 0)):  # time to move on to the next zone in the route
				var idx := (int(st.get("route_idx", 0)) + 1) % (route as Array).size()
				st["route_idx"] = idx
				st["next_move_t"] = now + ROUTE_DWELL_MS
				var to_map := str(route[idx])
				if _worlds.has(to_map):
					_relocate(f, null, to_map, World.spawn_for(to_map))
		else:
			# home-only: if it somehow drifted out of its zone (shouldn't — no portals), pull it back
			var home := str(r.get("home", World.HOME))
			if str(f["map"]) != home and _worlds.has(home):
				_relocate(f, null, home, World.spawn_for(home))

# emulate level + gear (residents have no inventory): flat level HP + a per-persona-tier hp/dmg multiplier.
func _scale_resident(f) -> void:
	var lvl := int(f.get("resLevel", 1))
	var tier: Dictionary = RESIDENT_TIERS.get(str(f.get("resTier", "mid")), RESIDENT_TIERS["mid"])
	f["maxHP"] = (f["maxHP"] + (lvl - 1) * LEVEL_HP) * float(tier["hp"])
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= float(tier["dmg"])
	if RESIDENT_STRIP_ULTS:                       # difficulty-pass v1: park bonded-resident ults on a sentinel cd so the Sim's cd>0 skip never fires them.
		for ab in GameData.CLASSES.get(str(f.get("classId", "")), {}).get("abilities", []):   # re-applied every respawn (create_fighter zeroes cds first). Don't remove without re-checking the cds handling.
			if ab.get("ult", false):
				(f["cds"] as Dictionary)[ab["key"]] = RESIDENT_ULT_LOCK

# ---- instances (endgame P0/P1): private per-party worlds spun up on demand + torn down when empty ----
var _instances := {}                             # instance key → {template, owner, tier, created_ms, cleared}
const INTENSITY_MAX := 30                         # ceiling on the ladder (the DB CHECK bounds it too)
# --- attunement (P2): Playbook Pages → the Master Key → the secret boss gate ---
const MASTER_KEY_PAGES := 300                     # pages to forge the Master Key (the ~6h chase dial)
const CIRCUIT_CLEAR_PAGES_BASE := 5              # a Circuit clear yields BASE + tier*PER_TIER pages
const CIRCUIT_CLEAR_PAGES_PER_TIER := 3
# --- gameplay-length P3b: weekly Camp Circuit AFFIX — a shared, rotating modifier stamped onto instance mobs via
# the mob-only _scale_mob lever (exactly like the Intensity ladder) so it's deterministic + balance-safe. UTC weeks.
const WEEK_SECS := 604800
const AFFIX_ROTATION := [
	{"id": "standard",   "name": "Standard Practice", "hp": 1.0,  "dmg": 1.0,  "pages": 1.0},
	{"id": "hardened",   "name": "Hardened Pads",      "hp": 1.35, "dmg": 1.0,  "pages": 1.15},   # tankier mobs, longer clears
	{"id": "frenzy",     "name": "Two-Minute Frenzy",  "hp": 0.85, "dmg": 1.20, "pages": 1.15},   # squishier but hit harder
	{"id": "recruiting", "name": "Recruiting Week",     "hp": 1.0,  "dmg": 1.0,  "pages": 1.5},    # pure-reward week
]
const CIRCUIT_ROTATION := ["camp", "camp_b", "camp_c"]   # gameplay-length P3b-rooms: the Camp Circuit rotates rooms per (party, tier, week)
const BOSS_PAGES := 50                            # the Head Coach boss also drops a page chunk
const RIVAL_PAGES := 15                           # Phase 8 S2: the Rival Coach's page chunk (repeatable on the 30-min boss cadence = 30 pages/hr — deliberately UNDER the Head Coach's 100/hr line so the rival never becomes the game's best Pages farm; no boss_time board — that stays head_coach-only so seasonal times stay comparable)
# --- Two-Minute Drill (P5): endless wave survival → leaderboard ---
const DRILL_WAVE_GAP_MS := 2500                  # breather between waves
const DRILL_PAGES_PER_WAVE := 2                  # end-of-run pages = max(0, wave-2) * this (wave 3+ only; anti-farm)
const DRILL_CREDITS_PER_WAVE := 40
const DRILL_XP_WAVE_FRAC := 0.08                 # gameplay-length P1: end-of-run XP per wave (3+) as a fraction of a level
const DRILL_XP_RUN_CAP_FRAC := 0.6               # a single Drill run is capped at this fraction of a level (anti power-farm)
const RESTED_BONUS := 0.5                        # gameplay-length P1(d): rested XP tops up each earned award by this fraction, drawn from the pool
const RESTED_CAP_FRAC := 1.5                     # rested pool cap = this many of the CURRENT level's xp-to-next
const RESTED_RATE_FRAC := 0.06                   # rested accrues this fraction of a level per HOUR offline (~fills the cap in ~25h)

# Intensity multipliers (P1): geometric so each tier is a real power check but the ladder is unbounded.
# hp ×1.6 / dmg ×1.13 per tier (tuned so a geared team clears its max tier, the next is a wall to grow into).
func _intensity_hp(tier: int) -> float:
	return pow(1.6, float(maxi(1, tier) - 1))
func _intensity_dmg(tier: int) -> float:
	return pow(1.13, float(maxi(1, tier) - 1))

# spawn a template's mob roster into an already-created instance world, stamped with the instance's Intensity
# (read by _scale_mob) + the clear-objective flag (its death completes the run).
func _spawn_instance_actors(key: String, tmpl: String, tier: int, affix: Dictionary = {}) -> void:
	for m in World.MOBS.get(tmpl, []):
		var fid := _spawn_fighter(str(m["class"]), 1, Vector2(float(m["x"]), float(m["y"])), key)
		var f = _find(fid)
		if f == null:
			continue
		f["mobLevel"] = int(m["level"])
		f["mobTier"] = str(m["tier"])
		f["intensity"] = tier                    # _scale_mob reads this for the ladder multiplier
		f["affixHp"] = float(affix.get("hp", 1.0))    # gameplay-length P3b: weekly affix, baked in here + read by _scale_mob below
		f["affixDmg"] = float(affix.get("dmg", 1.0))
		if bool(m.get("objective", false)):
			f["objective"] = true                # killing it completes the Circuit (grants tier reward + unlock)
		_scale_mob(f)
		if GameData.CLASSES.get(str(m["class"]), {}).get("isCore", false):
			f["isCore"] = true

# get-or-create the instance world for (template, owner, tier). Owner = a party key or a solo fid, so
# party-mates entering at the same tier share one instance. Idempotent: returns the existing key if live.
# gameplay-length P3b: this week's shared Circuit affix. Function of UTC weeks (orchestration, never read by the
# deterministic Sim) — identical for everyone in a given week, stamped onto each instance's mobs at spawn.
func _current_affix() -> Dictionary:
	var week := int(Time.get_unix_time_from_system() / WEEK_SECS)
	return AFFIX_ROTATION[week % AFFIX_ROTATION.size()]

# gameplay-length P3b-rooms: pick this run's Circuit room — a pure function of (owner key, tier, UTC week). Party-safe
# for mates who enter at the SAME tier (shared owner key → same room → shared instance); the room varies by tier as you
# climb + refreshes weekly. KNOWN LOW edge: two mates whose enter RPCs straddle the exact UTC-week flip resolve
# different rooms (self-heals on re-entry) — a future fix would join any live (owner,tier) instance regardless of tmpl.
func _circuit_template(owner: String, tier: int) -> String:
	var week := int(Time.get_unix_time_from_system() / WEEK_SECS)
	var idx := absi(("%s|%d|%d" % [owner, tier, week]).hash()) % CIRCUIT_ROTATION.size()
	return CIRCUIT_ROTATION[idx]

func _ensure_instance(tmpl: String, owner: String, tier: int, affix_override: Dictionary = {}) -> String:
	var key := "%s#%s#%d" % [tmpl, owner, tier]
	if not _worlds.has(key):
		_worlds[key] = _new_world(key)
		var affix := affix_override if not affix_override.is_empty() else _current_affix()   # P5 Audible: a bought affix override, else this run's weekly affix (baked in so a week-boundary mid-run doesn't re-roll)
		_spawn_instance_actors(key, tmpl, tier, affix)
		_instances[key] = {"template": tmpl, "owner": owner, "tier": tier, "created_ms": Time.get_ticks_msec(), "cleared": false, "affix": affix}
		print("[zone] instance %s created (I%d)" % [key, tier])
	return key

# route a player into a private instance of `tmpl` at Intensity `tier`. Party-aware owner keying.
func _enter_instance(pid: int, tmpl: String, tier: int, affix_override: Dictionary = {}) -> void:
	if not _session.has(pid):
		return
	var f = _find(_session[pid]["fid"])
	if f == null:
		return
	var owner := _party_key(pid)
	if owner == "":                              # solo → own the instance by fighter id
		owner = str(_session[pid]["fid"])
	var key := _ensure_instance(tmpl, owner, tier, affix_override)
	_relocate(f, _session[pid], key, World.spawn_for(tmpl))

# ---- Builder Mode P1: enter your PRIVATE Locker Room. Keyed per-CHARACTER (char_id) — NOT party/fid — so the
# room + its layout are yours alone and persist across sessions (the world is ephemeral, the placed items live in
# the DB). Gated on locker_unlocked, server-authoritative (_check_portals also gates before calling this). On entry
# we load the character's PLACED build items ONCE and cache them on the instance as snapshot `decals`; the 30 Hz
# broadcast reads the cache and never re-queries. Empty until P2's build_buy/place populates rows. ----
func _enter_locker_room(pid: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	if not bool(s.get("locker_unlocked", false)):
		return                                        # don't own it → the pad is inert (P3 offers the purchase)
	var f = _find(s["fid"])
	if f == null:
		return
	var key := _ensure_instance(World.LOCKER, str(s["char_id"]), 1)   # per-character; tier is unused (always 1)
	_relocate(f, s, key, World.spawn_for(World.LOCKER))
	var rows = await supa.get_placed_build_items_as(s["access"], str(s["char_id"]))
	var meta = _instances.get(key)                    # may be null if the peer left during the await (instance torn down)
	if meta != null and rows is Array:                # rows == null → read failed; leave decals empty (room re-queries on re-entry)
		meta["decals"] = _locker_decals(rows)

# format placed build-item rows [{model, xform}] into render decals matching Client._render_decals' prop decals
# ({kind:"prop", model, x,y,h,yaw,oy}). A row whose xform isn't a dict is skipped (defensive — placed rows carry one).
func _locker_decals(rows: Array) -> Array:
	var out := []
	for r in rows:
		var xf = (r as Dictionary).get("xform", null)
		if not (xf is Dictionary):
			continue
		# _safe_num on every read too (defense in depth): a junk row (e.g. a null-coord xform from an old client
		# or an admin insert) renders at a safe default instead of throwing and blanking the whole room.
		# `id` is included so the OWNER's client can map a placed prop back to its inventory row for move/remove
		# (P3b); Client._render_decals ignores the extra key, and the locker is private so only the owner sees it.
		out.append({"kind": "prop", "id": str((r as Dictionary).get("id", "")), "model": str((r as Dictionary).get("model", "")),
			"x": _safe_num(xf.get("x"), 0.0), "y": _safe_num(xf.get("y"), 0.0), "h": _safe_num(xf.get("h"), 2.0),
			"yaw": _safe_num(xf.get("yaw"), 0.0), "oy": _safe_num(xf.get("oy"), 0.0)})
	return out

# tear down an instance world once no players remain in it: remove its mobs (cleaning their id-keyed dicts)
# and drop the world + meta. Called whenever a player leaves an instance (portal out, death-relocate, disconnect).
func _maybe_teardown_instance(key: String) -> void:
	if not _is_instance(key) or not _worlds.has(key):
		return
	var w = _worlds[key]
	for fr in w["fighters"]:
		if fr["team"] == 0:                      # ANY connected player still inside (incl. a DEAD one awaiting its
			return                               # in-place respawn) keeps the instance — disconnected players are
												 # already stripped by _remove_fighter, so a corpse here = a live session
												 # (checking f["alive"] would tear the world out from under a downed co-op partner)
	for fr in w["fighters"]:                     # empty of players → purge every fighter's per-id server state
		var fid: String = fr["id"]
		_spawn_pos.erase(fid)
		_respawn.erase(fid)
		_tp_next.erase(fid)
		_mob_engaged.erase(fid)
	_worlds.erase(key)
	_instances.erase(key)
	print("[zone] instance %s torn down" % key)

# ---- Camp Circuit entry (RPC-driven so the client picks an Intensity tier) + clear/unlock (P1) ----
var _camp_next := {}                              # pid → earliest next enter_camp (light rate-limit)

# is the player standing at the home Camp entry pad? (mirrors _at_questgiver; entry is gated on this server-side)
func _at_camp_pad(pid: int) -> bool:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return false
	var f = _find(_session[pid]["fid"])
	if f == null:
		return false
	for p in World.PORTALS.get(World.HOME, []):
		if p.has("instance") and str(p["instance"]) == World.CAMP:
			return Vector2(f["x"] - float(p["x"]), f["y"] - float(p["y"])).length() <= World.PORTAL_RADIUS + 24.0
	return false

# client → server: enter the Camp Circuit at a chosen Intensity. Server-validated: at the pad, tier within
# [1, max_intensity]. Not economy-mutating (no dupe surface); lightly rate-limited against spam.
func enter_camp(pid: int, intensity: int) -> void:
	if not _session.has(pid):
		return
	var now := Time.get_ticks_msec()
	if now < int(_camp_next.get(pid, 0)):
		return
	_camp_next[pid] = now + 500
	if not _at_camp_pad(pid):
		return
	var tier := clampi(int(intensity), 1, int(_session[pid].get("max_intensity", 1)))
	var owner := _party_key(pid)                  # gameplay-length P3b-rooms: rotate the room (party-safe — same owner key → same room → shared instance)
	if owner == "":
		owner = str(_session[pid]["fid"])
	var tmpl := _circuit_template(owner, tier)
	var fresh := not _worlds.has("%s#%s#%d" % [tmpl, owner, tier])   # will THIS enter create the instance? (affix only bites on creation)
	# P5: consume the queued Audible. The bonus flag is ALWAYS (re)set from the current pending so a stale flag from an
	# abandoned run can't carry over. The affix override applies + is consumed ONLY on a fresh instance; joining a live
	# instance keeps the affix queued for a future fresh run (not silently burned).
	var pend: Dictionary = _session[pid].get("pending_audible", {})
	var affix_ov := {}
	var new_pend := {}
	if str(pend.get("affix", "")) != "":
		if fresh:
			affix_ov = _affix_by_id(str(pend["affix"]))
		else:
			new_pend["affix"] = str(pend["affix"])   # keep it for the next fresh run
	_session[pid]["run_bonus_drop"] = bool(pend.get("bonus", false))   # (re)set — clears any stale flag from an abandoned run
	_session[pid]["pending_audible"] = new_pend
	_enter_instance(pid, tmpl, tier, affix_ov)

# the Circuit's objective mob died → complete the run for EVERY player in that instance (unlock + bonus loot).
func _on_circuit_clear(key: String) -> void:
	var meta = _instances.get(key)
	if meta == null or bool(meta.get("cleared", false)):
		return
	meta["cleared"] = true
	var tier := int(meta.get("tier", 1))
	var elapsed_ms := Time.get_ticks_msec() - int(meta.get("created_ms", Time.get_ticks_msec()))   # P7d: Circuit fastest-clear time (shared by every player in this instance; monotonic ticks)
	var w = _worlds.get(key)
	if w == null:
		return
	var pids := []                                # snapshot the pids first (grants await + can mutate state)
	for f in w["fighters"]:
		if f["team"] == 0:
			var pid := _pid_by_fid(f["id"])
			if pid >= 0:
				pids.append(pid)
	print("[zone] CIRCUIT CLEAR %s (I%d) for %d player(s)" % [key, tier, pids.size()])
	for pid in pids:
		await _grant_circuit_clear(pid, tier, meta.get("affix", {}), elapsed_ms)

func _grant_circuit_clear(pid: int, tier: int, affix: Dictionary = {}, elapsed_ms: int = 0) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	if tier >= int(s.get("max_intensity", 1)):    # cleared at your ceiling → unlock the next tier (atomic, race-safe)
		if tier < INTENSITY_MAX:
			var nm = await supa.progression_unlock_as(str(s["char_id"]), tier)
			if _session.has(pid) and int(nm) > 0:
				s["max_intensity"] = int(nm)
				_submit_score(str(s["char_id"]), str(s["name"]), "intensity", int(nm) - 1)   # P5: highest Intensity CLEARED

	await _award_pages(pid, int(round((CIRCUIT_CLEAR_PAGES_BASE + tier * CIRCUIT_CLEAR_PAGES_PER_TIER) * float(affix.get("pages", 1.0)))))   # attunement (P2) × this run's baked-in weekly-affix reward mult (P3b)
	# a guaranteed Intensity-scaled bonus drop (a synthetic elite-tier roll) as the clear reward
	if _session.has(pid):
		await _grant_loot(pid, {"mobTier": "elite", "mobLevel": 8, "intensity": maxi(1, tier)})
	# P5: an EXTRA clear drop from the Bird Dog paragon perk (chance) or a queued "Extra Scouting" Audible (guaranteed)
	if _session.has(pid):
		var extra := bool(s.get("run_bonus_drop", false))
		if extra:
			s["run_bonus_drop"] = false
		else:
			var cb := _par_bonus(pid, "scout_clear")   # only draw the (non-deterministic) loot rng when the perk is actually owned
			if cb > 0.0:
				extra = float(_loot_rng.next()) < cb
		if extra:
			await _grant_loot(pid, {"mobTier": "elite", "mobLevel": 8, "intensity": maxi(1, tier)})
	_bounty_on_circuit(pid, tier)                    # gameplay-length P6b: advance any "clear the Circuit" bounty
	if elapsed_ms > 0:                               # gameplay-length P7d: Circuit fastest-clear board (tier-agnostic MVP), inverted so greatest() keeps the fastest
		_submit_score(str(s["char_id"]), str(s["name"]), "circuit_time", CLEAR_CAP_MS - clampi(elapsed_ms, 1, CLEAR_CAP_MS - 1))
	if net != null and _session.has(pid):
		net.recv_circuit_clear.rpc_id(pid, tier, int(_session[pid].get("max_intensity", 1)))

# ---- attunement (P2): Playbook Pages currency + the Master Key craft ----
var _key_busy := {}                              # pid → a key craft is in flight
var _key_next := {}                              # pid → earliest next key op (ms)

func _has_master_key(pid: int) -> bool:
	return _session.has(pid) and bool(_session[pid].get("has_key", false))

# award Playbook Pages (Circuit clears + the boss). Atomic DB add (source of truth) → sync the session total.
func _award_pages(pid: int, amt: int) -> void:
	if amt <= 0 or not _session.has(pid):
		return
	amt = int(round(float(amt) * _par_mult(pid, "recruit_pages")))   # P5: Recruiter "Playbook Study" Bench-Board perk
	if amt <= 0:
		return
	var char_id := str(_session[pid]["char_id"])
	var r = await supa.progression_add_pages_as(char_id, amt)
	if _session.has(pid) and r.get("ok"):
		_session[pid]["pages"] = int(r["total"])

func _key_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_key_busy.get(pid, false)) or now < int(_key_next.get(pid, 0)):
		return false
	_key_busy[pid] = true
	_key_next[pid] = now + 500
	return true

# client → server: forge the Master Key (spend MASTER_KEY_PAGES, set has_key). Dupe-safe: own lock set before
# the await; the spend+set is a single atomic gated DB update (no double-craft / double-spend). Home-gated.
func craft_master_key(pid: int) -> void:
	if not _key_lock(pid):
		return
	await _do_craft_master_key(pid)
	_key_busy.erase(pid)

func _do_craft_master_key(pid: int) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return
	var s = _session[pid]
	if bool(s.get("has_key", false)):
		return                                    # already forged
	if int(s.get("pages", 0)) < MASTER_KEY_PAGES:
		return                                    # not enough pages
	var ok: bool = await supa.progression_craft_key_as(str(s["char_id"]), MASTER_KEY_PAGES)
	if not _session.has(pid):
		return
	if not ok:                                    # lost the atomic race / insufficient → nothing changed
		return
	s["has_key"] = true
	s["pages"] = maxi(0, int(s.get("pages", 0)) - MASTER_KEY_PAGES)
	if net != null:
		net.recv_key_crafted.rpc_id(pid, true)
	print("[zone] %s forged the Master Key" % s["name"])

# ---- talent trees (gameplay-length P4): spend/respec, dupe-safe (own-lock-before-await, atomic gated DB commit) ----
var _tal_busy := {}                              # pid → a talent op is in flight
var _tal_next := {}                              # pid → earliest next talent op (ms)

func _tal_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_tal_busy.get(pid, false)) or now < int(_tal_next.get(pid, 0)):
		return false
	_tal_busy[pid] = true
	_tal_next[pid] = now + 400
	return true

# client → server: put `ranks` points into talent `node`. The server validates node/req/slot/cap/budget; the DB fn
# is the atomic budget+node-ceiling backstop (dupe-safe: own lock set before the await, the DB commit is one gated
# update so a rapid double-send can't double-spend). Then re-fold talents into the stat seam + push the new state.
func spend_talent(pid: int, node: String, ranks: int) -> void:
	if not _tal_lock(pid):
		return
	await _do_spend_talent(pid, node, ranks)
	_tal_busy.erase(pid)

func _do_spend_talent(pid: int, node: String, ranks: int) -> void:
	if not _session.has(pid) or ranks <= 0:
		return
	var s = _session[pid]
	var f = _find(s["fid"])
	if f == null:
		return
	var cls := str(f["classId"])
	var nd := GameData.talent_node_def(cls, node)
	if nd.is_empty():
		return                                    # not a real node for this class
	var talents: Dictionary = s.get("talents", {})
	if int(talents.get(node, 0)) + ranks > int(nd["max"]):
		return                                    # would overfill the node
	if GameData.talent_branch_ranks(talents, cls, str(nd["branch"])) < int(nd["req"]):
		return                                    # branch prerequisite (req cumulative ranks) not met
	var level := int(s["level"])
	if GameData.talent_points_available(level, int(s.get("talent_spent", 0))) < ranks:
		return                                    # not enough unspent points at this level
	var budget := (level - 1) * GameData.TALENT_POINTS_PER_LEVEL
	var res = await supa.talents_spend_as(str(s["char_id"]), node, ranks, budget, int(nd["max"]))
	if not _session.has(pid):
		return
	if not res.get("ok", false):                  # lost the atomic race / insufficient in-DB → nothing changed
		return
	s["talents"] = res["talents"]
	var spent := 0                                 # derive spent from the DB-authoritative map (not a local +=ranks that could drift under a 2nd session)
	for br in GameData.TALENT_BRANCH_ORDER:
		spent += GameData.talent_branch_ranks(res["talents"], cls, br)
	s["talent_spent"] = spent
	await _apply_equipment(pid)                    # re-fold talents into the gear→derive→FORMAT_MODS seam (awaited: it re-reads inventory)
	if net != null and _session.has(pid):
		net.recv_talents.rpc_id(pid, s["talents"], int(s["talent_spent"]))

# client → server: wipe the allocation for TALENT_RESPEC_CREDITS. Dupe-safe: own lock + deduct-before-write
# (charge credits BEFORE the await so a double-send can't pass the affordability check twice); refund on DB failure.
func respec_talents(pid: int) -> void:
	if not _tal_lock(pid):
		return
	await _do_respec_talents(pid)
	_tal_busy.erase(pid)

func _do_respec_talents(pid: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	if int(s.get("talent_spent", 0)) <= 0:
		return                                    # nothing allocated → no charge
	if int(s.get("credits", 0)) < GameData.TALENT_RESPEC_CREDITS:
		return                                    # can't afford
	if _atomic_econ:
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_respec_talents(_op_id(), str(s["char_id"]), GameData.TALENT_RESPEC_CREDITS)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			s["talents"] = {}
			s["talent_spent"] = 0
			if _session.has(pid):
				await _apply_equipment(pid)       # strip the talent stat layer (peer still present)
			if net != null and _session.has(pid):
				net.recv_talents.rpc_id(pid, {}, 0)
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))         # deferred-save contract (busy-lock skipped the logout save)
		return
	if not _legacy_econ_allowed():
		return
	s["credits"] = int(s["credits"]) - GameData.TALENT_RESPEC_CREDITS   # deduct-before-write
	var ok: bool = await supa.talents_respec_as(str(s["char_id"]))
	# ALWAYS reconcile (even if the peer left mid-await) — the captured `s` owns this op's terminal credit save, and
	# _on_peer_disconnected skips its own save while _tal_busy is set, so this write is authoritative (mirrors buy_cosmetic).
	if not ok:                                    # DB reset failed → refund + persist (nothing net-charged)
		s["credits"] = int(s.get("credits", 0)) + GameData.TALENT_RESPEC_CREDITS
		_save_one(s, _find(s["fid"]))
		return
	s["talents"] = {}
	s["talent_spent"] = 0
	if _session.has(pid):
		await _apply_equipment(pid)               # strip the talent stat layer (peer still present)
	_save_one(s, _find(s["fid"]))                  # persist the credit spend (paid even if the peer left)
	if net != null and _session.has(pid):
		net.recv_talents.rpc_id(pid, {}, 0)

# ---- gameplay-length P5: PARAGON ("Overtime") accrual + Bench Board (SET) + Audibles (Pages sink). QoL-only, sim-safe ----
func _paragon_available(pid: int) -> int:
	if not _session.has(pid):
		return 0
	var s = _session[pid]
	return GameData.paragon_available(int(s.get("overtime_xp", 0)), int(s.get("paragon_spent", 0)))

# a Bench-Board perk MULTIPLIER (1.0 + ranks*step), read at a SERVER reward chokepoint — never the deterministic sim
func _par_mult(pid: int, perk: String) -> float:
	if not _session.has(pid) or not GameData.PARAGON_CATALOG.has(perk):
		return 1.0
	var ranks := int((_session[pid].get("paragon_perks", {}) as Dictionary).get(perk, 0))
	return 1.0 + float(ranks) * float(GameData.PARAGON_CATALOG[perk]["step"])

# the additive bonus FRACTION for a chance-based perk (ranks*step)
func _par_bonus(pid: int, perk: String) -> float:
	if not _session.has(pid) or not GameData.PARAGON_CATALOG.has(perk):
		return 0.0
	var ranks := int((_session[pid].get("paragon_perks", {}) as Dictionary).get(perk, 0))
	return float(ranks) * float(GameData.PARAGON_CATALOG[perk]["step"])

func _affix_by_id(id: String) -> Dictionary:
	for a in AFFIX_ROTATION:
		if str(a.get("id", "")) == id:
			return a
	return {}

# divert post-cap XP overflow into the monotonic paragon odometer. In-session accrual is synchronous (immediate); the
# DB flush (monotonic greatest()) fires only on a paragon-level crossing (infrequent) or at logout, so a crash between
# flushes forfeits only sub-level progress — never a spendable point, never an over-grant.
func _accrue_overtime(pid: int, amt: int) -> void:
	if amt <= 0 or not _session.has(pid):
		return
	var s = _session[pid]
	var before := int(s.get("overtime_xp", 0))
	var after := before + amt
	s["overtime_xp"] = after
	if net != null:
		net.recv_overtime.rpc_id(pid, after)      # keep the client paragon bar live (1 int, deliberately NOT in the hash-diffed META → guards the 382f60f anti-bloat fix)
	var lvl_after := GameData.paragon_level(after)
	if lvl_after > GameData.paragon_level(before):   # crossed a paragon level → durable flush + milestone
		var bag := GameData.paragon_gear_bonus(lvl_after)
		s["gear_bag_bonus"] = bag
		await supa.progression_set_overtime_as(str(s["char_id"]), after, bag)
		if net != null and _session.has(pid):
			net.recv_paragon_level.rpc_id(pid, lvl_after, _paragon_available(pid), bag)
		print("[zone] %s → Paragon %d (bag+%d)" % [s["name"], lvl_after, bag])

# ---- Bench Board: client sends the WHOLE proposed board; server validates + idempotent budget-guarded SET ----
var _par_busy := {}
var _par_next := {}

func _par_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_par_busy.get(pid, false)) or now < int(_par_next.get(pid, 0)):
		return false
	_par_busy[pid] = true
	_par_next[pid] = now + 400
	return true

# client → server: set the whole Bench Board. Dupe-safe: own lock before the await; the DB SET is idempotent + budget-
# guarded, so concurrent duplicates converge (respec-free reallocation, never accumulates). QoL perks → no sim/stat touch.
func set_paragon(pid: int, perks: Dictionary) -> void:
	if not _par_lock(pid):
		return
	await _do_set_paragon(pid, perks)
	_par_busy.erase(pid)

func _do_set_paragon(pid: int, perks: Dictionary) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	var clean := {}                               # validate: known perks, ranks in [0, cap]; compute spent
	var spent := 0
	for k in perks:
		if not GameData.PARAGON_CATALOG.has(k):
			continue
		var ranks := clampi(int(perks[k]), 0, int(GameData.PARAGON_CATALOG[k]["cap"]))
		if ranks > 0:
			clean[k] = ranks
			spent += ranks
	var budget := GameData.paragon_level(int(s.get("overtime_xp", 0)))
	if spent > budget:
		return                                    # over budget (the DB SET also guards this)
	if spent > 0:                                 # flush the (monotonic) odometer FIRST so the durable overtime backs this budget — closes the crash-window where paragon_spent could persist ahead of the durable level
		await supa.progression_set_overtime_as(str(s["char_id"]), int(s.get("overtime_xp", 0)), int(s.get("gear_bag_bonus", 0)))
		if not _session.has(pid):
			return
	var res = await supa.paragon_set_as(str(s["char_id"]), clean, spent, budget)
	if not _session.has(pid):
		return
	if not res.get("ok", false):                  # lost the atomic race / over budget in-DB → nothing changed
		return
	s["paragon_perks"] = res["perks"]
	var real_spent := 0                           # derive from the DB-authoritative map (not a local value that could drift)
	for k in res["perks"]:
		real_spent += int(res["perks"][k])
	s["paragon_spent"] = real_spent
	if net != null:
		net.recv_paragon.rpc_id(pid, s["paragon_perks"], real_spent)

# ---- Audibles: buy a per-run consumable with Pages (the repeatable sink), dupe-safe deduct-before-write ----
var _aud_busy := {}
var _aud_next := {}

func _aud_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_aud_busy.get(pid, false)) or now < int(_aud_next.get(pid, 0)):
		return false
	_aud_busy[pid] = true
	_aud_next[pid] = now + 400
	return true

func buy_audible(pid: int, id: String) -> void:
	if not _aud_lock(pid):
		return
	await _do_buy_audible(pid, id)
	_aud_busy.erase(pid)

func _do_buy_audible(pid: int, id: String) -> void:
	if not _session.has(pid) or not GameData.AUDIBLE_CATALOG.has(id):
		return
	var s = _session[pid]
	var def: Dictionary = GameData.AUDIBLE_CATALOG[id]
	var cur: Dictionary = s.get("pending_audible", {})   # already-queued → no-op (never charge Pages for a duplicate effect)
	if str(def["type"]) == "affix" and str(cur.get("affix", "")) == str(def["affix"]):
		return
	if str(def["type"]) == "bonus" and bool(cur.get("bonus", false)):
		return
	var cost := int(def["cost"])
	if int(s.get("pages", 0)) < cost:
		return                                    # can't afford
	var r = await supa.progression_add_pages_as(str(s["char_id"]), -cost)   # deduct-before-write: the atomic underflow-guarded Pages spend (reused, no new fn)
	if not _session.has(pid):
		return
	if not r.get("ok", false):                    # lost the race / insufficient → nothing changed
		return
	s["pages"] = int(r["total"])
	var pend: Dictionary = (s.get("pending_audible", {}) as Dictionary).duplicate()
	if str(def["type"]) == "affix":
		pend["affix"] = str(def["affix"])
	elif str(def["type"]) == "bonus":
		pend["bonus"] = true
	s["pending_audible"] = pend
	if net != null:
		net.recv_audible.rpc_id(pid, pend, int(s["pages"]))

# ---- cosmetics (P4): buy a dye with credits (dupe-safe) + equip it (server-authoritative ownership) ----
var _cos_busy := {}                              # pid → a cosmetics op is in flight
var _cos_next := {}

func _cos_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_cos_busy.get(pid, false)) or now < int(_cos_next.get(pid, 0)):
		return false
	_cos_busy[pid] = true
	_cos_next[pid] = now + 300
	return true

func buy_cosmetic(pid: int, dye_id: String) -> void:
	if not _cos_lock(pid):
		return
	await _do_buy_cosmetic(pid, dye_id)
	_cos_busy.erase(pid)

func _do_buy_cosmetic(pid: int, dye_id: String) -> void:
	if not _session.has(pid) or not GameData.DYE_CATALOG.has(dye_id):
		return
	var s = _session[pid]
	if dye_id in (s.get("cos_owned", []) as Array):
		return                                        # already owned
	if not bool(GameData.DYE_CATALOG[dye_id].get("buyable", true)):
		return                                        # P7d: a grant-only cosmetic (the Season Champion tint) is never purchasable for credits (also avoids a missing-price crash)
	var price := int(GameData.DYE_CATALOG[dye_id]["price"])
	if int(s.get("credits", 0)) < price:
		return
	if _atomic_econ:
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_buy_cosmetic(_op_id(), str(s["char_id"]), dye_id, price)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			if not (dye_id in (s.get("cos_owned", []) as Array)):
				(s["cos_owned"] as Array).append(dye_id)
			if net != null and _session.has(pid):
				net.recv_cosmetics_changed.rpc_id(pid, (s["cos_owned"] as Array).duplicate(), str(s.get("cos_dye", "")))
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))                 # deferred-save contract (busy-lock skipped the logout save)
		return
	if not _legacy_econ_allowed():
		return
	s["credits"] = int(s["credits"]) - price          # deduct up front; refund if the grant fails
	var ok: bool = await supa.cosmetics_grant_as(str(s["char_id"]), dye_id)
	if not ok:                                        # already owned / write failed → refund + persist
		s["credits"] = int(s["credits"]) + price
		_save_one(s, _find(s["fid"]))
		return
	if _session.has(pid):
		(s["cos_owned"] as Array).append(dye_id)
	_save_one(s, _find(s["fid"]))                     # persist the credit spend (paid even if the peer left)
	if net != null and _session.has(pid):
		net.recv_cosmetics_changed.rpc_id(pid, (s["cos_owned"] as Array).duplicate(), str(s.get("cos_dye", "")))

func equip_cosmetic(pid: int, dye_id: String) -> void:
	if not _cos_lock(pid):
		return
	await _do_equip_cosmetic(pid, dye_id)
	_cos_busy.erase(pid)

func _do_equip_cosmetic(pid: int, dye_id: String) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	if dye_id != "" and (not GameData.DYE_CATALOG.has(dye_id) or not (dye_id in (s.get("cos_owned", []) as Array))):
		return                                        # can only equip an owned dye (or "" = default)
	var ok: bool = await supa.cosmetics_equip_as(str(s["char_id"]), dye_id)
	if not _session.has(pid) or not ok:
		return
	s["cos_dye"] = dye_id
	if net != null:
		net.recv_cosmetics_changed.rpc_id(pid, (s["cos_owned"] as Array).duplicate(), dye_id)

# ---- Builder Mode + the Locker Room (P0 foundation) ---------------------------------------------------------
# A one-time 10,000-credit unlock buys a player their private Locker Room (the instanced zone + Home-Base portal
# land in P1). Build items are a new inventory CATEGORY (furniture/props) bought with credits from a Home-Base
# Build Shop pad (build_buy + placement RPCs land in P2/P3). Everything is server-authoritative: credits + item
# grants are server-owned, the unlock is atomic + idempotent + rate-limited + serialized, and hard caps bound
# how much a character can own — which in turn bounds what a Locker Room costs to store + send. No shared/ changes.
const LOCKER_UNLOCK_COST := 10000            # one-time credits to buy access to your Locker Room (§3d, locked)
const BUILD_OWNED_CAP := 50                  # hard cap: total build items a character may own (Build tab + placed)
const BUILD_PER_MODEL_CAP := 20              # anti-hoard: max copies of ONE model (raise toward the owned cap to disable)
# placement bounds (P2): the server NEVER trusts client-sent coords — it clamps every placement into the room.
# = GameData.ARENA_PAD (the walkable margin) so you can only place where you can WALK — no placing in the
# non-walkable strip outside the room's lighter-green floor (playtest ask).
const LOCKER_WALL_MARGIN := 50.0             # matches GameData.ARENA_PAD (fighter movement clamp in Geom.clamp_arena)
const BUILD_H_MIN := 0.4                      # placement scale (height) clamp — catalog props are ~0.8..4 tall
const BUILD_H_MAX := 15.0                     # headroom to size buildings up to a believable scale vs the ~2-unit player
const BUILD_OY_MIN := -1.0                    # vertical-lift (stacking) clamp — can't sink far through the floor
const BUILD_OY_MAX := 8.0
# starter price catalog (§3d) — model id → tier; one central constant, trivial to retune. Every model here is a
# real prop the client already renders (a subset of Client.DECO_PROPS → models/kits/*), so P1/P3 draw them for free.
const BUILD_TIER_PRICE := {"small": 250, "medium": 600, "tree": 1000, "prop": 1500, "large": 4000}
const BUILD_CATALOG := {
	# Small (250) — note: 'cone' from §3d is excluded; it's a special primitive decal kind, not a prop GLB
	"flower_redA": "small", "flower_yellowB": "small", "plant_bush": "small",
	"grass_large": "small", "log_stack": "small",
	# Medium (600)
	"rock_largeA": "medium", "rock_largeC": "medium", "rock_largeE": "medium", "rock_tallC": "medium",
	"stone_largeB": "medium", "plant_bushLarge": "medium", "fence_simple": "medium", "fence_planks": "medium",
	"fence_corner": "medium",
	# Trees (1,000)
	"tree_oak": "tree", "tree_default": "tree", "tree_thin": "tree", "tree_pineRoundC": "tree",
	"tree_palmDetailedTall": "tree",
	# Props (1,500)
	"bag": "prop", "barrier": "prop", "rack": "prop", "chimney-small": "prop", "chimney-medium": "prop",
	"chimney-large": "prop", "detail-tank": "prop",
	# Large (4,000)
	"building-a": "large", "building-c": "large", "building-e": "large", "building-h": "large",
	"building-k": "large", "building-n": "large", "building-q": "large", "building-t": "large", "stadium": "large",
}

# price of a build model in credits, or -1 if it isn't a catalog model (an unknown/forged id can never be bought).
func _build_price(model: String) -> int:
	var tier := str(BUILD_CATALOG.get(model, ""))
	return int(BUILD_TIER_PRICE.get(tier, -1)) if tier != "" else -1

# the build catalog as a pushable list [{model, tier, price}] — for the recv_build_info push + Build Shop UI (P3).
func _build_catalog() -> Array:
	var out := []
	for m in BUILD_CATALOG:
		out.append({"model": m, "tier": str(BUILD_CATALOG[m]), "price": _build_price(m)})
	return out

# cap gate: may this character own one MORE of `model`? Both counts are SERVER-fetched live totals (never client-
# supplied). The 50 total cap bounds stockpile + render (placed ⊆ owned); the 20 per-model cap stops a hoard of one
# prop. build_buy (P2) fetches the counts under its serialized lock and calls this BEFORE granting. Fails closed on
# a negative count (a failed DB fetch → deny rather than grant unbounded).
func _build_within_caps(owned: int, model_owned: int) -> bool:
	return owned >= 0 and model_owned >= 0 and owned < BUILD_OWNED_CAP and model_owned < BUILD_PER_MODEL_CAP

# The 10,000-credit Locker-Room unlock. Its OWN dupe-safe lock (set BEFORE the await); deduct-before-write +
# refund-on-fail; the flag flip itself is atomic + idempotent in the DB (a gated false→true PATCH). Structurally
# identical to _do_buy_cosmetic — a proven, already-reviewed spend path. locker_unlocked is written ONLY here (via
# the gated PATCH), never by _save_one, so no stale session save can ever revert it (monotonic false→true).
var _locker_busy := {}                            # pid -> an unlock op is in flight
var _locker_next := {}                            # pid -> earliest next unlock op (ms)

func _locker_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_locker_busy.get(pid, false)) or now < int(_locker_next.get(pid, 0)):
		return false
	_locker_busy[pid] = true
	_locker_next[pid] = now + 300
	return true

func buy_locker_room(pid: int) -> void:
	if not _locker_lock(pid):
		return
	await _do_buy_locker_room(pid)
	_locker_busy.erase(pid)

func _do_buy_locker_room(pid: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	if bool(s.get("locker_unlocked", false)):
		return                                        # already owned — no charge, no-op (also blocks a re-buy)
	if int(s.get("credits", 0)) < LOCKER_UNLOCK_COST:
		return                                        # server-authoritative affordability check
	if _atomic_econ:
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_unlock_locker(_op_id(), str(s["char_id"]), LOCKER_UNLOCK_COST)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			s["locker_unlocked"] = true               # (captured dict — correct even if the peer just left)
			print("[zone] %s unlocked their Locker Room (−%d cr) — credits→%d" % [s.get("name", "?"), LOCKER_UNLOCK_COST, int(s["credits"])])
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))             # deferred-save contract (busy-lock skipped the logout save)
		return
	if not _legacy_econ_allowed():
		return
	s["credits"] = int(s["credits"]) - LOCKER_UNLOCK_COST   # deduct up front; refund if the flip fails
	var ok: bool = await supa.locker_unlock_as(str(s["char_id"]))   # atomic false→true; true ONLY if WE flipped it
	if not ok:                                        # already unlocked (another session) / write failed → refund + persist
		s["credits"] = int(s["credits"]) + LOCKER_UNLOCK_COST
		_save_one(s, _find(s["fid"]))
		return
	if _session.has(pid):
		s["locker_unlocked"] = true
	_save_one(s, _find(s["fid"]))                     # persist the credit spend (paid even if the peer left mid-buy)
	print("[zone] %s unlocked their Locker Room (−%d cr) — credits→%d" % [s.get("name", "?"), LOCKER_UNLOCK_COST, int(s["credits"])])
	# No client push in P0: the deducted credits reach the client via the next per-tick snapshot (pinfo.credits,
	# already broadcast). The client-facing confirmation + Home-Base portal state land in P1/P3 (which read
	# locker_unlocked from the snapshot / a dedicated recv). buy_locker_room is the P0 RPC surface.

# ---- Builder Mode P2: buy build items + place / move / remove them in your Locker Room. All server-authoritative:
# the server owns credits + item grants + placement (clients send only intents). ONE serialized + rate-limited lock
# for all four (per-character mutations that must not interleave across their DB awaits). build_buy enforces the
# 50 / 20 caps by fetching the live owned counts UNDER the lock and gating BEFORE the insert; place/move/remove are
# gated atomic PATCHes scoped by character_id (dupe-safe — a duplicate/concurrent op matches nothing, and you can't
# touch gear or another character's items). Every mutation refreshes the instance's cached decals (so the room
# re-renders on the next snapshot) and echoes recv_inventory_changed (so the Build tab refreshes). Remove flips
# placed=false (returns the SAME item to the Build tab — no refund, no dupe). ----
var _build_busy := {}                             # pid -> a build op is in flight
var _build_next := {}                             # pid -> earliest next build op (ms)

func _build_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_build_busy.get(pid, false)) or now < int(_build_next.get(pid, 0)):
		return false
	_build_busy[pid] = true
	_build_next[pid] = now + 250
	return true

# safe numeric coercion for a CLIENT-supplied value: accept ONLY an actual finite number — anything else (null,
# Array, Dict, Vector2, String, bool, NaN, Inf) → the default. Required because float() THROWS on a non-numeric
# Variant and clampf/wrapf pass NaN/Inf straight through (a NaN would persist as JSON null and break the render).
func _safe_num(v, def: float) -> float:
	if v is float or v is int:
		var f := float(v)
		return f if is_finite(f) else def
	return def

# sanitize a CLIENT-supplied placement transform — never trust its coords. Clamp x/y inside the room walls, the
# scale (h) and lift (oy) to sane ranges, and wrap yaw. Every field goes through _safe_num first (untrusted input),
# so a missing/NaN/Inf/non-numeric value can't crash the handler or persist junk. Returns ONLY the transform keys.
func _clamp_locker_xform(xform) -> Dictionary:
	var xf: Dictionary = xform if xform is Dictionary else {}
	var c := World.cfg(World.LOCKER)
	var w := float(c.get("w", 700))
	var h := float(c.get("h", 460))
	return {
		"x": clampf(_safe_num(xf.get("x"), w * 0.5), LOCKER_WALL_MARGIN, w - LOCKER_WALL_MARGIN),
		"y": clampf(_safe_num(xf.get("y"), h * 0.5), LOCKER_WALL_MARGIN, h - LOCKER_WALL_MARGIN),
		"h": clampf(_safe_num(xf.get("h"), 2.0), BUILD_H_MIN, BUILD_H_MAX),
		"oy": clampf(_safe_num(xf.get("oy"), 0.0), BUILD_OY_MIN, BUILD_OY_MAX),
		"yaw": wrapf(_safe_num(xf.get("yaw"), 0.0), -PI, PI),
	}

# is the player standing in THEIR OWN Locker Room right now? place/move/remove only make sense there, and the
# instance's owner segment == their char_id — so this also proves they can only ever edit their own room.
func _in_own_locker(pid: int) -> bool:
	if not _session.has(pid):
		return false
	var key: String = str(_session[pid]["map"])
	if _template(key) != World.LOCKER:
		return false
	var meta = _instances.get(key)
	return meta != null and str((meta as Dictionary).get("owner", "")) == str(_session[pid]["char_id"])

# re-query the character's placed items → rebuild the instance's cached decals (so the room re-renders next
# snapshot). Cheap (≤ BUILD_OWNED_CAP rows) and only on a deliberate place/move/remove, never per frame.
func _refresh_locker_decals(pid: int) -> void:
	if not _session.has(pid):
		return
	var key: String = str(_session[pid]["map"])
	if _template(key) != World.LOCKER:
		return
	var rows = await supa.get_placed_build_items_as(_session[pid]["access"], str(_session[pid]["char_id"]))
	var meta = _instances.get(key)                    # re-check after the await (the instance may have torn down)
	if meta != null and rows is Array:                # rows == null → transient read error; KEEP the prior cache (don't blank the room)
		meta["decals"] = _locker_decals(rows)

func build_buy(pid: int, model: String) -> void:
	if not _build_lock(pid):
		return
	await _do_build_buy(pid, model)
	_build_busy.erase(pid)

func _do_build_buy(pid: int, model: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME:
		return                                        # the Build Shop pad is in the home base (like the shop/forge)
	var price := _build_price(model)
	if price < 0:
		return                                        # not a catalog model — an unknown/forged id can never be bought
	var s = _session[pid]
	if int(s.get("credits", 0)) < price:
		return
	var models = await supa.build_owned_models_as(str(s["char_id"]))   # live counts UNDER the lock; null → fail closed
	if not _session.has(pid) or models == null:
		return
	var owned := (models as Array).size()
	var model_owned := 0
	for mm in (models as Array):
		if str(mm) == model:
			model_owned += 1
	if not _build_within_caps(owned, model_owned):
		return                                        # at the 50 total or 20 per-model cap → no-op
	if _atomic_econ:
		await _flush_awards(s)
		var bitem := {"category": "build", "model": model, "name": model, "rarity": "common", "slot": "build"}
		await _econ_begin(s)
		var ar = await supa.econ_buy_item(_op_id(), str(s["char_id"]), price, 0, bitem)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			if net != null and _session.has(pid):
				net.recv_inventory_changed.rpc_id(pid)
			print("[zone] %s bought build item '%s' (−%d cr)" % [s.get("name", "?"), model, price])
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))             # deferred-save contract (busy-lock skipped the logout save)
		return
	if not _legacy_econ_allowed():
		return
	s["credits"] = int(s["credits"]) - price          # deduct up front; refund if the insert fails
	var r = await supa.add_build_item_as(str(s["char_id"]), model)
	if not r.get("ok"):
		s["credits"] = int(s["credits"]) + price      # refund + persist (paid even if the peer left mid-buy)
		_save_one(s, _find(s["fid"]))
		return
	_save_one(s, _find(s["fid"]))                     # persist the credit spend
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)
	print("[zone] %s bought build item '%s' (−%d cr)" % [s.get("name", "?"), model, price])

func build_place(pid: int, item_id: String, xform: Dictionary) -> void:
	if not _build_lock(pid):
		return
	await _do_build_place(pid, item_id, xform)
	_build_busy.erase(pid)

func _do_build_place(pid: int, item_id: String, xform) -> void:
	if not _in_own_locker(pid) or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var r = await supa.build_place_as(str(s["char_id"]), item_id, _clamp_locker_xform(xform))
	if not r.get("ok"):
		return                                        # not yours / already placed / not a build item → no-op
	await _refresh_locker_decals(pid)
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

func build_move(pid: int, item_id: String, xform: Dictionary) -> void:
	if not _build_lock(pid):
		return
	await _do_build_move(pid, item_id, xform)
	_build_busy.erase(pid)

func _do_build_move(pid: int, item_id: String, xform) -> void:
	if not _in_own_locker(pid) or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var r = await supa.build_move_as(str(s["char_id"]), item_id, _clamp_locker_xform(xform))
	if not r.get("ok"):
		return
	await _refresh_locker_decals(pid)
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

func build_remove(pid: int, item_id: String) -> void:
	if not _build_lock(pid):
		return
	await _do_build_remove(pid, item_id)
	_build_busy.erase(pid)

func _do_build_remove(pid: int, item_id: String) -> void:
	if not _in_own_locker(pid) or not _is_uuid(item_id):
		return
	var s = _session[pid]
	var r = await supa.build_remove_as(str(s["char_id"]), item_id)
	if not r.get("ok"):
		return                                        # not placed / not yours → no-op
	await _refresh_locker_decals(pid)
	if net != null and _session.has(pid):
		net.recv_inventory_changed.rpc_id(pid)

# ---- Two-Minute Drill (P5): instanced endless wave survival → a leaderboard score ----
# enter the Drill (P7d: party-keyed — party-mates share one instance/wave, each scored + rewarded individually;
# solo owns it by fid). Called from _check_portals (auto entry on the drill pad).
func _enter_drill(pid: int) -> void:
	if not _session.has(pid):
		return
	var f = _find(_session[pid]["fid"])
	if f == null:
		return
	var owner := _party_key(pid)                      # gameplay-length P7d: party-mates share ONE Drill instance (each is scored + rewarded individually)
	if owner == "":
		owner = str(_session[pid]["fid"])             # solo → own the instance by fighter id
	var key := _ensure_instance(World.DRILL, owner, 1)
	_relocate(f, _session[pid], key, World.spawn_for(World.DRILL))
	f["drillEngaged"] = false                          # P7d: reset this entrant's per-run engagement flag (anti-leech gate at run end)
	f["drillDmg0"] = float(f.get("dmgDealt", 0.0))     # P7d: snapshot lifetime dmg at entry → the gate compares a DELTA (dmgDealt is cumulative, reset only on _revive, so pre-entry damage can't forge engagement)
	var meta = _instances.get(key)
	if meta != null and not bool(meta.get("active", false)):   # start a run ONLY if none is live here (fresh instance OR a prior run ended) — a mid-run party-mate just drops into the current wave, no reset
		meta["mode"] = "drill"
		meta["wave"] = 0
		meta["active"] = true
		meta["next_wave_t"] = 0
		_advance_drill_wave(key)                       # spawn wave 1

func _advance_drill_wave(key: String) -> void:
	var meta = _instances.get(key)
	if meta == null:
		return
	var w = _worlds.get(key)                          # cull the cleared wave's corpses (instance mobs don't respawn
	if w != null:                                     # + aren't removed on death) so an endless run can't grow unbounded
		var dead := []
		for f in w["fighters"]:
			if f["team"] == 1 and not f["alive"]:
				dead.append(str(f["id"]))
		for fid in dead:
			_remove_fighter(fid)
	meta["wave"] = int(meta.get("wave", 0)) + 1
	meta["next_wave_t"] = 0
	_spawn_drill_wave(key, int(meta["wave"]))

# spawn a wave: count + level + Intensity all ramp with the wave number (a mini-boss every 5th). Drill mobs are
# tagged isDrill → no loot/xp/credits (the reward is the run score). Deterministic placement (ring, no rng).
func _spawn_drill_wave(key: String, wave: int) -> void:
	var w = _worlds.get(key)
	if w == null:
		return
	var count := clampi(2 + wave, 2, 10)              # solo baseline
	var players := 0                                  # P7d: real-player roster in this instance (bots don't inflate the wave)
	for pf in w["fighters"]:
		if int(pf["team"]) == 0 and not pf.get("resident", false):
			players += 1
	if players > 1:                                   # party → proportionally bigger waves so a group's higher waves are earned (solo is byte-identical)
		count = clampi(count * players, count, 8 + players * 5)
		var _pm = _instances.get(key)
		if _pm != null:
			_pm["party_run"] = true                    # P7d: a run that ever had 2+ real players is a PARTY run → excluded from the SOLO skill leaderboard (still gives per-member rewards)
	var pool := ["cone_swarmer", "foam_dummy", "shooting_dummy", "tackle_brute", "spring_cone", "tire_dummy", "chalk_liner", "whistle_cone", "pop_dummy", "iron_sled", "gatling_machine", "blitz_captain", "tackle_captain"]   # gameplay-length P3/P3b: roster remix widens the Drill variety (minions + elites)
	var lvl := clampi(1 + wave, 1, 20)
	var cx := float(w.get("arenaW", GameData.ARENA_W)) * 0.5
	var cy := float(w.get("arenaH", GameData.ARENA_H)) * 0.5
	var rad := minf(cx, cy) * 0.72
	for i in count:
		var cls: String = pool[(wave + i) % pool.size()]
		var ang: float = TAU * float(i) / float(count)
		var pos := Vector2(cx + cos(ang) * rad, cy + sin(ang) * rad)
		var fid := _spawn_fighter(cls, 1, pos, key)
		var m = _find(fid)
		if m == null:
			continue
		m["mobLevel"] = lvl
		m["mobTier"] = "elite" if (wave % 5 == 0 and i == 0) else "minion"   # a tougher anchor every 5 waves
		m["intensity"] = 1 + int(wave / 3)          # difficulty ramp via the Intensity multiplier
		m["isDrill"] = true
		_scale_mob(m)

# per-frame drill driver (called after _check_portals): advance waves + detect the run's end.
func _tick_drills() -> void:
	var now := Time.get_ticks_msec()
	for key in _instances.keys():
		var meta = _instances[key]
		if str(meta.get("mode", "")) != "drill" or not bool(meta.get("active", false)):
			continue
		var w = _worlds.get(key)
		if w == null:
			continue
		var any_player_alive := false
		var mobs_alive := 0
		for f in w["fighters"]:
			if int(f["team"]) == 0 and not f.get("resident", false):   # P7d: REAL players only — a companion can't keep a run alive after all real players are down
				if f["alive"]:
					any_player_alive = true
				if not bool(f.get("drillEngaged", false)) and (float(f.get("dmgDealt", 0.0)) > float(f.get("drillDmg0", 0.0)) or float(f.get("noDmgT", 999.0)) < RESIDENT_ENGAGED_S):
					f["drillEngaged"] = true          # P7d: sticky — fought this run → eligible for the end reward (anti-leech, mirrors the party-XP engaged gate)
			elif f["team"] == 1 and f["alive"]:
				mobs_alive += 1
		if not any_player_alive:                     # the player fell → end the run
			_end_drill(key)
			continue
		if mobs_alive == 0:                          # wave cleared → next after a short gap
			if int(meta.get("next_wave_t", 0)) == 0:
				meta["next_wave_t"] = now + DRILL_WAVE_GAP_MS
			elif now >= int(meta["next_wave_t"]):
				_advance_drill_wave(key)

func _end_drill(key: String) -> void:
	var meta = _instances.get(key)
	if meta == null or not bool(meta.get("active", false)):
		return
	meta["active"] = false
	var wave := int(meta.get("wave", 0))
	var w = _worlds.get(key)
	if w == null:
		return
	var party_run := bool(meta.get("party_run", false))   # P7d: a run that ever had 2+ real players doesn't post to the SOLO skill board
	var pids := []                                    # ALL real players in the instance — everyone is sent home; only ENGAGED members are rewarded
	for f in w["fighters"]:
		if int(f["team"]) == 0 and not f.get("resident", false):
			var p := _pid_by_fid(str(f["id"]))
			if p >= 0 and not pids.has(p):
				pids.append(p)
	for pid in pids:
		if not _session.has(pid):
			continue
		var s = _session[pid]
		var pf = _find(s["fid"])
		if pf != null and bool(pf.get("drillEngaged", false)):   # P7d: only members who actually fought get the run rewards (anti-leech; a passive/dead alt banks nothing)
			# pages only from a REAL run (wave 3+) so a fresh char can't death-farm wave 1 faster than the Circuit chase
			_award_pages(pid, maxi(0, wave - 2) * DRILL_PAGES_PER_WAVE)
			_award_credits(pid, wave * DRILL_CREDITS_PER_WAVE)
			# gameplay-length P1: the endless Drill feeds the level bar — a capped, level-relative payout (waves 3+)
			var _need := _xp_to_next(int(s["level"]))
			var _drill_xp := int(minf(_need * DRILL_XP_RUN_CAP_FRAC, float(maxi(0, wave - 2)) * _need * DRILL_XP_WAVE_FRAC))
			if _drill_xp > 0:
				_award_xp(pid, _drill_xp)
			if not party_run:                          # the "drill" leaderboard is a SOLO skill board — party runs give rewards but don't post a score (fairness)
				_submit_score(str(s["char_id"]), str(s["name"]), "drill", wave)
			_bounty_on_drill(pid, wave)                # gameplay-length P6b: advance any "reach Drill wave N" bounty
			if net != null:
				net.recv_drill_end.rpc_id(pid, wave)
		if pf != null:
			_relocate(pf, s, World.HOME, World.HOME_SPAWN)   # everyone goes home (revive on arrival) regardless of engagement
			_respawn.erase(pf["id"])
			_revive(pf)
		_save_one(s, _find(s["fid"]))

# ---- leaderboards (P5): server-authoritative scores; clients read the board via an RPC ----
var _lb_next := {}                               # pid → earliest next fetch (rate limit)

# gameplay-length P7d: leaderboard SEASONS + clear-time boards.
const SEASON_SECS := WEEK_SECS                   # a season = one UTC week (skill boards reset weekly)
const CLEAR_CAP_MS := 3600000                    # clear-time boards store CLEAR_CAP_MS - elapsed_ms (inversion → greatest() keeps the FASTEST; a >60min run clamps to worst, not dropped)
const SEASONAL_CATS := ["drill", "circuit_time", "boss_time"]   # reset weekly; gear/intensity stay ALL-TIME (season 0 — cumulative ceilings)
func _current_season() -> int:
	return int(Time.get_unix_time_from_system() / SEASON_SECS)   # orchestration time (never the deterministic sim), like _current_affix
func _season_of(category: String) -> int:
	return _current_season() if SEASONAL_CATS.has(category) else 0

func _submit_score(char_id: String, name: String, category: String, score: int) -> void:
	if score <= 0 or supa == null:
		return
	await supa.leaderboard_submit_as(category, _season_of(category), char_id, name, score)   # season-aware; keeps the personal best

func fetch_leaderboard(pid: int, category: String) -> void:
	if not _session.has(pid):
		return
	var now := Time.get_ticks_msec()
	if now < int(_lb_next.get(pid, 0)):
		return
	_lb_next[pid] = now + 300                         # short enough that a normal tab-switch isn't dropped
	if not ["drill", "gear", "intensity", "circuit_time", "boss_time"].has(category):
		return
	var seas := _season_of(category)
	var reset_unix := (seas + 1) * SEASON_SECS if SEASONAL_CATS.has(category) else 0   # P7d: next-reset epoch for the seasonal tabs (0 = all-time board)
	var r = await supa.leaderboard_top_as(category, seas, 20)
	if net != null and _session.has(pid):
		net.recv_leaderboard.rpc_id(pid, category, r.get("entries", []), seas, reset_unix)

# gameplay-length P7d: lazy weekly-Champion cosmetic. On login, if a NEW season started since this char last settled,
# grant the Season Champion dye if it placed rank-1 on ANY seasonal board in the JUST-ended season, then advance
# last_season (a guarded CAS so the scan runs once). Grant-then-settle: cosmetics_grant is idempotent (the real dupe
# guard); season_claim only stops re-scanning. No cron — rides the player's login. Awards only the immediately-prior
# season (absent for multiple weeks forfeits older placements — avoids a multi-season scan).
func _maybe_award_season(pid: int) -> void:
	if not _session.has(pid) or supa == null:
		return
	var s = _session[pid]
	var cur := _current_season()
	var last := int(s.get("last_season", 0))
	if last >= cur:
		return
	# Scan the just-ended season for a rank-1 placement. NO special-case for last==0: a brand-new / pre-P7d char
	# simply ranks 0 (the prior season's board is empty for them) → no reward, and merging the paths makes it
	# self-healing — a failed first settle leaves the DB-authoritative last_season behind, so the NEXT login
	# re-scans + re-grants (idempotent) rather than silently skipping the char's first placement.
	var champ := false
	for cat in SEASONAL_CATS:                         # rank-1 on ANY seasonal board in the just-ended season = Champion
		var rank: int = await supa.leaderboard_rank_as(cat, cur - 1, str(s["char_id"]))   # annotate: := can't infer from an await result (CLAUDE.md gotcha)
		if not _session.has(pid):
			return
		if rank == 1:
			champ = true
			break
	if champ:
		var ok: bool = await supa.cosmetics_grant_as(str(s["char_id"]), "champion")
		if ok and _session.has(pid):                 # fold into the live session + push (mirrors the quest-dye path)
			var owned: Array = _session[pid].get("cos_owned", [])
			if not ("champion" in owned):
				owned.append("champion")
			if net != null:
				net.recv_cosmetics_changed.rpc_id(pid, owned.duplicate(), str(_session[pid].get("cos_dye", "")))
	await supa.season_claim_as(str(s["char_id"]), cur)
	if _session.has(pid):
		_session[pid]["last_season"] = cur

# ---- connection / auth ----
# transport seams (overridden by the headless stabilization tests, which run with no ENet peer):
# is this peer still connected at the transport layer?
func _peer_live(pid: int) -> bool:
	return multiplayer.has_multiplayer_peer() and (pid in multiplayer.get_peers())

# drop a peer. `reason` is a non-sensitive, player-facing explanation (logged; delivered to the
# client via the deny channel where one exists).
func _kick(pid: int, reason := "") -> void:
	if reason != "":
		print("[zone] kicking peer %d — %s" % [pid, reason])
		if net != null:                          # tell the player WHY before the drop (reliable; ENet
			net.recv_denied.rpc_id(pid, reason)  # flushes queued packets on a non-forced disconnect)
	_transport_kick(pid)

# transport seam: actually drop the peer (overridden by the headless tests, which have no ENet peer).
# GRACE before the drop: the recv_denied RPC queued in _kick sits in SceneMultiplayer's OUTGOING
# buffer and isn't handed to ENet until the next multiplayer poll. disconnect_peer() synchronously in
# the same frame therefore severs the link before the reason packet is even sent — the client only
# sees the generic transport-drop message (confirmed live). A short wall-clock grace lets the poll
# flush the reliable RPC into ENet first; disconnect_peer(force=false) then drains it to the client.
const KICK_GRACE_S := 0.4
func _transport_kick(pid: int) -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	await get_tree().create_timer(KICK_GRACE_S).timeout
	if multiplayer.has_multiplayer_peer() and pid in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(pid)

func _on_peer_connected(pid: int) -> void:
	print("[zone] peer %d connected — awaiting auth" % pid)

func _on_peer_disconnected(pid: int) -> void:
	_authing.erase(pid)
	if not _session.has(pid):
		return
	var s = _session[pid]                        # capture before erasing (the save coroutine holds it)
	s["_gone"] = true                            # in-flight econ coroutines route failed award packets to the orphan queue
	if int(_char_peer.get(str(s["char_id"]), -1)) == pid:   # release the single-session claim (P2);
		_char_peer.erase(str(s["char_id"]))                 # the == pid guard never frees another peer's claim
	if supa != null:                             # gameplay-length P1(d): persist remaining rested pool + stamp offline time
		supa.progression_rest_logout_as(str(s["char_id"]), int(s.get("rested_xp", 0)))
	if supa != null and int(s.get("overtime_xp", 0)) > 0:   # gameplay-length P5: flush the running paragon Overtime (monotonic greatest() → safe even if a level flush already ran)
		supa.progression_set_overtime_as(str(s["char_id"]), int(s.get("overtime_xp", 0)), int(s.get("gear_bag_bonus", 0)))
	if not bool(_sellmany_busy.get(pid, false)) and not bool(_forge_busy.get(pid, false)) and not bool(_vendor_busy.get(pid, false)) and not bool(_shop_busy.get(pid, false)) and not bool(_cos_busy.get(pid, false)) and not bool(_locker_busy.get(pid, false)) and not bool(_build_busy.get(pid, false)) and not bool(_tal_busy.get(pid, false)):
		_save_one(s, _find(s["fid"]))            # an in-flight bulk-sell / upgrade / vendor-buy / shop-buy / dye-buy / locker-unlock / build-buy / talent-respec owns its OWN terminal
												 # its OWN terminal save; saving here too would race that credit
												 # write (a stale absolute write could clobber it). Skip it.
	_release_residents_of(pid)                   # RP2: release any recruited companions back to their director
	_party_leave(pid)                            # drop out of any party (and disband if it falls below 2)
	for tk in _party_invites.keys():             # sweep invites this peer SENT (keyed by target) so a stale
		if int((_party_invites[tk] as Dictionary).get("from", -1)) == pid:   # entry can't block the target's re-invites for 30s
			_party_invites.erase(tk)
	var left_map: String = str(s.get("map", ""))
	var lmeta = _instances.get(left_map)         # rage-quit mid-Drill → still record the wave reached
	if lmeta != null and str(lmeta.get("mode", "")) == "drill" and bool(lmeta.get("active", false)) and not bool(lmeta.get("party_run", false)):
		_submit_score(str(s["char_id"]), str(s["name"]), "drill", int(lmeta.get("wave", 0)))   # P7d: solo runs only — a party run never posts to the solo skill board (even on rage-quit)
	_remove_fighter(s["fid"])
	_maybe_teardown_instance(left_map)           # last player out of a private instance → tear it down
	_lb_next.erase(pid)
	_gate_prompt_next.erase(pid)
	_peers.erase(pid)
	_session.erase(pid)
	_move.erase(pid)
	_pending_ability.erase(pid)
	_last_aseq.erase(pid)
	_hop_next.erase(pid)
	_hop_t0.erase(s["fid"])                       # Phase 0.5: drop the cosmetic-hop timestamp for this fighter
	_intent_age.erase(pid)
	_meta_hash.erase(pid)
	_meta_tick.erase(pid)
	_chat_next.erase(pid)
	_equipping.erase(pid)
	_equip_next.erase(pid)
	_party_invite_next.erase(pid)
	_tal_busy.erase(pid)
	_tal_next.erase(pid)
	_par_busy.erase(pid)
	_par_next.erase(pid)
	_aud_busy.erase(pid)
	_aud_next.erase(pid)
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
	_bounty_busy.erase(pid)
	_bounty_next.erase(pid)
	_camp_next.erase(pid)
	_key_busy.erase(pid)
	_key_next.erase(pid)
	_cos_busy.erase(pid)
	_cos_next.erase(pid)
	_locker_busy.erase(pid)
	_locker_next.erase(pid)
	_build_busy.erase(pid)
	_build_next.erase(pid)
	print("[zone] peer %d left" % pid)

func authenticate(pid: int, access: String, hello: Dictionary = {}) -> void:
	if pid in _peers or _authing.has(pid) or supa == null:
		return
	# ---- PROTOCOL GATE (stabilization P5): validate the client's protocol version BEFORE any token
	# work. Missing/older/newer all refuse with a player-facing reason; nothing (no DB call, no
	# session, no claim) happens for an incompatible client. Bump rules: shared/Protocol.gd. ----
	var pv := Protocol.hello_version(hello)
	if not Protocol.compatible(pv):
		if pv == 0:
			_kick(pid, "This client is out of date (no protocol version; server runs v%d). Please update your client." % Protocol.VERSION)
		elif pv < Protocol.VERSION:
			_kick(pid, "This client is out of date (protocol v%d, server v%d). Please update your client." % [pv, Protocol.VERSION])
		else:
			_kick(pid, "This client (protocol v%d) is newer than the server (v%d) — the zone needs an update." % [pv, Protocol.VERSION])
		return
	_authing[pid] = true
	var res = await supa.get_character_as(access)
	_authing.erase(pid)
	if not _peer_live(pid) or pid in _peers:
		return
	if not res.get("ok") or res.get("character") == null:
		print("[zone] peer %d auth failed (%s) — kicking" % [pid, res.get("error", "no character")])
		_kick(pid, "Authentication failed — please sign in again.")
		return
	var ch = res["character"]
	# ---- SINGLE ACTIVE SESSION (stabilization P2): one character, one controlling peer. Policy:
	# REJECT the second connection (no takeover). The check-and-claim below has NO await between the
	# lookup and the write, and the claim→session creation below is likewise await-free — so two
	# in-flight authentications for the same character resolve deterministically to ONE winner, and a
	# claim can never exist without its session (the disconnect handler releases both together). ----
	var claim_cid := str(ch["id"])
	if _char_peer.has(claim_cid):
		var holder := int(_char_peer[claim_cid])
		if _session.has(holder):                 # live holder → refuse the newcomer, keep the session
			print("[zone] peer %d refused — character '%s' already online as peer %d" % [pid, ch.get("name", "?"), holder])
			_kick(pid, "That character is already online from another connection. Log the other session out first (a dropped session frees up within ~30s).")
			return
		_char_peer.erase(claim_cid)              # stale claim with no session (defensive) → reclaimable
	_char_peer[claim_cid] = pid
	# defensive clamps: characters is server-authoritative for economy/progression, but clamp on load so a
	# malformed/tampered DB row can never grant god-mode HP (huge level) or negative currency. (See the
	# characters_guard_progression migration — the DB pins these columns against non-service-role writes.)
	var lvl := clampi(int(ch.get("level", 1)), 1, 99)
	var fid := _spawn_player(ch, lvl)
	var pf = _find(fid)
	_peers.append(pid)
	_session[pid] = {"fid": fid, "access": access, "char_id": str(ch["id"]),
		"name": str(ch.get("name", "?")), "xp": maxi(0, int(ch.get("xp", 0))), "level": lvl,
		"map": str(pf["map"]) if pf != null else World.HOME, "party": [], "credits": maxi(0, int(ch.get("credits", 0))),
		"scrap": 0, "tokens": maxi(0, int(ch.get("practice_tokens", 0))), "quests": {},
		"max_intensity": 1, "pages": 0, "has_key": false, "cos_owned": [], "cos_dye": "",
		"locker_unlocked": bool(ch.get("locker_unlocked", false)),
		"ability_ungated": GameData.ability_grandfathered(ch.get("created_at", "")),   # gameplay-length P2: pre-gating chars keep the full kit
		"rested_xp": 0,   # gameplay-length P1(d): offline rested pool, accrued just below at login
		"talents": {}, "talent_spent": 0,   # gameplay-length P4: talent allocation (loaded from the progression table below)
		"overtime_xp": 0, "paragon_perks": {}, "paragon_spent": 0, "gear_bag_bonus": 0, "pending_audible": {},   # gameplay-length P5: paragon + Audible state (loaded below)
		"bounties": {}, "bounty_claims": {}, "last_season": 0}   # gameplay-length P6b: bounty progress/ledger + P7d last-settled season (loaded below)
	_move[pid] = {"mx": 0.0, "my": 0.0}
	_pending_ability[pid] = ""
	_last_aseq[pid] = 0
	_intent_age[pid] = 0
	net.assign_fighter.rpc_id(pid, fid)
	net.recv_shop_info.rpc_id(pid, {"catalog": _catalog(), "roll": ROLL_PRICE, "sell": SELL_PRICE})
	net.recv_vendor_info.rpc_id(pid, {"catalog": _token_catalog()})   # the Practice Vendor (Rookie Camp set)
	net.recv_build_info.rpc_id(pid, {"catalog": _build_catalog(), "unlock_cost": LOCKER_UNLOCK_COST,
		"owned_cap": BUILD_OWNED_CAP, "model_cap": BUILD_PER_MODEL_CAP})   # Builder Mode: Build Shop catalog + caps (P3)
	var mr = await supa.get_mats_as(access)           # load the player's salvage materials into the session
	if _session.has(pid):
		_session[pid]["scrap"] = int(mr.get("scrap", 0))
	var pr = await supa.get_progression_as(access)    # load the Camp Circuit Intensity ladder + Playbook Pages + Master Key
	if _session.has(pid):
		_session[pid]["max_intensity"] = maxi(1, int(pr.get("max_intensity", 1)))
		_session[pid]["pages"] = maxi(0, int(pr.get("pages", 0)))
		_session[pid]["has_key"] = bool(pr.get("has_key", false))
		var _tal = pr.get("talents", {})                # gameplay-length P4: load the talent allocation (existing chars default to {} → all points unspent)
		_session[pid]["talents"] = (_tal if _tal is Dictionary else {})
		_session[pid]["talent_spent"] = maxi(0, int(pr.get("talent_spent", 0)))
		var _par = pr.get("paragon_perks", {})          # gameplay-length P5: load paragon Overtime + Bench Board
		_session[pid]["overtime_xp"] = maxi(0, int(pr.get("overtime_xp", 0)))
		_session[pid]["paragon_perks"] = (_par if _par is Dictionary else {})
		_session[pid]["paragon_spent"] = maxi(0, int(pr.get("paragon_spent", 0)))
		_session[pid]["gear_bag_bonus"] = maxi(0, int(pr.get("gear_bag_bonus", 0)))
		var _bc = pr.get("bounty_claims", {})           # gameplay-length P6b: load the per-period bounty claim ledger
		_session[pid]["bounty_claims"] = (_bc if _bc is Dictionary else {})
		_session[pid]["last_season"] = maxi(0, int(pr.get("last_season", 0)))   # gameplay-length P7d: last settled leaderboard season
		if net != null and int(_session[pid]["overtime_xp"]) > 0:   # seed the client paragon bar on login (live value, not in the hashed META)
			net.recv_overtime.rpc_id(pid, int(_session[pid]["overtime_xp"]))
	if _session.has(pid):                             # gameplay-length P1(d): accrue the offline rested-XP pool at login (rate/cap level-scaled)
		var _rneed := _xp_to_next(maxi(1, int(_session[pid]["level"])))
		var _rest = await supa.progression_rest_login_as(str(_session[pid]["char_id"]), float(_rneed) * RESTED_RATE_FRAC, int(_rneed * RESTED_CAP_FRAC))
		if _session.has(pid):
			_session[pid]["rested_xp"] = maxi(0, int(_rest))
	var cos = await supa.get_cosmetics_as(access)     # load owned dyes + the equipped dye (P4 cosmetics)
	if _session.has(pid):
		_session[pid]["cos_owned"] = cos.get("owned", [])
		_session[pid]["cos_dye"] = str(cos.get("equipped", ""))
	await _maybe_award_season(pid)                    # gameplay-length P7d: lazy weekly-Champion cosmetic (needs cos_owned + last_season loaded above)
	await _apply_equipment(pid)                       # re-derive stats from saved equipment
	await _load_quests(pid)                           # load + push the player's quest progress
	# GATE RE-VALIDATION: _spawn_player restores last_map (client-writable position columns) BEFORE quests/key
	# are known, so re-check the restored map against its entry gate now that they're loaded — a client that
	# PATCHed last_map to a gated zone (or a pre-P2 logout inside it) is sent HOME instead of spawning past the gate.
	if _session.has(pid):
		var gpf = _find(_session[pid]["fid"])
		if gpf != null:
			var gate := World.gate_for_map(str(gpf["map"]))
			# gear_unknown: the inventory fetch failed transiently → item_power is 0-by-accident, not 0-by-fact.
			# Skip ONLY the relocate (never bounce a geared player on a DB blip); pad USE still re-checks live.
			if gate != "" and not _portal_unlocked(pid, gate) and not bool(_session[pid].get("gear_unknown", false)):
				_relocate(gpf, _session[pid], World.HOME, World.HOME_SPAWN)
	if _session.has(pid):                             # admin powers, gated on the service-role admins table
		var is_admin: bool = await supa.is_admin_as(str(ch.get("user_id", "")))
		if not _session.has(pid):                     # the peer may drop during the admin lookup — bail
			return                                    # (was an unguarded _session[pid] → script error)
		_session[pid]["admin"] = is_admin
		if is_admin and net != null:
			net.recv_admin.rpc_id(pid, true)
			print("[zone] %s authenticated as ADMIN" % ch.get("name", "?"))
	if not _session.has(pid):
		return
	print("[zone] %s (%s, lvl %d) joined as %s in '%s' — now %d player(s)" % [ch.get("name", "?"), ch.get("class", "?"), lvl, fid, _session[pid]["map"], _peers.size()])

func reauth(pid: int, access: String) -> void:
	if not _session.has(pid) or access == "":
		return
	# re-validate the incoming token belongs to THIS session's character before trusting it — else a client
	# could reauth with another account's token and make token-scoped reads (get_inventory_as / _apply_equipment)
	# operate on that account's data. reauth runs ~every 25 min, so the extra round-trip is negligible.
	var res = await supa.get_character_as(access)
	if not _session.has(pid):
		return
	var ch = res.get("character")
	if res.get("ok") and ch != null and str((ch as Dictionary).get("id", "")) == str(_session[pid]["char_id"]):
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
	# never spawn straight into an instance from a restored last_map. last_map is a CLIENT-WRITABLE position column,
	# so a tampered value like "locker_room#<other>#1" or "camp#<owner>#5" would drop you into a LIVE private/gated
	# instance world — bypassing the locker_unlocked / Intensity gates AND another character's isolation (and the
	# GATE RE-VALIDATION below can't catch it: instance portals use `instance:` not `to`/`gate`, so gate_for_map="").
	# Instances are re-entered ONLY via their gated portal/RPC. Mirrors _save_one, which maps instances→HOME on write.
	if not _worlds.has(map) or _is_instance(map):  # stale/unknown map (e.g. the DB default 'stadium') OR any instance key → home
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
var _party_seq := {}                              # pid -> join order (lowest = founder → party leader for loot fallback)
var _party_seq_ctr := 0


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
	if _residents.has(target_fid):                   # RP2: a resident isn't a peer — auto-join it server-side
		_resident_join(pid, target_fid, now)         # (no recv_party_invite round-trip; it has no client)
		return
	var tpid := _pid_by_fid(target_fid)
	if tpid < 0 or tpid == pid:
		return
	var party: Array = _session[pid]["party"]
	var invitee_res := 0                             # the invitee brings its own recruited companions into the merge
	for rfid in _res_party:
		if int(_res_party[rfid]) == tpid:
			invitee_res += 1
	if tpid in party or _party_headcount(pid) + 1 + invitee_res > MAX_PARTY:   # cap counts humans + companions
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
	if not _party_seq.has(ipid):                  # founder gets the earliest join order → leader
		_party_seq_ctr += 1
		_party_seq[ipid] = _party_seq_ctr
	if not _party_seq.has(pid):                   # the accepter joins after → higher order
		_party_seq_ctr += 1
		_party_seq[pid] = _party_seq_ctr
	var res_total := 0                            # RP2: companions bonded to any prospective member count toward the cap
	for rfid in _res_party:
		if int(_res_party[rfid]) in members:
			res_total += 1
	if members.size() + res_total > MAX_PARTY:     # authoritative humans + companions cap on the merge
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
	_release_residents_of(pid)                    # RP2: "Leave Party" also dismisses your recruited companions
	_party_leave(pid)

# set each member's party to the shared list (disband if < 2 left); the roster rides the snapshot
func _party_set(members: Array) -> void:
	if members.size() < 2:
		for m in members:
			if _session.has(m):
				_session[m]["party"] = []
			_party_seq.erase(m)                   # disbanded → clear join order
		return
	for m in members:
		if _session.has(m):
			_session[m]["party"] = members.duplicate()

func _party_leave(pid: int) -> void:
	_party_invites.erase(pid)
	_party_seq.erase(pid)                          # this member left → drop their join order
	for drop_id in _loot_rolls:                    # forfeit any open roll: a departed member can't vote on or win it
		var lr = _loot_rolls[drop_id]
		if pid in lr["eligible"]:
			(lr["eligible"] as Array).erase(pid)
			(lr["choices"] as Dictionary).erase(pid)
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
	var res_fids := _residents_of_party(pid)
	var party: Array = _session[pid]["party"]
	if party.size() < 2 and res_fids.is_empty():
		return out                               # truly solo, no companion → no HUD frame
	var members: Array = party if party.size() >= 2 else [pid]   # include self when it's you + a companion
	for m in members:
		if not _session.has(m):
			continue
		var mf = _find(_session[m]["fid"])
		out.append({"fid": str(_session[m]["fid"]), "name": str(_session[m]["name"]),
			"hp": int(round(mf["hp"])) if mf != null else 0, "maxHP": int(mf["maxHP"]) if mf != null else 1,
			"alive": bool(mf["alive"]) if mf != null else false, "map": str(_session[m]["map"])})
	for rfid in res_fids:                        # RP2: fold in recruited companions (fields synth'd from the fighter dict)
		var rf = _find(rfid)
		out.append({"fid": rfid, "name": str((rf as Dictionary).get("resName", "resident")) if rf != null else "resident",
			"hp": int(round(rf["hp"])) if rf != null else 0, "maxHP": int(rf["maxHP"]) if rf != null else 1,
			"alive": bool(rf["alive"]) if rf != null else false, "map": str(rf["map"]) if rf != null else ""})
	return out

# ---- RP2: partied residents (an AI "player" you can recruit, that follows + fights/heals with you) ----
# Residents are fid-only (no pid/_session), so they can't live in the pid-keyed party list; instead a
# separate _res_party (fid -> leader pid) bonds a resident to its recruiter, and the roster/follow logic
# folds it back in. All PvE-zone allyship/healing is already team-based, so no shared/ or client change.

# every resident bonded to any member of pid's party (so all party-mates see + share the companion)
func _residents_of_party(pid: int) -> Array:
	var out := []
	if not _session.has(pid):
		return out
	var party: Array = _session[pid]["party"]
	var pids: Array = party if party.size() >= 2 else [pid]
	for rfid in _res_party:
		if int(_res_party[rfid]) in pids:
			out.append(rfid)
	return out

# party headcount for the cap: human members (solo counts as 1) + bonded residents
func _party_headcount(pid: int) -> int:
	if not _session.has(pid):
		return 0
	var party: Array = _session[pid]["party"]
	return maxi(party.size(), 1) + _residents_of_party(pid).size()

# recruit a resident into pid's party (called from party_invite when the target fid is a resident)
func _resident_join(pid: int, res_fid: String, now: int) -> void:
	if not _session.has(pid) or not _residents.has(res_fid):
		return
	if _res_party.has(res_fid):                      # already bonded (to me = no-op; to another = can't steal)
		return                                       # cheap dict reject BEFORE the O(n) _find (anti-spam hygiene)
	if _party_headcount(pid) >= MAX_PARTY:           # party (humans + companions) is full
		return
	var res_f = _find(res_fid)
	if res_f == null:
		return
	_party_invite_next[pid] = now + INVITE_COOLDOWN_MS   # rate-limit recruits like peer invites
	_res_party[res_fid] = pid
	print("[zone] %s recruited resident %s" % [str(_session[pid]["name"]), str(res_f.get("resName", "resident"))])
	_try_follow(res_fid)                             # snap to the leader's zone immediately
	_resident_say(res_fid, "join", true)             # RP3: greet the recruiter (force past the cooldown)

# a bonded resident follows its leader BETWEEN zones (the brain handles local fight/heal). Cross-zone only —
# the shared brain idles with no enemy, so intra-zone trailing isn't possible without editing shared/.
func _try_follow(res_fid: String) -> void:
	var leader_pid := int(_res_party.get(res_fid, -1))
	if leader_pid < 0 or not _session.has(leader_pid):
		_release_resident(res_fid)                   # leader gone → release (double-guards the disconnect path)
		return
	var res_f = _find(res_fid)
	if res_f == null:
		return
	var leader_f = _find(str(_session[leader_pid].get("fid", "")))
	if leader_f == null:
		return
	var leader_map := str(leader_f["map"])
	if _is_instance(leader_map):
		return                                       # leader in a private Camp/Drill instance → wait it out (v1: shared worlds only)
	var w = _worlds.get(leader_map, null)
	if w == null or bool((w as Dictionary).get("pvp", false)):
		return                                       # leader in the PvP arena → don't drag a companion into PvP
	if str(res_f["map"]) == leader_map:
		return                                       # already together
	var aw := float((w as Dictionary).get("arenaW", GameData.ARENA_W))
	var ah := float((w as Dictionary).get("arenaH", GameData.ARENA_H))
	var pos := Vector2(clampf(float(leader_f["x"]) - 60.0, 40.0, aw - 40.0), clampf(float(leader_f["y"]), 40.0, ah - 40.0))
	_relocate(res_f, null, leader_map, pos)          # reuse the RP1 null-session relocate

# drop a resident's party bond; it resumes its director routing (without an instant route teleport)
func _release_resident(res_fid: String) -> void:
	if not _res_party.has(res_fid):
		return
	_res_party.erase(res_fid)
	_resident_say(res_fid, "dismiss")                # RP3: a parting line (cooldown-gated; skipped if no one's near)
	if _res_dir.has(res_fid):
		(_res_dir[res_fid] as Dictionary)["next_move_t"] = Time.get_ticks_msec() + ROUTE_DWELL_MS

func _release_residents_of(pid: int) -> void:
	for rfid in _res_party.keys():                   # keys() is a snapshot → safe to erase while iterating
		if int(_res_party[rfid]) == pid:
			_release_resident(rfid)

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
	return int(base * _intensity_reward(mob))    # Circuit Intensity scales the payout (1.0 for open-world mobs)

func _award_credits(pid: int, amt: int) -> void:
	if not _session.has(pid) or amt == 0:
		return
	var s = _session[pid]
	s["credits"] = int(s["credits"]) + amt
	if _atomic_econ:                             # P3: queue the delta for the idempotent DB flush.
		var open: Dictionary = s.get("award_open", {"credits": 0, "tokens": 0})   # NEGATIVE deltas ride too
		open["credits"] = int(open.get("credits", 0)) + amt                       # (admin corrections) — the
		s["award_open"] = open                                                    # DB floors the result at 0

# Practice Tokens (Glitchyard reward loop). Awarded in-session; persistence rides the _save_one in the
# _award_xp call that follows every kill (practice_tokens is in the saved fields). Tier-scaled.
func _award_tokens(pid: int, amt: int) -> void:
	if amt <= 0 or not _session.has(pid):
		return
	var s = _session[pid]
	s["tokens"] = int(s.get("tokens", 0)) + amt
	if _atomic_econ:                             # P3: queue the delta for the idempotent DB flush
		var open: Dictionary = s.get("award_open", {"credits": 0, "tokens": 0})
		open["tokens"] = int(open.get("tokens", 0)) + amt
		s["award_open"] = open

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
	if _atomic_econ:
		await _give_and_charge_atomic(pid, item, 0, int(entry["price"]))
	elif _legacy_econ_allowed():
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

# roll a recipe's output item (unique recipes draw a random unique; the rest a random slot).
# Shared by the atomic and legacy craft paths so the roll logic can't drift between them.
func _roll_recipe_item(recipe) -> Dictionary:
	if bool(recipe.get("unique", false)):                    # forge_unique → a random unique (P6)
		return _make_unique(GameData.UNIQUE_IDS[_loot_rng.next_int(GameData.UNIQUE_IDS.size())], int(recipe.get("ilvl", SHOP_ILVL)))
	var slot: String = (LOOT_SLOTS.keys())[_loot_rng.next_int(LOOT_SLOTS.size())]
	return _make_item(slot, str(recipe["rarity"]), int(recipe.get("ilvl", SHOP_ILVL)))

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
	if _atomic_econ:
		await _give_and_charge_atomic(pid, item, int(entry["price"]), 0)
	elif _legacy_econ_allowed():
		await _give_and_charge(pid, item, int(entry["price"]))

func _do_shop_roll(pid: int, rarity: String) -> void:
	if not _session.has(pid) or str(_session[pid]["map"]) != World.HOME or not ROLL_PRICE.has(rarity):
		return
	if int(_session[pid]["credits"]) < int(ROLL_PRICE[rarity]):
		return
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	var rolled := _make_item(slot, rarity, SHOP_ILVL)         # rolls carry affixes
	if _atomic_econ:
		await _give_and_charge_atomic(pid, rolled, int(ROLL_PRICE[rarity]), 0)
	elif _legacy_econ_allowed():
		await _give_and_charge(pid, rolled, int(ROLL_PRICE[rarity]))

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
	if _atomic_econ:
		# ONE transaction: every owned/unequipped/unlocked row is removed and the payout credited
		# together — retry-safe via the op ledger, and a crash mid-op can't strand a paid-but-present
		# (or removed-but-unpaid) item.
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_sell_items(_op_id(), str(s["char_id"]), ids, SELL_PRICE)
		_econ_end(s)
		var sold_n := 0
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			sold_n = (ar.get("sold", []) as Array).size()
		if _session.has(pid) and sold_n > 0:
			await _apply_equipment(pid)                       # defensive re-derive (equipped is never sold)
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))                     # deferred-save contract: the leaver's xp/level
		if net != null and _session.has(pid):
			net.recv_inventory_changed.rpc_id(pid)
		return
	if not _legacy_econ_allowed():
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
	if _atomic_econ:
		var yields := {}                                      # per-rarity scrap, perk multiplier pre-applied
		for rk in SALVAGE_YIELD:
			yields[rk] = maxi(1, int(round(float(int(SALVAGE_YIELD[rk])) * _par_mult(pid, "payroll_scrap"))))
		await _econ_begin(s)
		var ar = await supa.econ_salvage_items(_op_id(), str(s["char_id"]), ids, yields)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
		if net != null and _session.has(pid):
			net.recv_inventory_changed.rpc_id(pid)
		return
	if not _legacy_econ_allowed():
		return
	for id in ids:
		var r = await supa.sell_item_safe_as(s["char_id"], id)   # same atomic delete → no double-yield
		if r.get("ok"):
			# credit THIS item's scrap immediately (atomic), so a transient credit failure can lose at most
			# ONE item's yield — never the whole batch — and it lands in the DB even if the peer has left.
			var scr := maxi(1, int(round(float(int(SALVAGE_YIELD.get(str(r["rarity"]), 1))) * _par_mult(pid, "payroll_scrap"))))   # P5: Payroll "Scrapper" perk
			var mr = await supa.mats_add_as(s["char_id"], scr)
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
	var new_ip := int(item.get("item_power", 0)) + UPGRADE_STEP
	if _atomic_econ:
		# ONE transaction: gated item patch + credits + scrap — a stale/duplicate request matches no
		# row and spends nothing; there is no partial state to refund.
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_forge_upgrade(_op_id(), str(s["char_id"]), item_id, lvl, new_ip, credit_cost, scrap_cost)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			if _session.has(pid):
				await _apply_equipment(pid)                   # the item may be equipped → raised cap applies
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))                     # deferred-save contract for a mid-op leaver
		if net != null and _session.has(pid):
			net.recv_inventory_changed.rpc_id(pid)
		return
	if not _legacy_econ_allowed():
		return
	var mr = await supa.mats_add_as(s["char_id"], -scrap_cost)   # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return                                                  # nothing was spent → safe to bail
	# Do NOT bail here if the peer left: scrap is already committed to the DB, so we must run the
	# upgrade-or-refund flow below (it uses the captured char_id + session dict, not a live connection).
	s["scrap"] = int(mr["total"])
	s["credits"] = int(s["credits"]) - credit_cost              # deduct credits before the write
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
	# reroll affixes, KEEPING the existing primary: roll a fresh item of the same slot/rarity/ilvl (its
	# affixes exclude the given primary) and take just its affixes; recompute item_power from the kept primary.
	# (Rolled BEFORE the spend for both paths — the loot rng is the wall-clock economy stream, not the sim's.)
	var ilvl := int(item.get("ilvl", 1))
	var rolled := _make_item(str(item.get("slot", "trinket")), rarity, ilvl, str(item.get("primary_stat", "")))
	var new_affixes: Array = rolled.get("affixes", [])
	var atot := 0
	for a in new_affixes:
		atot += int(a.get("amt", 0))
	var new_ip := int(item.get("primary_amt", 0)) + atot + ilvl
	if _atomic_econ:
		await _flush_awards(s)
		await _econ_begin(s)
		var ar = await supa.econ_forge_reforge(_op_id(), str(s["char_id"]), item_id, rc, new_affixes, new_ip, credit_cost, scrap_cost)
		_econ_end(s)
		if bool(ar.get("ok", false)):
			_econ_sync_currency(s, ar)
			if _session.has(pid):
				await _apply_equipment(pid)                   # equipped item → new affixes apply (still capped)
		if not _session.has(pid):
			_save_one(s, _find(s["fid"]))
		if net != null and _session.has(pid):
			net.recv_inventory_changed.rpc_id(pid)
		return
	if not _legacy_econ_allowed():
		return
	var mr = await supa.mats_add_as(s["char_id"], -scrap_cost)   # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return                                                # nothing spent → safe to bail
	s["scrap"] = int(mr["total"])
	s["credits"] = int(s["credits"]) - credit_cost
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
	if _atomic_econ:
		# no mirror pre-check on scrap: the mirror can be stale-low after a failed login read, and the
		# DB fn is the authoritative underflow guard anyway (matches the legacy path's semantics)
		var aitem := _roll_recipe_item(recipe)
		if aitem.is_empty():
			return                                            # unknown unique def → nothing spent
		await _econ_begin(s)
		var ar = await supa.econ_craft(_op_id(), str(s["char_id"]), cost, aitem)
		_econ_end(s)
		if not bool(ar.get("ok", false)):
			return                                            # insufficient / inventory_full / network → no spend
		_econ_sync_currency(s, ar)
		if net != null and _session.has(pid):
			net.recv_loot.rpc_id(pid, str(aitem["name"]), str(aitem["rarity"]), str(aitem["slot"]), int(aitem["bonus_amt"]), str(aitem["bonus_stat"]))
			net.recv_inventory_changed.rpc_id(pid)
		return
	if not _legacy_econ_allowed():
		return
	var mr = await supa.mats_add_as(s["char_id"], -cost)      # spend scrap atomically (ok=false → insufficient)
	if not mr.get("ok"):
		return
	if _session.has(pid):
		s["scrap"] = int(mr["total"])
	var item: Dictionary = _roll_recipe_item(recipe)
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
	# UNTRUSTED input: coerce through _safe_num FIRST — clampf passes NaN straight through, so a
	# forged {"mx": NAN} would otherwise poison the fighter's position (and every snapshot reading it);
	# a non-numeric component would crash the handler. Valid numbers are unchanged (same clamp+normalize).
	var v := Vector2(clampf(_safe_num(mv.get("mx"), 0.0), -1.0, 1.0), clampf(_safe_num(mv.get("my"), 0.0), -1.0, 1.0))
	if v.length() > 1.0:
		v = v.normalized()
	_move[pid] = {"mx": v.x, "my": v.y, "target": str(mv.get("target", "")), "friend": str(mv.get("friend", ""))}
	_intent_age[pid] = 0

func submit_ability(pid: int, key, seq) -> void:
	if not _session.has(pid) or typeof(key) != TYPE_STRING:
		return
	if not _ability_unlocked(pid, key):          # gameplay-length P2: reject a still-locked ability — intent-layer gate,
		return                                    # so the deterministic Sim / balance harness never sees it (byte-identical)
	if int(seq) > int(_last_aseq.get(pid, 0)):
		_last_aseq[pid] = int(seq)
		_pending_ability[pid] = key

const HOP_ECHO_MS := 500      # how long a hop rides the snapshot as hopT (≥ client HOP_DUR 450ms; remotes clamp the tail)
const HOP_RATE_MS := 250      # min ms between accepted hops per peer — anti-spam AND the sole cadence gate; kept well
# UNDER the client's ~450ms re-hop cadence (HOP_DUR) so a continuous hopper's EVERY jump is networked (a padded
# restart window ≥ HOP_DUR silently dropped every other one).
# Phase 0.5 cosmetic hop: a client presses Space → this timestamps a purely-visual hop, echoed to other clients as a
# snapshot `hopT`. It NEVER touches the deterministic Sim (no position/collision/LOS/balance) — the fighter doesn't
# leave the 2-D plane; only the remote clients' render lifts the mesh. Server owns the cadence: session-gated,
# rate-limited (also DoS-bounds _hop_t0 churn), and alive-gated. A well-behaved client only sends one per completed
# arc (its own hop_t gates it), so the rate limit is purely a floor against a forged/spamming peer.
func submit_hop(pid: int) -> void:
	if not _session.has(pid):
		return
	var now := Time.get_ticks_msec()
	if now < int(_hop_next.get(pid, 0)):                          # rate limit (anti-spam / DoS) — the cadence gate
		return
	_hop_next[pid] = now + HOP_RATE_MS
	var fid := str(_session[pid].get("fid", ""))
	var f = _find(fid)
	if f == null or not bool(f.get("alive", false)):             # only a live fighter hops
		return
	_hop_t0[fid] = now
	_hop_n += 1                                                  # demand instrument (hops/min in the health log)

# gameplay-length P2: is `key` unlocked for this player? Grandfathered chars (created pre-gating) keep the full kit.
func _ability_unlocked(pid: int, key: String) -> bool:
	var s = _session[pid]
	if bool(s.get("ability_ungated", false)):
		return true
	var f = _find(s["fid"])
	if f == null:
		return true                              # no fighter (shouldn't happen) → don't reject (fail-open, non-security)
	return int(s["level"]) >= GameData.ability_unlock_level(str(f["classId"]), key)

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
		_tick_drills()                            # Two-Minute Drill: advance waves / end runs (P5)
		_apply_godmode()                          # keep god-mode players invulnerable (after damage resolves)
		_acc -= SIM_DT
		steps += 1
	if steps == 5:
		_acc = 0.0
	_tick_residents(delta)                        # RP1 director: resident routing/tether (real-time cadence)
	_tick_reports(delta)                          # RP4: automated-playtest anomaly detection (real-time cadence)
	_save_t += delta                              # save clock runs every frame, not just on sim steps
	if _save_t >= SAVE_INTERVAL:
		_save_t = 0.0
		_save_all()
	if steps > 0:
		_award_kills()                            # grant XP for mob kills before events are cleared
		_tick_loot_rolls()                        # auto-resolve any timed-out party loot rolls
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
			if f["team"] == 0 and not f.get("resident", false):   # real players only (residents aren't an upgrade signal)
				np += 1
		if np > 0:
			counts.append("%s:%d" % [mapname, np])
	var zones: String = " ".join(counts) if not counts.is_empty() else "-"
	var load := _proc_first_token("/proc/loadavg")
	var free_mb := _proc_kb("/proc/meminfo", "MemAvailable:") / 1024
	var rss_mb := _proc_kb("/proc/self/status", "VmRSS:") / 1024
	print("[health] players=%d [%s]  load=%s (1 vCPU)  peak_tick=%.1fms/33ms  free_ram=%dMB  server_rss=%dMB  hops/min=%d" % [
		players, zones, load, _tick_us_peak / 1000.0, free_mb, rss_mb, _hop_n])
	_tick_us_peak = 0
	_hop_n = 0

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
	_scale_boss_party(w)                          # P7c: lock a phased world boss's HP to the engaging party on its first hit (before regen)
	_consume_summons(w, mapname)                  # spawn any adds the sim requested this tick (summon bridge)
	_apply_regen(w)                               # out-of-combat health regen (rate/delay per map type)
	var instance := _is_instance(mapname)
	for f in w["fighters"]:                       # queue the dead for respawn (dummy instant; mobs slower than players)
		if not f["alive"] and not _respawn.has(f["id"]):
			if f.get("dummy", false):
				_respawn[f["id"]] = 0.0
			elif f["team"] == 1:
				if instance:
					continue                          # Circuit mobs DON'T respawn — a finite clear (killing the objective completes it)
				# the boss is a rare ~30-min event; its cones/cores + normal mobs churn at the usual rate
				# Phase 8 S2: ANY def may carry a per-def respawnS override — used by rival_core (45 s, so a
				# solo rotation can earn the Rival Coach's shield-down window; the GY raid cores keep the 6-s
				# cadence). Bosses default to the 30-min world-event cadence, minions to 6 s, as shipped.
				var _bdef: Dictionary = GameData.CLASSES.get(str(f["classId"]), {})
				var _rdefault: float = BOSS_RESPAWN_DELAY if _bdef.get("phased", false) else MOB_RESPAWN_DELAY
				_respawn[f["id"]] = float(_bdef.get("respawnS", _rdefault))
			else:
				var _dmeta: Dictionary = _instances.get(mapname, {})
				if bool(_dmeta.get("active", false)) and str(_dmeta.get("mode", "")) == "drill":
					continue                          # P7d: no mid-run Drill battle-rez — a downed member stays down (one life per run, like solo); still rewarded at run-end if it engaged
				_respawn[f["id"]] = RESPAWN_DELAY
				if f.get("resident", false):          # RP4: a resident died → tally it for the playtest report (fires once per death)
					_on_resident_death(f)

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
		if f["team"] == 0 and not f.get("resident", false) and bool(_worlds.get(str(f["map"]), {}).get("pvp", false)):
			var s = _session_by_fid(id)               # died in a PvP zone → respawn at the home safe zone (residents respawn in place)
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
			add["intensity"] = int(owner.get("intensity", 1))   # P3b: adds inherit the summoner's Circuit context (1 = open-world/Drill unchanged; future affixed rooms scale their adds too)
			add["affixHp"] = float(owner.get("affixHp", 1.0))
			add["affixDmg"] = float(owner.get("affixDmg", 1.0))
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
		for portal in World.PORTALS.get(_template(s["map"]), []):   # portals resolve by template (instances share theirs)
			if Vector2(f["x"] - float(portal["x"]), f["y"] - float(portal["y"])).length() <= World.PORTAL_RADIUS:
				if portal.has("instance"):            # instance ENTRY: `auto` pads (the Drill) enter on walk; others
					if bool(portal.get("auto", false)) and str(portal["instance"]) == World.DRILL:   # (Camp) are RPC-driven
						_enter_drill(pid)
						_tp_next[f["id"]] = now + TP_GRACE_MS
						break
					if str(portal["instance"]) == World.LOCKER:   # Builder Mode: walk-on entry, gated on locker_unlocked
						if bool(s.get("locker_unlocked", false)):
							_enter_locker_room(pid)
							_tp_next[f["id"]] = now + TP_GRACE_MS
						break                          # locked → inert (no teleport); P3 offers the purchase on proximity
					continue                          # Camp: walking onto the pad only opens the client selector.
				if portal.has("gate") and not _portal_unlocked(pid, str(portal["gate"])):
					var why := _gate_locked_msg(str(portal["gate"]))   # tell the player WHY the visible pad is sealed (throttled; "" = a hidden gate, stays silent). Generalized from boss_ready-only in Phase 8.
					if why != "" and now >= int(_gate_prompt_next.get(pid, 0)) and net != null:
						_gate_prompt_next[pid] = now + GATE_PROMPT_COOLDOWN_MS
						net.recv_chat.rpc_id(pid, "SYSTEM", why)
					continue                          # gated + locked — no teleport (secret-type gates are also hidden in the snapshot)
				# leaving an active Drill via the exit → END the run (bank the score + reward), not a bare teleport
				if str((_instances.get(s["map"], {}) as Dictionary).get("mode", "")) == "drill" and bool((_instances.get(s["map"], {}) as Dictionary).get("active", false)):
					_end_drill(s["map"])
					_tp_next[f["id"]] = now + TP_GRACE_MS
					break
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
	match gate:
		"all_quests":
			return _all_quests_done(pid)
		"secret_key":                            # the secret boss: finish EVERY quest (incl. Boss1) AND forge the Master Key
			return _all_quests_done(pid) and _has_master_key(pid)
		"boss_ready":                            # difficulty-pass v1: the first boss needs real progression — level AND gear score
			var s = _session.get(pid, {})
			return int(s.get("level", 1)) >= BOSS_GATE_LEVEL and int(s.get("item_power", 0)) >= BOSS_GATE_IP
		"away_gate":                             # Phase 8: the Away Circuit — level only (the biome IS the gear path)
			return int(_session.get(pid, {}).get("level", 1)) >= AWAY_GATE_LEVEL
		"finals_gate":                           # Phase 8 S3: the Finals — level + gear, NEVER the raid kill (a stalled raid must not block the capstone)
			var fs = _session.get(pid, {})
			return int(fs.get("level", 1)) >= FINALS_GATE_LEVEL and int(fs.get("item_power", 0)) >= FINALS_GATE_IP
	return true

# Why a visible-but-locked pad is sealed, for the throttled on-approach prompt ("" = stay silent — the
# HIDDEN_GATES pads never render, so they never need an explanation). Phase 8 generalized this from the
# boss_ready-only branch so every new gate explains itself.
func _gate_locked_msg(gate: String) -> String:
	match gate:
		"boss_ready":
			return "The Head Coach Arena is sealed — reach level %d and gear score %d to enter." % [BOSS_GATE_LEVEL, BOSS_GATE_IP]
		"away_gate":
			return "The Away Games start at level %d — finish your Glitchyard training first." % AWAY_GATE_LEVEL
		"finals_gate":
			return "The Finals are sealed — reach level %d and gear score %d to enter." % [FINALS_GATE_LEVEL, FINALS_GATE_IP]
	return ""

# per-player portal list for the snapshot: gated portals the player hasn't unlocked are HIDDEN (the secret
# zone's entrance doesn't render until you've earned it).
func _portals_for_player(map: String, pid: int) -> Array:
	var out := []
	for p in World.PORTALS.get(_template(map), []):   # by template so instance worlds render their exit pad
		if p.has("gate") and HIDDEN_GATES.has(str(p["gate"])) and not _portal_unlocked(pid, str(p["gate"])):
			continue                                  # difficulty-pass v1: only SECRET-type gates hide; boss_ready stays visible-but-locked
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
	_maybe_teardown_instance(from_map)               # left an instance? tear it down if now empty of players

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
		var is_boss := bool(GameData.CLASSES.get(str(f["classId"]), {}).get("phased", false))
		var engaged := false
		if (here - spawn).length() <= MAX_LEASH:                 # stays tethered to its camp
			for p in w["fighters"]:
				# a raid BOSS only stays engaged for a REAL player — an AI resident can't hold it (so it resets/heals
				# for a fresh pull + a resident can never help solo-attrition a 5-man boss). Regular mobs: anyone.
				if p["team"] == 0 and p["alive"] and (not is_boss or not p.get("resident", false)) and (Vector2(p["x"], p["y"]) - here).length() < radius:
					engaged = true
					break
		_mob_engaged[f["id"]] = engaged
		frozen[f["id"]] = not engaged
		if not engaged and f["alive"]:
			f["x"] = spawn.x                                     # disengaged → return to camp
			f["y"] = spawn.y
			if was:                                             # heal to full only on the engage→disengage edge
				if is_boss:                                     # P7c: a leashed boss is a FRESH pull — restore the base 5-player HP pool + clear the party-scale lock so the next pull re-samples the real force (defeats tag-and-leave / solo-death-in-opening)
					f["maxHP"] = float(f.get("_basePool", f["maxHP"]))
					f["_scaleCommitted"] = false
					f["_scaleFac"] = 1.0
					f["_scaleEff"] = 0.0
					f["_fightStartMs"] = 0     # P7d: a leashed boss is a fresh pull → restart the fastest-kill clock
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
			if victim == null or victim["team"] != 1 or victim.get("dummy", false) or victim.get("isAdd", false) or victim.get("isCore", false) or victim.get("isDrill", false):  # mobs only; not the dummy, adds, cores, or Drill-wave mobs (reward is the run score)
				continue
			if victim.get("objective", false) and _is_instance(str(mapname)):   # the Circuit gatekeeper died → complete the run
				_on_circuit_clear(str(mapname))                # (idempotent; instance mobs don't respawn so it fires once)
			var gy := str(mapname).begins_with("glitchyard") or str(mapname).begins_with("away") or str(mapname).begins_with("finals")   # the reward loop: Practice Tokens drop in the Glitchyard + the whole Away Circuit incl. the Finals (the plan's owner-approved "extend to the new 9-28 bands" decision)
			# who gets credit? A real player who landed the blow — OR, when a POLITE AI resident finished a mob,
			# the nearest engaged player (helping never robs you). The RUDE resident (+ unclaimed kills) → nobody.
			var credit_pid := -1
			for pid in _peers:
				if _session[pid]["fid"] == ev["killer"]:
					credit_pid = pid
					break
			if credit_pid < 0:
				var killer_f = _find(ev["killer"])
				if killer_f != null and killer_f.get("resident", false):
					_resident_say(str(ev["killer"]), "kill")   # RP3: a persona line on the killing blow (cooldown-gated)
					var vpos := Vector2(victim["x"], victim["y"])
					credit_pid = _nearest_player_pid(str(mapname), vpos, RESIDENT_ASSIST_RANGE, true)   # an ENGAGED player was fighting it → never robbed (polite OR rude)
					if credit_pid < 0 and bool(killer_f.get("resPolite", true)):   # a SOLO kill (no one was fighting) → polite gifts it, the rude one hogs it
						credit_pid = _nearest_player_pid(str(mapname), vpos, RESIDENT_ASSIST_RANGE, false)
			if credit_pid >= 0 and _session.has(credit_pid):
				_award_credits(credit_pid, int(round(float(_mob_credits(victim)) * _par_mult(credit_pid, "payroll_credit"))))   # credits before xp's save persists both (P5: Payroll perk)
				if gy:
					_award_tokens(credit_pid, int(round(float(_mob_tokens(victim)) * _par_mult(credit_pid, "recruit_tokens"))))   # P5: Recruiter "Talent Scout" perk
				_award_kill_xp(credit_pid, victim, str(mapname))
				var drop := _roll_loot(victim, _par_mult(credit_pid, "scout_drop"))   # roll once; solo → grant; party (≥2 real, same zone) → want/need/pass (P5: Scout drop-rate perk)
				if not drop.is_empty():
					_distribute_loot(credit_pid, drop, str(mapname))
				_quest_on_kill(credit_pid, victim)             # advance any matching kill-quest
				_bounty_on_kill(credit_pid, victim)            # gameplay-length P6b: advance any matching kill-bounty
				if str(victim.get("classId", "")) == "rival_coach":   # Phase 8 S2: the Rival Coach pays Pages too (repeatable; deliberately NOT on the boss_time board)
					_award_pages(credit_pid, RIVAL_PAGES)
				if str(victim.get("classId", "")) == "head_coach":   # the campaign boss drops a Playbook-Pages chunk (attunement)
					_award_pages(credit_pid, BOSS_PAGES)
					# gameplay-length P7d: Head Coach fastest-KILL board — the KILLING-BLOW player's fight duration (from the
					# P7c damage-anchored commit). Killer-only on purpose: credit_pid is an engaged real player, so a bystander
					# clipped by AoE in this SHARED arena can't leech onto the board (which would mint a free Champion tint);
					# support players earn it on their own kills — the boss is a re-runnable 30-min event.
					var _fs := int(victim.get("_fightStartMs", 0))
					var _el := Time.get_ticks_msec() - _fs
					if _fs > 0 and _el > 0 and _el < CLEAR_CAP_MS and credit_pid >= 0 and _session.has(credit_pid):
						_submit_score(str(_session[credit_pid]["char_id"]), str(_session[credit_pid]["name"]), "boss_time", CLEAR_CAP_MS - clampi(_el, 1, CLEAR_CAP_MS - 1))

func _nearest_player_pid(mapname: String, pos: Vector2, rng: float, require_engaged := false) -> int:
	var best := -1
	var bd := rng * rng
	for pid in _peers:
		if not _session.has(pid) or str(_session[pid].get("map", "")) != mapname:
			continue
		var pf = _find(_session[pid]["fid"])
		if pf == null or not pf["alive"]:
			continue
		if require_engaged and float(pf.get("noDmgT", 999.0)) > RESIDENT_ENGAGED_S:
			continue                                  # not recently hit → not actually in this fight (anti-AFK-farm)
		var d2: float = (Vector2(pf["x"], pf["y"]) - pos).length_squared()
		if d2 < bd:
			bd = d2
			best = pid
	return best

func _award_xp(pid: int, amt: int) -> void:
	if not _session.has(pid):
		return
	var s = _session[pid]
	var rested := int(s.get("rested_xp", 0))     # gameplay-length P1(d): spend the offline rested pool as a bonus on earned XP
	if rested > 0 and amt > 0 and int(s["level"]) < LEVEL_CAP:
		var bonus := mini(rested, int(round(float(amt) * RESTED_BONUS)))
		if bonus > 0:
			s["rested_xp"] = rested - bonus
			amt += bonus
	s["xp"] = int(s["xp"]) + amt
	while int(s["level"]) < LEVEL_CAP and s["xp"] >= _xp_to_next(int(s["level"])):
		s["xp"] -= _xp_to_next(int(s["level"]))
		s["level"] = int(s["level"]) + 1
		var f = _find(s["fid"])
		if f != null:
			f["maxHP"] += LEVEL_HP
			f["hp"] = f["maxHP"]
		if net != null:                          # gameplay-length P4: each level = +1 talent point (derived from level, so nothing to store) → nudge the client to open the tree
			net.recv_talent_point.rpc_id(pid, int(s["level"]))
	if int(s["level"]) >= LEVEL_CAP:             # at cap: park xp at a full bar, divert the OVERFLOW into paragon Overtime (P5)
		var overflow := int(s["xp"]) - _xp_to_next(LEVEL_CAP)
		s["xp"] = mini(int(s["xp"]), _xp_to_next(LEVEL_CAP))
		if overflow > 0:
			_accrue_overtime(pid, overflow)     # fire-and-forget (like _save_one): in-session accrual is synchronous, the DB flush only fires on a level crossing
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
	elif f.get("resident", false):               # AI resident: re-apply the level+tier scaling (no session)
		_scale_resident(f)
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
	var i_hp := _intensity_hp(int(f.get("intensity", 1)))     # Camp Circuit Intensity ladder (1 = no-op for open-world mobs)
	var i_dmg := _intensity_dmg(int(f.get("intensity", 1)))
	f["maxHP"] = f["maxHP"] * hp_s * float(bdef.get("hpMult", 1.0)) * i_hp * float(f.get("affixHp", 1.0))   # per-boss + Intensity + weekly-affix HP mult (affix defaults 1.0 → open-world/boss unaffected)
	f["hp"] = f["maxHP"]
	f["dmgMult"] *= dmg_s * float(bdef.get("dmgScale", 1.0)) * i_dmg * float(f.get("affixDmg", 1.0))   # per-boss + Intensity + weekly-affix damage mult
	f["_basePool"] = f["maxHP"]           # P7c: cache the base 5-player HP pool so the leash edge can restore it + upscales measure against it
	f["_scaleCommitted"] = false          # P7c: (re)based → the per-party hook re-samples on the next fresh pull (survives _revive: not in create_fighter)
	f["_scaleFac"] = 1.0                   # currently-applied HP factor (1.0 = base pool)
	f["_scaleEff"] = 0.0                   # peak attacking force seen this pull (reset here + on leash)
	f["_fightStartMs"] = 0                 # P7d: boss fastest-kill clock — restart on (re)spawn

# P7c — a phased WORLD boss scales its HP pool to the PEAK engaging force. Each tick it tracks the peak effective
# force present (real players + bots × BOSS_BOT_WEIGHT; rises only, cleared on leash/respawn). The INITIAL lock is
# anchored to REAL damage — it fires the first tick the force has driven the boss below BOSS_SCALE_COMMIT of its base
# pool (well above the phase-1 boundary), scaling HP by clampf(SOLO+STEP·(peak-1),SOLO,1) frac-preservingly. Because
# the commit is damage-anchored (not a timer/occupancy), a lone tagger who leaves never locks it — the leash edge
# restores the base pool. After the lock, if MORE force arrives (peak rises — e.g. a staged group joins after a solo
# tag) the boss UPSCALES, ADDING the same absolute HP as base pool it adds (damage already dealt is preserved, never
# refunded) so staging is never a shortcut (and, via monotonic phases, is a penalty). Never downscales. HP only (full
# damage kept). Server-only mob stat → no deterministic player sim / FORMAT_MODS change.
func _scale_boss_party(w: Dictionary) -> void:
	for f in w["fighters"]:
		if int(f["team"]) != 1 or not bool(f.get("alive", false)):
			continue
		if not GameData.CLASSES.get(str(f["classId"]), {}).get("phased", false):
			continue                              # only the phased world bosses scale to the party
		var reals := 0
		var bots := 0
		for a in w["fighters"]:
			if int(a["team"]) == 0 and bool(a.get("alive", false)):
				if bool(a.get("resident", false)):
					bots += 1
				else:
					reals += 1
		var eff: float = float(reals) + float(bots) * BOSS_BOT_WEIGHT
		if eff > float(f.get("_scaleEff", 0.0)):
			f["_scaleEff"] = eff                  # running PEAK force present this pull (rises only; cleared on leash/respawn)
		var peak: float = float(f.get("_scaleEff", 0.0))
		if peak < 1.0:
			continue                              # no real attacking force present yet
		var target: float = clampf(BOSS_SOLO_HP_FRAC + BOSS_HP_PER_ATTACKER * (peak - 1.0), BOSS_SOLO_HP_FRAC, 1.0)
		if not bool(f.get("_scaleCommitted", false)):
			if float(f["hp"]) < float(f["maxHP"]) * BOSS_SCALE_COMMIT:   # real damage done → lock to the peak (frac-preserving)
				f["maxHP"] = float(f["maxHP"]) * target
				f["hp"] = float(f["hp"]) * target
				f["_scaleFac"] = target
				f["_scaleCommitted"] = true
				f["_fightStartMs"] = Time.get_ticks_msec()   # P7d: boss fastest-kill clock starts at the damage-anchored commit (90% HP — the same fair anchor for everyone; a tag-and-idle can't start it)
				print("[boss] %s HP locked to %d%% — force eff %.1f" % [str(f.get("classId", "boss")), int(round(target * 100.0)), peak])
		elif target > float(f.get("_scaleFac", 1.0)) + 0.0001:          # peak rose after the lock → upscale: add absolute HP (damage preserved)
			var add: float = float(f.get("_basePool", f["maxHP"])) * (target - float(f["_scaleFac"]))
			f["maxHP"] = float(f["maxHP"]) + add
			f["hp"] = float(f["hp"]) + add
			f["_scaleFac"] = target
			print("[boss] %s HP upscaled to %d%% — force grew to eff %.1f" % [str(f.get("classId", "boss")), int(round(target * 100.0)), peak])

# Intensity reward factor for xp/credits (a Circuit mob at tier N is worth more): +50% per tier above 1.
func _intensity_reward(mob) -> float:
	return 1.0 + float(maxi(1, int(mob.get("intensity", 1))) - 1) * 0.5

func _mob_xp(mob, killer_lvl := 0) -> int:
	var lvl := int(mob.get("mobLevel", 1))
	var tier := str(mob.get("mobTier", "minion"))
	var mult := MOB_BOSS_XP if tier == "boss" else (MOB_ELITE_XP if tier == "elite" else 1)
	# con-scaling applies to OPEN-WORLD mobs only; instanced Circuit runs (ANY tier — keyed on the "#" instance map,
	# so the mandatory intensity==1 entry tier is covered too) are already level-gated by the Intensity ladder and
	# keep full XP, else a high-level player would earn ~0 there. (Drill mobs never reach here; they skip the reward path.)
	var con := 1.0 if _is_instance(str(mob.get("map", ""))) else _con_mult(killer_lvl, lvl)
	return int(MOB_XP_BASE * lvl * mult * _intensity_reward(mob) * con)

# gameplay-length P1: con / level-difference factor. Full XP within ±XP_CON_GRACE levels, fading linearly to
# XP_CON_FLOOR over XP_CON_SPAN more levels (both a mob far BELOW you — anti trivial-farm — and far ABOVE you —
# anti free-carry — decay). killer_lvl <= 0 disables scaling (back-compat for any unscaled caller).
func _con_mult(actor_lvl: int, mob_lvl: int) -> float:
	if actor_lvl <= 0:
		return 1.0
	var over := absi(actor_lvl - mob_lvl) - XP_CON_GRACE
	if over <= 0:
		return 1.0
	return maxf(XP_CON_FLOOR, 1.0 - float(over) / float(XP_CON_SPAN) * (1.0 - XP_CON_FLOOR))

# gameplay-length P1: award a mob kill's XP to the credit player AND same-zone party members near the kill,
# each scaled by their OWN level vs the mob (con). Grouping now accelerates leveling instead of being XP-neutral;
# the level-delta + proximity gates keep it from being a power-level shortcut. Open-world (intensity 1) only con-scales.
func _award_kill_xp(credit_pid: int, mob, mapname: String) -> void:
	if not _session.has(credit_pid):
		return
	var recipients := [credit_pid]
	var party: Array = _session[credit_pid]["party"]
	if party.size() >= 2:
		var vpos := Vector2(mob["x"], mob["y"])
		var clvl := int(_session[credit_pid]["level"])
		for m in party:
			if m == credit_pid or not _session.has(m):
				continue
			if str(_session[m]["map"]) != mapname:
				continue
			if absi(int(_session[m]["level"]) - clvl) > XP_SHARE_MAX_DELTA:   # anti power-level: no carrying a far-lower friend
				continue
			var mf = _find(_session[m]["fid"])
			if mf == null or not mf["alive"]:
				continue
			if float(mf.get("noDmgT", 999.0)) > RESIDENT_ENGAGED_S:   # anti-AFK / 2-box leech: must have been hit recently (actually in this fight), same primitive as resident kill-credit
				continue
			if (Vector2(mf["x"], mf["y"]) - vpos).length_squared() > XP_SHARE_RANGE * XP_SHARE_RANGE:
				continue
			recipients.append(m)
	for pid in recipients:
		_award_xp(pid, _mob_xp(mob, int(_session[pid]["level"])))

# roll THEN grant (used by the Circuit-clear bonus). Mob kills roll once + distribute (solo grant or party roll).
func _grant_loot(pid: int, mob) -> void:
	if not _session.has(pid):
		return
	var item := _roll_loot(mob, _par_mult(pid, "scout_drop"))   # P5: Scout drop-rate perk applies to Circuit-clear bonus rolls too
	if not item.is_empty():
		await _grant_item(pid, item)

# grant an ALREADY-rolled item: persist it, then notify. The single write point for a loot drop.
func _grant_item(pid: int, item: Dictionary) -> void:
	if not _session.has(pid) or item.is_empty():
		return
	var s = _session[pid]
	var r = await supa.add_item_as(s["access"], s["char_id"], item)
	if not r.get("ok"):                                  # never tell the client it looted something we didn't save
		print("[loot] %s drop NOT saved (code %s)" % [s["name"], r.get("code", "?")])
		return
	if _session.has(pid):                                # still connected after the write
		net.recv_loot.rpc_id(pid, str(item["name"]), str(item["rarity"]), str(item["slot"]), int(item["bonus_amt"]), str(item["bonus_stat"]))
		print("[loot] %s looted [%s] %s (+%d %s)" % [s["name"], item["rarity"], item["name"], item["bonus_amt"], item["bonus_stat"]])

# a compact item summary for the roll UI (residents/companions aren't peers, so never included)
func _loot_item_info(item: Dictionary) -> Dictionary:
	return {"name": str(item.get("name", "?")), "rarity": str(item.get("rarity", "common")),
		"slot": str(item.get("slot", "")), "amt": int(item.get("bonus_amt", 0)), "stat": str(item.get("bonus_stat", "")),
		"ilvl": int(item.get("ilvl", 1)), "unique": str(item.get("unique_id", "")) != ""}

# a drop landed for a partied killer → either grant solo, or open a want/need/pass roll for the real party
# members in the same zone (AI companions are fid-only, never in the pid party list → they never roll).
func _distribute_loot(killer_pid: int, item: Dictionary, mapname: String) -> void:
	var eligible := []
	if _session.has(killer_pid):
		var party: Array = _session[killer_pid]["party"]
		if party.size() >= 2:
			for m in party:
				if _session.has(m) and str(_session[m]["map"]) == mapname:
					eligible.append(m)
	if eligible.size() < 2:                              # solo, or party split across zones → straight to the killer
		_grant_item(killer_pid, item)
		return
	_loot_roll_ctr += 1
	var drop_id := _loot_roll_ctr
	_loot_rolls[drop_id] = {"item": item, "map": mapname, "eligible": eligible, "choices": {},
		"deadline": Time.get_ticks_msec() + LOOT_ROLL_MS}   # all-pass winner is recomputed from live seq at resolve time
	var info := _loot_item_info(item)
	for m in eligible:
		if _session.has(m) and net != null:
			net.recv_loot_roll.rpc_id(m, drop_id, info, LOOT_ROLL_MS)

# a party member's Need/Want/Pass choice (client → server)
func loot_roll(pid: int, drop_id: int, choice: String) -> void:
	if not _session.has(pid) or not _loot_rolls.has(drop_id):
		return
	var now := Time.get_ticks_msec()
	if now < int(_loot_roll_next.get(pid, 0)):
		return
	_loot_roll_next[pid] = now + 200
	var roll = _loot_rolls[drop_id]
	if pid not in roll["eligible"] or (roll["choices"] as Dictionary).has(pid):
		return                                           # not eligible, or already chose
	if choice != "need" and choice != "want" and choice != "pass":
		choice = "pass"
	roll["choices"][pid] = choice
	var all_chose := true                                # resolve early only once every still-connected eligible has chosen
	for m in roll["eligible"]:                           # (count-compare would misfire on stale votes left by a disconnect)
		if _session.has(m) and not (roll["choices"] as Dictionary).has(m):
			all_chose = false
			break
	if all_chose:
		_resolve_loot_roll(drop_id)

# resolve a roll: tiered Need > Want (a lone claimant wins outright; ties roll 1-100 within the winning tier);
# everyone passed → the party leader; then grant the item to the winner and tell every roller the outcome.
func _resolve_loot_roll(drop_id: int) -> void:
	if not _loot_rolls.has(drop_id):
		return
	var roll = _loot_rolls[drop_id]
	_loot_rolls.erase(drop_id)                           # claim it once (idempotent)
	var item: Dictionary = roll["item"]
	var needs := []
	var wants := []
	for m in roll["eligible"]:
		if not _session.has(m):
			continue                                     # disconnected = pass
		var c := str((roll["choices"] as Dictionary).get(m, "pass"))
		if c == "need":
			needs.append(m)
		elif c == "want":
			wants.append(m)
	var pool: Array = needs if not needs.is_empty() else wants   # Need outranks Want
	var rolls := {}
	var winner := -1
	if pool.size() == 1:
		winner = int(pool[0])                            # lone claimant → wins outright
	elif pool.size() > 1:
		var best := -1
		for m in pool:
			var rv: int = _loot_rng.next_int(100) + 1    # 1..100 (Variant → annotate per the := trap)
			rolls[m] = rv
			if rv > best or (rv == best and (winner < 0 or m < winner)):
				best = rv
				winner = m
	else:                                                # everyone passed → the party leader AMONG still-eligible members
		var best_seq := 1 << 62                          # founder = lowest join seq; a mid-roll leaver's seq was erased → sorts last,
		for m in roll["eligible"]:                        # and an out-of-zone founder was never in eligible → both correctly excluded
			if not _session.has(m):
				continue                                 # disconnected → can't win
			var lsq := int(_party_seq.get(m, 1 << 61))
			if lsq < best_seq or (lsq == best_seq and (winner < 0 or m < winner)):
				best_seq = lsq
				winner = m
	# tell every roller the outcome (winner name + choices + rolls), then grant to the winner
	var choices_out := {}
	var rolls_out := {}
	for m in roll["eligible"]:
		var f := str(_session[m]["fid"]) if _session.has(m) else str(m)
		choices_out[f] = str((roll["choices"] as Dictionary).get(m, "pass"))
		if rolls.has(m):
			rolls_out[f] = int(rolls[m])
	var win_name := str(_session[winner]["name"]) if (winner >= 0 and _session.has(winner)) else "nobody"
	var result := {"item": _loot_item_info(item), "winner": win_name, "choices": choices_out, "rolls": rolls_out}
	for m in roll["eligible"]:
		if _session.has(m) and net != null:
			net.recv_loot_roll_result.rpc_id(m, drop_id, result)
	if winner >= 0 and _session.has(winner):
		_grant_item(winner, item)
	else:
		print("[loot] roll %d: item lost (no eligible winner)" % drop_id)

# expire timed-out rolls (called from the tick)
func _tick_loot_rolls() -> void:
	if _loot_rolls.is_empty():
		return
	var now := Time.get_ticks_msec()
	var expired := []
	for drop_id in _loot_rolls:
		if now >= int(_loot_rolls[drop_id]["deadline"]):
			expired.append(drop_id)
	for drop_id in expired:
		_resolve_loot_roll(drop_id)

func _roll_loot(mob, drop_mult: float = 1.0) -> Dictionary:
	var tier := str(mob.get("mobTier", "minion"))
	var lvl := int(mob.get("mobLevel", 1))
	var intensity := int(mob.get("intensity", 1))            # Circuit Intensity (1 = open world → no change)
	# drop_mult (P5 Scout "Sharp Eyes" perk) scales the drop CHANCE. This DOES shift the shared _loot_rng stream (a higher
	# chance passes the gate more often → more downstream rarity/slot draws) — but that is fine: _loot_rng is a separate,
	# wall-clock-seeded ECONOMY rng, entirely distinct from the per-world deterministic Sim Rng, so create_fighter/derive/
	# FORMAT_MODS + the AI-duel harness stay byte-identical. Do NOT feed a chance multiplier into the deterministic sim rng.
	var chance := clampf((float(DROP_CHANCE.get(tier, 0.15)) + ((intensity - 1) * DROP_INTENSITY_STEP if tier == "minion" else 0.0)) * drop_mult, 0.0, 1.0)
	if _loot_rng.next() > chance:
		return {}
	var rar := _roll_rarity(tier, intensity)
	var slots: Array = LOOT_SLOTS.keys()
	var slot: String = slots[_loot_rng.next_int(slots.size())]
	var tbonus := 12 if tier == "boss" else (5 if tier == "elite" else 0)   # drop ilvl = mob level + tier + Intensity
	var ilvl := clampi(lvl + tbonus + (intensity - 1) * 2, 1, 80)
	# uniques from bosses always, and from high-Intensity elite gatekeepers (the Circuit chase) — never routine
	if (tier == "boss" or (tier == "elite" and intensity >= 3)) and _loot_rng.next() < UNIQUE_DROP_CHANCE:
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

func _roll_rarity(tier: String, intensity: int = 1) -> Dictionary:
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
	idx = clampi(idx + int((intensity - 1) / 2), 0, RARITIES.size() - 1)   # Circuit Intensity raises the rarity floor ~1 per 2 tiers
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
		# char-scope the write (every other item write is; guards against a reauth-swapped token touching a foreign row)
		var own_filter := "id=eq.%s&character_id=eq.%s" % [item_id, s["char_id"]]
		if bool(item["equipped"]):                   # toggle OFF: unequip this item
			ok = bool((await supa.inv_set_equipped_as(s["access"], own_filter, false)).get("ok"))
		else:                                        # toggle ON: equip it FIRST, then trim the slot to capacity
			ok = bool((await supa.inv_set_equipped_as(s["access"], own_filter, true)).get("ok"))
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
					trim_ok = bool((await supa.inv_set_equipped_as(s["access"], "id=eq.%s&character_id=eq.%s" % [str(others[i]["id"]), s["char_id"]], false)).get("ok")) and trim_ok
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
	if not inv.get("ok"):
		if _session.has(pid):                            # S3 review: a TRANSIENT inventory-fetch failure must not
			_session[pid]["gear_unknown"] = true         # read as "no gear" — the login gate re-validation would
		return                                           # bounce a legitimately-geared player out of an IP-gated zone
	if not _session.has(pid):
		return
	_session[pid]["gear_unknown"] = false
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
					"amt": pamt2, "icd": float(pdef.get("icd", 0.0)), "dur": float(pdef.get("dur", 3.0)),
					"chance": float(pdef.get("chance", 1.0))})
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
	# The cap is applied to the TOTAL set contribution PER STAT — two sets that share a signature stat (e.g.
	# football + rookie_camp both END) must not stack past SET_BONUS_CAP, or END (→HP) blows past the bound.
	var set_active := {}                                 # set_id -> {count, bonus} for the character sheet
	var set_by_stat := {}                                # stat -> summed set bonus (pre-cap)
	for sid in set_counts:
		var sd = GameData.SET_DEFS.get(sid, null)
		if sd == null:
			continue
		var cnt := int(set_counts[sid])
		var sb := _set_bonus(sd, cnt)
		var st := str(sd["stat"])
		if sb > 0:
			set_by_stat[st] = int(set_by_stat.get(st, 0)) + sb
		set_active[sid] = {"count": cnt, "bonus": sb, "stat": st}
	for st in set_by_stat:                               # cap the aggregate set bonus per stat (cross-set)
		bonus[st] = int(bonus.get(st, 0)) + min(int(set_by_stat[st]), SET_BONUS_CAP)
	var _tf = _find(_session[pid]["fid"])                # gameplay-length P4: talents = a 3rd above-cap stat layer (own cap, same funnel as set bonuses → Sim stays byte-identical)
	if _tf != null:
		var tal_delta := GameData.talent_stat_deltas(_session[pid].get("talents", {}), str(_tf["classId"]))
		for st in tal_delta:
			bonus[st] = int(bonus.get(st, 0)) + min(int(tal_delta[st]), GameData.TALENT_STAT_CAP)
	_session[pid]["equip_bonus"] = bonus                 # cache for fast re-apply on respawn
	_session[pid]["item_power"] = ip_total               # gear score for the character sheet (P3)
	if ip_total > int(_session[pid].get("gear_best", 0)):   # P5: submit gear score ONLY when it improves (no spam)
		_session[pid]["gear_best"] = ip_total
		_submit_score(str(_session[pid]["char_id"]), str(_session[pid]["name"]), "gear", ip_total)
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
	# mark completed WITHOUT resetting rewarded (a concurrent session's turn-in must not re-open the claim)
	var wr = await supa.quest_complete_as(s["char_id"], qid, int(st["progress"]))
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
	# ATOMIC exactly-once claim: only the first caller (this session, a concurrent same-character session, or
	# reconnect recovery) flips rewarded false→true and is cleared to grant. A duplicate claim matches no row
	# (ok=false) and grants nothing — closing the concurrent-session reward-dupe. Do NOT set st["rewarded"]
	# optimistically before the claim: if another session won the claim, leaving our in-memory flag false lets
	# nothing here double-pay, and a real network failure lets recovery retry on next login.
	var wr = await supa.quest_mark_rewarded_as(char_id, qid)
	if not _session.has(pid):
		return
	if not wr.get("ok"):                                  # already claimed elsewhere, or not durable → grant nothing
		return
	st["rewarded"] = true                                 # durable + ours to grant
	var rw: Dictionary = quest.get("rewards", {})
	if rw.has("item"):                                    # item first: service-role write, survives a disconnect
		await _grant_quest_item(pid, char_id, access, rw["item"])
	if rw.has("dye") and str(rw["dye"]) != "":            # P6a: cosmetic dye — service-role + idempotent, survives a disconnect
		var dye_id := str(rw["dye"])
		var cok: bool = await supa.cosmetics_grant_as(char_id, dye_id)
		if cok and _session.has(pid):                     # mirror the shop path: fold into the LIVE session + push, so it's usable THIS session (not only after relog)
			var owned: Array = _session[pid].get("cos_owned", [])
			if not (dye_id in owned):
				owned.append(dye_id)
			if net != null:
				net.recv_cosmetics_changed.rpc_id(pid, owned.duplicate(), str(_session[pid].get("cos_dye", "")))
	if int(rw.get("pages", 0)) > 0:                       # P6a: Playbook Pages (attunement) — atomic DB add (self-guards on session)
		await _award_pages(pid, int(rw["pages"]))
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

# ---- BOUNTY BOARD (gameplay-length P6b: rotating daily/weekly objectives, co-located at the Quest Giver) ----
# Content is SERVER-DEFINED (below) and pushed to the client via HOME snapshot META, so future rotations/reward-
# tunes ship with ZERO client re-export. Progress is SESSION-ONLY (never persisted → not a dupe surface); the ONLY
# durable state is the per-period CLAIM ledger (progression.bounty_claims), advanced by the atomic bounty_claim fn.
# Rewards are currencies ONLY (credits/tokens/Pages) — no gear, no combat stat → determinism + FORMAT_MODS untouched.
const DAY_SECS := 86400                            # daily-bounty UTC period (WEEK_SECS=604800 already defined above)
const BOUNTY_DAILY_SLOTS := 3                      # how many of the daily pool rotate in each UTC day

# daily pool — each ~one short session of effort. kind: "kill" (match AND-combined vs the slain-mob descriptor via
# Quests.kill_matches, tier/map only — mobs cap ~lvl 8 so a mob min_level match would be uncompletable) / "circuit"
# (Camp Circuit clears, optional min_tier) / "drill" (a Two-Minute Drill run reaching >= wave).
const BOUNTY_DAILY := {
	"d_sweep":    {"name": "Camp Sweep",     "kind": "kill",    "match": {},                                  "count": 25, "desc": "Defeat 25 opponents anywhere.",              "rewards": {"credits": 600, "pages": 30}},
	"d_elites":   {"name": "Elite Detail",   "kind": "kill",    "match": {"tier": "elite"},                   "count": 12, "desc": "Defeat 12 elite opponents.",                 "rewards": {"credits": 500, "tokens": 25}},
	"d_gy5":      {"name": "Tower Patrol",   "kind": "kill",    "match": {"map": "glitchyard_5"},             "count": 15, "desc": "Defeat 15 in the Command Tower (GY5).",      "rewards": {"credits": 700, "pages": 25}},
	"d_gy5elite": {"name": "Command Cull",   "kind": "kill",    "match": {"map": "glitchyard_5", "tier": "elite"}, "count": 5, "desc": "Defeat 5 Command Tower elites (GY5).",  "rewards": {"tokens": 30, "pages": 35}},
	"d_circuit":  {"name": "Circuit Duty",   "kind": "circuit", "min_tier": 1,                                "count": 3,  "desc": "Clear the Camp Circuit 3 times.",           "rewards": {"credits": 600, "pages": 60}},
	# Phase 8 (the Away Circuit): direction into the new band — server-only rows, re-aimable with zero client
	# re-export. min_level hides them from characters the away_gate would refuse anyway (view-filter only).
	"d_roadgame": {"name": "Road Patrol",    "kind": "kill",    "match": {"map": "away_1"},                   "count": 15, "min_level": 8, "desc": "Defeat 15 on the Rival Practice Field.",     "rewards": {"credits": 650, "tokens": 25}},
	"d_gauntlet": {"name": "Gauntlet Runner","kind": "kill",    "match": {"map": "away_2", "tier": "elite"},  "count": 4,  "min_level": 8, "desc": "Defeat 4 Visitors' Gauntlet elites.",        "rewards": {"tokens": 30, "pages": 30}},
	# Phase 8 S3 (the Finals district) — view-filtered below finals_gate's level
	"d_quarter":  {"name": "Quarter Patrol", "kind": "kill",    "match": {"map": "finals_1"},                 "count": 15, "min_level": 17, "min_ip": 800, "desc": "Defeat 15 in the Contenders' Quarter.",     "rewards": {"credits": 900, "pages": 30}},
	"d_gallery":  {"name": "Gallery Runs",   "kind": "kill",    "match": {"map": "finals_2", "class": "grand_gallery"}, "count": 2, "min_level": 17, "min_ip": 800, "desc": "Break the Grand Gallery twice.",  "rewards": {"tokens": 40, "pages": 45}},
	"d_drill":    {"name": "Drill Grind",    "kind": "drill",   "wave": 6,                                    "count": 1,  "desc": "Reach wave 6 of a Two-Minute Drill.",       "rewards": {"credits": 500, "pages": 45}},
}
# weekly pool — one bigger chase (resets on the UTC week, same Thursday-00:00 boundary as the Camp affix).
const BOUNTY_WEEKLY := {
	"w_gauntlet": {"name": "Weekly Gauntlet","kind": "circuit", "min_tier": 1, "count": 15, "desc": "Clear the Camp Circuit 15 times this week.",  "rewards": {"credits": 4000, "pages": 220}},
	"w_elites":   {"name": "Weekly Muster",  "kind": "kill",    "match": {"tier": "elite"}, "count": 60, "desc": "Defeat 60 elite opponents this week.", "rewards": {"tokens": 90, "pages": 240}},
	"w_drill":    {"name": "Weekly Drills",  "kind": "drill",   "wave": 12, "count": 3, "desc": "Reach wave 12 of a Drill, 3 times this week.", "rewards": {"credits": 5000, "pages": 260}},
	# Phase 8 S2: the away chase — one Rival Coach win a week (10-min respawn, so contention-light)
	"w_rival":    {"name": "Away Win",       "kind": "kill",    "match": {"map": "away_boss", "tier": "boss"}, "count": 1, "min_level": 8, "desc": "Defeat the Rival Coach this week.", "rewards": {"credits": 3000, "tokens": 60, "pages": 120}},
}

var _bounty_busy := {}                             # pid → a bounty claim is in flight
var _bounty_next := {}                             # pid → earliest next bounty op (ms)

func _bounty_day() -> int:                          # UTC day integer — orchestration only (never read by the deterministic Sim), mirrors _current_affix
	return int(Time.get_unix_time_from_system() / DAY_SECS)
func _bounty_week() -> int:                         # UTC week integer (identical form to _current_affix at :591)
	return int(Time.get_unix_time_from_system() / WEEK_SECS)

# the currently-active bounty ids: BOUNTY_DAILY_SLOTS distinct dailies + 1 weekly, chosen deterministically by
# (id, period) hash (mirrors _circuit_template) so every player sees the SAME set and it rotates at the UTC boundary
# with no scheduler. sort-then-take guarantees distinct dailies (vs a per-slot hash that could collide).
func _daily_bounty_ids(day: int) -> Array:
	var ids: Array = BOUNTY_DAILY.keys()
	ids.sort_custom(func(a, b): return absi(("%s|%d" % [str(a), day]).hash()) < absi(("%s|%d" % [str(b), day]).hash()))
	return ids.slice(0, mini(BOUNTY_DAILY_SLOTS, ids.size()))
func _weekly_bounty_ids(week: int) -> Array:
	var ids: Array = BOUNTY_WEEKLY.keys()
	ids.sort_custom(func(a, b): return absi(("%s|%d" % [str(a), week]).hash()) < absi(("%s|%d" % [str(b), week]).hash()))
	return ids.slice(0, 1)
func _active_bounty_ids() -> Array:
	return _daily_bounty_ids(_bounty_day()) + _weekly_bounty_ids(_bounty_week())

func _bounty_def(id: String) -> Dictionary:
	if BOUNTY_DAILY.has(id):
		return BOUNTY_DAILY[id]
	if BOUNTY_WEEKLY.has(id):
		return BOUNTY_WEEKLY[id]
	return {}
func _bounty_is_weekly(id: String) -> bool:
	return BOUNTY_WEEKLY.has(id)
func _bounty_period(id: String) -> int:
	return _bounty_week() if _bounty_is_weekly(id) else _bounty_day()
func _bounty_period_end(id: String) -> int:         # epoch of the next reset — a fixed int per period (no per-tick META churn); the client renders the countdown
	return (_bounty_period(id) + 1) * (WEEK_SECS if _bounty_is_weekly(id) else DAY_SECS)

# has this character already claimed `id` for the CURRENT period? (in-session mirror of the durable ledger)
func _bounty_claimed(pid: int, id: String) -> bool:
	return _session.has(pid) and int((_session[pid].get("bounty_claims", {}) as Dictionary).get(id, -1)) >= _bounty_period(id)

# ensure a session progress row for `id` stamped with the current period; a stale period (UTC rollover while online)
# resets progress to 0. Session-only, self-healing on every read/hook — so no persisted progress + no rollover cron.
func _bounty_touch(pid: int, id: String) -> Dictionary:
	var b: Dictionary = _session[pid]["bounties"]
	var period := _bounty_period(id)
	var st = b.get(id)
	if st == null or int((st as Dictionary).get("period", -1)) != period:
		st = {"period": period, "progress": 0}
		b[id] = st
	return st

# advance one bounty's progress (called by the kind-specific hooks). Never advances a claimed/complete bounty; on
# the transition to complete, nudge the client (toast + panel refresh).
func _bounty_bump(pid: int, id: String, def: Dictionary) -> void:
	if not _session.has(pid) or _bounty_claimed(pid, id):
		return
	var st := _bounty_touch(pid, id)
	var count := int(def.get("count", 1))
	if int(st["progress"]) >= count:
		return
	st["progress"] = int(st["progress"]) + 1
	if net != null and int(st["progress"]) >= count:     # just became claimable → nudge the panel/toast
		net.recv_bounty_update.rpc_id(pid, id, int(st["progress"]), false)

# --- progress hooks (co-located beside the existing crediting sites) ---
func _bounty_on_kill(pid: int, victim) -> void:
	if not _session.has(pid):
		return
	var v := {"tier": str(victim.get("mobTier", "minion")), "map": str(victim.get("map", "")),
		"class": str(victim.get("classId", "")), "level": int(victim.get("mobLevel", 1))}
	for id in _active_bounty_ids():
		var def := _bounty_def(id)
		if str(def.get("kind", "")) != "kill":
			continue
		if not Quests.kill_matches({"objective": {"type": "kill", "match": def.get("match", {})}}, v):
			continue
		_bounty_bump(pid, id, def)
func _bounty_on_circuit(pid: int, tier: int) -> void:
	if not _session.has(pid):
		return
	for id in _active_bounty_ids():
		var def := _bounty_def(id)
		if str(def.get("kind", "")) != "circuit" or tier < int(def.get("min_tier", 1)):
			continue
		_bounty_bump(pid, id, def)
func _bounty_on_drill(pid: int, wave: int) -> void:    # Drill mobs are isDrill (excluded from _award_kills) → count the RUN's wave, not kills
	if not _session.has(pid):
		return
	for id in _active_bounty_ids():
		var def := _bounty_def(id)
		if str(def.get("kind", "")) != "drill" or wave < int(def.get("wave", 1)):
			continue
		_bounty_bump(pid, id, def)

# per-player active-bounty display array for the HOME snapshot META (id/name/desc/progress/claimed/reward/period-end).
# _bounty_touch self-heals the period so a rollover-while-at-home reflects immediately; period_end is a fixed int per
# period so it never churns the META hash (the client renders the live countdown locally from it).
func _bounty_meta(pid: int) -> Array:
	var out := []
	for id in _active_bounty_ids():
		var def := _bounty_def(id)
		# Phase 8: rows carrying a min_level / min_ip are hidden from characters below them (the away/finals
		# rows point into gated zones — showing an unreachable daily is just noise/frustration). The global
		# rotation stays deterministic; only this per-player VIEW filters (S3: min_ip mirrors finals_gate).
		if int(def.get("min_level", 0)) > int(_session.get(pid, {}).get("level", 1)):
			continue
		if int(def.get("min_ip", 0)) > int(_session.get(pid, {}).get("item_power", 0)):
			continue
		var st := _bounty_touch(pid, id)
		var count := int(def.get("count", 1))
		out.append({"id": id, "name": str(def.get("name", id)), "desc": str(def.get("desc", "")),
			"kind": str(def.get("kind", "")), "count": count, "progress": mini(int(st["progress"]), count),
			"claimed": _bounty_claimed(pid, id), "weekly": _bounty_is_weekly(id),
			"rewards": def.get("rewards", {}), "period_end": _bounty_period_end(id)})
	return out

# claim is mutating + DB-backed → rate-limited AND serialized (mirrors _quest_lock). Grant-only (like the quest
# reward path, NOT deduct-before-write) → follows the quest precedent and is NOT in the disconnect skip-list.
func _bounty_lock(pid: int) -> bool:
	var now := Time.get_ticks_msec()
	if not _session.has(pid) or bool(_bounty_busy.get(pid, false)) or now < int(_bounty_next.get(pid, 0)):
		return false
	_bounty_busy[pid] = true
	_bounty_next[pid] = now + 300
	return true

func bounty_action(pid: int, action: String, bounty_id: String) -> void:
	if not _bounty_lock(pid):
		return
	if not _at_questgiver(pid):                    # bounties are claimed at the SAME home-base NPC as quests (co-located)
		_bounty_busy.erase(pid)
		return
	if action == "claim":
		await _do_bounty_claim(pid, bounty_id)
	_bounty_busy.erase(pid)

func _do_bounty_claim(pid: int, id: String) -> void:
	if not _session.has(pid) or not _active_bounty_ids().has(id):   # not one of today's bounties (rotated out / forged id)
		return
	var def := _bounty_def(id)
	if def.is_empty():
		return
	var st := _bounty_touch(pid, id)
	if int(st["progress"]) < int(def.get("count", 1)):   # objective not finished
		return
	if _bounty_claimed(pid, id):                         # already claimed this period (in-session fast-path)
		return
	var s = _session[pid]
	var period := _bounty_period(id)
	# ATOMIC per-period claim FIRST (mark-before-grant): only the first caller in this period flips the ledger; a
	# replay / concurrent same-char session / stale period matches no row (ok=false) and grants nothing. A mid-grant
	# disconnect is a rare LOSS, never a dupe (ledger already advanced; no recovery re-fires) — the quest-path stance.
	var ok: bool = await supa.bounty_claim_as(str(s["char_id"]), id, period)
	if not _session.has(pid) or not ok:
		return
	(s["bounty_claims"] as Dictionary)[id] = period    # mirror the durable claim into the session
	var rw: Dictionary = def.get("rewards", {})
	if int(rw.get("credits", 0)) > 0:
		_award_credits(pid, int(rw["credits"]))
		_save_one(s, _find(s["fid"]))
	if int(rw.get("tokens", 0)) > 0:
		_award_tokens(pid, int(rw["tokens"]))
		_save_one(s, _find(s["fid"]))
	if int(rw.get("pages", 0)) > 0:                    # atomic DB add (self-guards on session)
		await _award_pages(pid, int(rw["pages"]))
	if net != null and _session.has(pid):
		net.recv_bounty_update.rpc_id(pid, id, int(def.get("count", 1)), true)
	print("[bounty] %s claimed '%s'" % [str(s.get("name", "?")), id])

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
			_award_credits(pid, int(args.get("amt", 500)))   # routes through the award bucket in atomic mode
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
		if _is_instance(mapname):                 # leave private instances alone (they self-manage + tear down)
			continue
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
	var from_map: String = str(f["map"])
	_worlds[from_map]["fighters"].erase(f)
	f["x"] = pos.x
	f["y"] = pos.y
	f["map"] = to_map
	f["arenaW"] = int(_worlds[to_map].get("arenaW", GameData.ARENA_W))
	f["arenaH"] = int(_worlds[to_map].get("arenaH", GameData.ARENA_H))
	_worlds[to_map]["fighters"].append(f)
	_spawn_pos[f["id"]] = pos
	if s != null:                                    # residents have no session (director-driven relocate)
		s["map"] = to_map
	_tp_next[f["id"]] = Time.get_ticks_msec() + TP_GRACE_MS
	_maybe_teardown_instance(from_map)               # left an instance (death/goto)? tear it down if now empty

func _find(id) -> Variant:
	for mapname in _worlds:
		for f in _worlds[mapname]["fighters"]:
			if f["id"] == id:
				return f
	return null

# ---- persistence ----
func _save_all() -> void:
	_retry_orphan_awards()                       # fire-and-forget; batch-swapped so ticks can't overlap
	for pid in _peers.duplicate():
		if _session.has(pid):
			_save_one(_session[pid], _find(_session[pid]["fid"]))

func _save_one(session: Dictionary, f) -> void:
	if supa == null:
		return
	if _atomic_econ:
		await _flush_awards(session)   # P3: currencies flow through the idempotent DB delta, not the PATCH
	# xp/level + the current world are always valid (they live on the session), so persist them even
	# for a corpse. Position is the live spot when alive, else the respawn point — never the death
	# spot — so last_map and last_x/last_y always stay consistent (you resume in the world you were in).
	# never persist a transient instance key as last_map (it won't exist on reconnect) — resume at home instead
	var save_map: String = str(session.get("map", World.HOME))
	if _is_instance(save_map):
		save_map = World.HOME
	var fields := {"xp": int(session["xp"]), "level": int(session["level"]), "last_map": save_map}
	if not _atomic_econ:               # legacy only: the absolute PATCH still carries the currencies
		fields["credits"] = int(session.get("credits", 0))
		fields["practice_tokens"] = int(session.get("tokens", 0))
	if f != null and not _is_instance(str(f.get("map", ""))):   # in an instance → don't save its coords either (home uses its fixed spawn)
		if f["alive"]:
			fields["last_x"] = f["x"]
			fields["last_y"] = f["y"]
		else:
			var sp: Vector2 = _spawn_pos.get(f["id"], Vector2(f["x"], f["y"]))
			fields["last_x"] = sp.x
			fields["last_y"] = sp.y
	var r = await supa.save_character_as(session["access"], session["char_id"], fields)
	if not (r is Dictionary and bool(r.get("ok", false))):   # a failed save must be OBSERVABLE, never silent
		_save_fail_n += 1
		print("[zone] ⚠ save FAILED for %s (HTTP %s) — xp/level/credits/position NOT persisted (fail #%d)" % [
			str(session.get("name", "?")), str(r.get("code", "?")) if r is Dictionary else "?", _save_fail_n])

# ---- interest-managed snapshots (per world) ----
func _broadcast() -> void:
	var pinfo := {}
	for pid in _peers:
		var s = _session[pid]
		var pf = _find(s["fid"])                  # include derived combat stats for skill-bar tooltips
		pinfo[s["fid"]] = {"level": int(s["level"]), "xp": int(s["xp"]), "xpNext": _xp_to_next(int(s["level"])),
			"name": str(s["name"]), "credits": int(s.get("credits", 0)),
			"dye": str(GameData.DYE_CATALOG.get(str(s.get("cos_dye", "")), {}).get("color", "")),   # P4: equipped dye color → all clients tint
			"dmgMult": float(pf["dmgMult"]) if pf != null else 1.0,
			"crit": float(pf["crit"]) if pf != null else 0.0,
			"critMult": float(pf["critMult"]) if pf != null else 1.5}
	for pid in _peers:
		var s = _session[pid]
		var f = _find(s["fid"])
		if f == null or not _worlds.has(s["map"]):
			continue
		var snap: Dictionary = _snapshot_for(_worlds[s["map"]], str(s["map"]), Vector2(f["x"], f["y"]), pinfo)
		snap["party"] = _party_roster(pid)        # roster (with live HP) for the party HUD — genuinely per-tick
		# ---- quasi-static META (portals + self sheet + zone pads + locker decals + drill counter) ----
		# These change RARELY, but the old code re-shipped them every 30 Hz tick — the bulk of the snapshot
		# bloat that overflowed client receive buffers ("Buffer full") → rubber-banding. Now: build once,
		# hash it, and ship it ONLY when it changes (or every META_HEARTBEAT ticks so a dropped unreliable
		# packet can't strand a client on a stale sheet/pads). The client caches + overlays it. Pure presentation.
		var meta := {"portals": _portals_for_player(str(s["map"]), pid),   # hide gated (secret) portals until unlocked
			# self stat block: the recipient's own APPLIED (capped, post-FORMAT_MODS) finals + capped equip_bonus
			"self": {
				"classId": str(f["classId"]), "level": int(s["level"]), "item_power": int(s.get("item_power", 0)), "scrap": int(s.get("scrap", 0)), "tokens": int(s.get("tokens", 0)),
				"max_intensity": int(s.get("max_intensity", 1)), "pages": int(s.get("pages", 0)), "has_key": bool(s.get("has_key", false)), "key_cost": MASTER_KEY_PAGES,   # Camp Circuit ladder + Pages + Master Key (P2)
				"locker_unlocked": bool(s.get("locker_unlocked", false)),   # Builder Mode: drives the Home portal "Purchase (10,000)" vs "Enter" state (P3)
				"ability_ungated": bool(s.get("ability_ungated", false)),   # gameplay-length P2: grandfathered → client hotbar shows the full kit unlocked
				"talents": (s.get("talents", {}) as Dictionary).duplicate(), "talent_spent": int(s.get("talent_spent", 0)),   # gameplay-length P4: talent tree state (T panel; the client derives points-available from level+spent)
				"paragon_perks": (s.get("paragon_perks", {}) as Dictionary).duplicate(), "paragon_spent": int(s.get("paragon_spent", 0)),   # gameplay-length P5: SLOW paragon state (Bench Board B panel); LIVE overtime_xp rides recv_overtime, never this hashed block
				"gear_bag_bonus": int(s.get("gear_bag_bonus", 0)), "pending_audible": (s.get("pending_audible", {}) as Dictionary).duplicate(),
				"cos_owned": (s.get("cos_owned", []) as Array).duplicate(), "cos_dye": str(s.get("cos_dye", "")),   # P4 cosmetics (wardrobe panel)
				"set_bonus": (s.get("set_bonus", {}) as Dictionary).duplicate(),
				"procs": (s.get("procs", []) as Array).duplicate(),
				"maxHP": float(f["maxHP"]), "dmgMult": float(f["dmgMult"]), "crit": float(f["crit"]), "critMult": float(f["critMult"]),
				"ms": float(f["ms"]), "cdr": float(f["cdr"]), "clutchDmg": float(f["clutchDmg"]), "clutchDR": float(f["clutchDR"]),
				"equip_bonus": (s.get("equip_bonus", {}) as Dictionary).duplicate(),
			}}
		if _is_instance(str(s["map"])) and str((_instances.get(str(s["map"]), {}) as Dictionary).get("mode", "")) == "drill":
			meta["drillWave"] = int((_instances[str(s["map"])] as Dictionary).get("wave", 0))   # Two-Minute Drill HUD counter
		if _template(str(s["map"])) == World.LOCKER:  # Builder Mode: the owner's placed build items → server decals (client _render_decals prefers these)
			meta["decals"] = (_instances.get(str(s["map"]), {}) as Dictionary).get("decals", [])
		if str(s["map"]) == World.HOME:           # the shop / forge pads + quest giver only exist in the home base
			meta["shop"] = {"x": World.SHOP_POS.x, "y": World.SHOP_POS.y}
			meta["forge"] = {"x": World.FORGE_POS.x, "y": World.FORGE_POS.y}
			meta["questgiver"] = {"x": World.QUESTGIVER_POS.x, "y": World.QUESTGIVER_POS.y}
			meta["practice"] = {"x": World.PRACTICE_POS.x, "y": World.PRACTICE_POS.y}   # the Practice Vendor (reward loop)
			meta["build_shop"] = {"x": World.BUILD_SHOP_POS.x, "y": World.BUILD_SHOP_POS.y}   # Builder Mode: buy furniture (P3)
			meta["bounties"] = _bounty_meta(pid)      # gameplay-length P6b: the day's active bounties (rendered in the Quest Giver panel)
			for lp in World.PORTALS.get(World.HOME, []):   # the Locker Room portal position → client's "Purchase (10,000)" prompt when not yet unlocked
				if str(lp.get("instance", "")) == World.LOCKER:
					meta["locker_portal"] = {"x": lp["x"], "y": lp["y"]}
					break
		var mh := str(meta).hash()                # ship META only when it changed, or on the heartbeat
		if not _meta_hash.has(pid) or int(_meta_hash[pid]) != mh or (_snap_count - int(_meta_tick.get(pid, -9999))) >= META_HEARTBEAT:
			snap["meta"] = meta
			_meta_hash[pid] = mh
			_meta_tick[pid] = _snap_count
		net.receive_snapshot.rpc_id(pid, snap)
	for mapname in _worlds:
		_worlds[mapname]["events"].clear()
	_snap_count += 1
	if _snap_count % 300 == 0:                    # concise heartbeat every ~10s
		var counts := []
		for mapname in _worlds:
			var np := 0
			for f in _worlds[mapname]["fighters"]:
				if f["team"] == 0 and not f.get("resident", false):   # real players only in the heartbeat
					np += 1
			counts.append("%s:%dp" % [mapname, np])
		var any_t: float = _worlds[_worlds.keys()[0]]["t"]   # every world ticks in lockstep — read any
		print("[zone] t=%.0f  %s" % [any_t, " ".join(counts)])

func _snapshot_for(w: Dictionary, mapname: String, center: Vector2, pinfo: Dictionary) -> Dictionary:
	var fs := []
	var now := Time.get_ticks_msec()                  # Phase 0.5: window the cosmetic hop echo (hopT) below
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
			if float(f.get("wobble", 0.0)) > 0.0:     # P3: Wobble stacks → client draws a pip meter (was invisible)
				d["wobble"] = float(f["wobble"])
			if bool(f["alive"]):                       # Phase 0.5 cosmetic hop echo — additive/optional (old clients ignore);
				var hs := int(_hop_t0.get(f["id"], -1))   # alive-gated so a fighter dying mid-hop can't float its corpse remotely
				if hs >= 0 and now - hs >= 0 and now - hs < HOP_ECHO_MS:
					d["hopT"] = (now - hs) / 1000.0   # elapsed seconds; the client renders the parabola (ignores its OWN, it predicts)
			if f.get("resident", false):          # RP0: AI resident identity (no session → not in pinfo)
				d["level"] = int(f.get("resLevel", 1))
				d["name"] = str(f.get("resName", ""))
				d["resident"] = true              # client draws a subtle marker
			if pinfo.has(f["id"]):
				var pi = pinfo[f["id"]]
				d["level"] = pi["level"]
				d["name"] = pi["name"]
				d["credits"] = pi["credits"]
				if str(pi.get("dye", "")) != "":       # P4: tint this player's model with their equipped dye
					d["dye"] = str(pi["dye"])
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
				# P3 core-shield cue, S3-generalized: ANY mob whose def carries coreShield (phased boss OR the
				# Grand Gallery elite-plus) shows shielded while a team core lives — the DR was server-active
				# but invisible for non-phased carriers (the exact "was invisible" defect P3 fixed for bosses).
				if float(GameData.CLASSES.get(str(f["classId"]), {}).get("coreShield", 0.0)) > 0.0:
					for e in w["fighters"]:
						if e["alive"] and e.get("isCore", false) and int(e["team"]) == int(f["team"]):
							d["shielded"] = true
							break
			fs.append(d)
	var ps := []
	var pcls := {}                                # owner id → classId for the Tier-2 projectile tint; a full
	for f in w["fighters"]:                       # pass (not interest-scoped: a shot can outrange its owner)
		pcls[f["id"]] = f["classId"]
	for p in w["projectiles"]:
		if Vector2(p["x"] - center.x, p["y"] - center.y).length() <= INTEREST_RADIUS:
			# "cls" is additive — old clients ignore unknown keys (same compat ride as the event types)
			ps.append({"x": p["x"], "y": p["y"], "delay": p.get("delay", 0.0), "cls": pcls.get(p.get("owner", ""), "")})
	var hz := []                                  # hazard zones only (dmg/slow) — buff zones stay invisible
	for z in w["zones"]:
		if float(z.get("dmg", 0.0)) <= 0.0 and z.get("slow", null) == null:
			continue
		if Vector2(z["x"] - center.x, z["y"] - center.y).length() <= INTEREST_RADIUS + float(z["radius"]):
			hz.append({"x": z["x"], "y": z["y"], "radius": z["radius"], "dmg": float(z.get("dmg", 0.0))})
	var tmpl := _template(mapname)                # client renders geometry/decals/portals by TEMPLATE name
	return {"fighters": fs, "projectiles": ps, "zones": hz,   # cover-panel props are read client-side from World.OBSTACLES by map name
		"events": w["events"].duplicate(true), "t": w["t"],
		"map": tmpl, "pvp": bool(w.get("pvp", false)),   # portals moved to the change-detected META block (per-player, gated)
		"arenaW": int(w.get("arenaW", GameData.ARENA_W)), "arenaH": int(w.get("arenaH", GameData.ARENA_H))}
