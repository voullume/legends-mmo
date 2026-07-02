extends Node
## SUPABASE CLIENT (Phase 3). Email/password auth + the `characters` table over REST.
## The anon key is PUBLIC and safe to embed — Row-Level Security protects the data, and the
## DB enforces one immutable-class character per account (see the legends_characters migration).
##
## All methods are async (await them):
##   var r = await supa.sign_in(email, pw)         -> {ok, error}
##   var c = await supa.get_character()            -> {ok, character|null, error}
##   var c = await supa.create_character(name,cls) -> {ok, character, error}
##   await supa.save_character(id, {last_x:..,..}) -> {ok, error, expired}

const URL := "https://reaiolskmzorymnrbtab.supabase.co"
const ANON := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJlYWlvbHNrbXpvcnltbnJidGFiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE1NjkyMTEsImV4cCI6MjA5NzE0NTIxMX0.fmzxS-O0ZByr4_J2mIuuYdQ1eIbbHoKFELVqLZh1V6g"
const TIMEOUT := 15.0

var access_token := ""
var refresh_token := ""
var user_id := ""
var email := ""
var service_key := ""   # service_role JWT (zone server only, from env) — bypasses RLS for inventory writes

func _headers(token := "") -> PackedStringArray:
	var t: String = token if token != "" else access_token
	var h := PackedStringArray(["apikey: " + ANON, "Content-Type: application/json"])
	if t != "":
		h.append("Authorization: Bearer " + t)
	return h

# One-shot HTTP request → { code, data, error }. A fresh HTTPRequest per call (await-friendly);
# bounded by TIMEOUT so a hung connection always resolves instead of suspending the UI forever.
func _http(method: int, path: String, body := "", extra := PackedStringArray(), token := "") -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT
	add_child(req)
	var headers := _headers(token)
	for e in extra:
		headers.append(e)
	var err := req.request(URL + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"code": 0, "data": null, "error": "HTTPRequest error %d" % err}
	var res = await req.request_completed     # [result, code, headers, body]
	req.queue_free()
	var result: int = res[0]
	if result != HTTPRequest.RESULT_SUCCESS:  # timeout / can't connect / TLS — surface as an error
		return {"code": 0, "data": null, "error": "network error %d" % result}
	var code: int = res[1]
	var text: String = (res[3] as PackedByteArray).get_string_from_utf8()
	var data = JSON.parse_string(text) if text != "" else null
	return {"code": code, "data": data, "error": ""}

# authed request with one transparent refresh-and-retry on a 401 (token expiry)
func _auth_http(method: int, path: String, body := "", extra := PackedStringArray()) -> Dictionary:
	var r = await _http(method, path, body, extra)
	if r["code"] == 401 and refresh_token != "":
		if await refresh_session():
			r = await _http(method, path, body, extra)
	return r

func _id_of(d) -> String:
	if d != null and d is Dictionary and d.has("user") and d["user"] is Dictionary:
		return str(d["user"].get("id", ""))
	return ""

func _store_session(d) -> void:
	access_token = str(d.get("access_token", ""))
	refresh_token = str(d.get("refresh_token", ""))
	user_id = _id_of(d)

# --- auth ---
func sign_up(em: String, password: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_POST, "/auth/v1/signup", JSON.stringify({"email": em, "password": password}))
	if r["code"] >= 200 and r["code"] < 300:
		var d = r["data"]
		if d is Dictionary and d.has("access_token"):     # auto-confirmed → instant session
			_store_session(d)
			email = em
			return {"ok": true, "needs_confirm": false}
		# no session in the signup response — try to sign in (works when the account is auto-confirmed)
		var si = await sign_in(em, password)
		if si.get("ok"):
			return {"ok": true, "needs_confirm": false}
		return {"ok": true, "needs_confirm": true}        # confirmation still required (no auto-confirm)
	return {"ok": false, "needs_confirm": false, "error": _err(r)}

func sign_in(em: String, password: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=password", JSON.stringify({"email": em, "password": password}))
	if r["code"] == 200 and r["data"] is Dictionary and r["data"].has("access_token"):
		_store_session(r["data"])
		email = em
		return {"ok": true}
	return {"ok": false, "error": _err(r)}

func refresh_session() -> bool:
	if refresh_token == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=refresh_token", JSON.stringify({"refresh_token": refresh_token}))
	if r["code"] == 200 and r["data"] is Dictionary and r["data"].has("access_token"):
		_store_session(r["data"])
		return true
	return false

func signed_in() -> bool:
	return access_token != ""

# --- characters (one per account; class set at creation, immutable) ---
func get_character() -> Dictionary:
	var r = await _auth_http(HTTPClient.METHOD_GET, "/rest/v1/characters?select=*&limit=1")
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "character": (r["data"][0] if r["data"].size() > 0 else null)}
	return {"ok": false, "character": null, "error": _err(r)}

func create_character(name: String, cls: String) -> Dictionary:
	var r = await _auth_http(HTTPClient.METHOD_POST, "/rest/v1/characters",
		JSON.stringify({"name": name, "class": cls}), PackedStringArray(["Prefer: return=representation"]))
	if r["code"] == 201 and r["data"] is Array and r["data"].size() > 0:
		return {"ok": true, "character": r["data"][0]}
	return {"ok": false, "character": null, "error": _err(r)}

func save_character(char_id: String, fields: Dictionary) -> Dictionary:
	var r = await _auth_http(HTTPClient.METHOD_PATCH, "/rest/v1/characters?id=eq." + char_id, JSON.stringify(fields))
	var ok: bool = r["code"] >= 200 and r["code"] < 300
	return {"ok": ok, "expired": r["code"] == 401, "error": _err(r)}

# --- inventory (this account's items; RLS scopes to characters we own) ---
func get_inventory() -> Dictionary:
	var r = await _auth_http(HTTPClient.METHOD_GET, "/rest/v1/inventory?select=*&order=created_at.desc")
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "items": r["data"]}
	return {"ok": false, "items": [], "error": _err(r)}

# --- server-side (explicit token, no shared session) — used by the zone server ---
func get_character_as(token: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/characters?select=*&limit=1", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "character": (r["data"][0] if r["data"].size() > 0 else null), "code": r["code"]}
	return {"ok": false, "character": null, "code": r["code"], "error": _err(r)}

func save_character_as(token: String, char_id: String, fields: Dictionary) -> Dictionary:
	# Server writes via service_role (bypasses RLS + the client column-guard trigger) so the zone stays the sole
	# authority over economy/progression columns (credits/level/xp/practice_tokens). Falls back to the player
	# token only if no service key is configured (dev). See the characters_guard_progression migration.
	var auth: String = service_key if service_key != "" else token
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/characters?id=eq." + char_id, JSON.stringify(fields), PackedStringArray(), auth)
	return {"ok": r["code"] >= 200 and r["code"] < 300, "code": r["code"]}

# inventory WRITES go out as service_role (bypasses RLS) when the server has the key, so clients
# can be denied direct write access; falls back to the player token if no service key is configured.
func add_item_as(token: String, char_id: String, item: Dictionary) -> Dictionary:
	var body := item.duplicate()
	body["character_id"] = char_id
	var auth: String = service_key if service_key != "" else token
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/inventory", JSON.stringify(body), PackedStringArray(), auth)
	return {"ok": r["code"] == 201, "code": r["code"]}

# READ stays on the player's token (RLS-scoped to their own items)
func get_inventory_as(token: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/inventory?select=id,slot,rarity,bonus_stat,bonus_amt,primary_stat,primary_amt,ilvl,affixes,item_power,upgrade_level,reforge_count,set_id,unique_id,proc_id,proc_tier,equipped,locked,created_at&order=created_at.desc", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "items": r["data"]}
	return {"ok": false, "items": []}

func inv_set_equipped_as(token: String, filter: String, val: bool) -> Dictionary:
	var auth: String = service_key if service_key != "" else token
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory?" + filter, JSON.stringify({"equipped": val}), PackedStringArray(), auth)
	return {"ok": r["code"] >= 200 and r["code"] < 300, "code": r["code"]}

# server-side: set an item's persistent `locked` flag. Scoped by character_id so a client can't lock
# items it doesn't own; return=representation confirms a row actually matched (ok only if it changed).
func inv_set_locked_as(token: String, char_id: String, item_id: String, val: bool) -> Dictionary:
	var auth: String = service_key if service_key != "" else token
	var q := "?id=eq.%s&character_id=eq.%s&select=id" % [item_id, char_id]
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, JSON.stringify({"locked": val}), PackedStringArray(["Prefer: return=representation"]), auth)
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "code": r["code"]}

# server-side: is this user registered in the admins table? (service-role read; clients can't see it)
func is_admin_as(user_id: String) -> bool:
	if service_key == "" or user_id == "":
		return false
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/admins?select=user_id&user_id=eq." + user_id, "", PackedStringArray(), service_key)
	return r["code"] == 200 and r["data"] is Array and (r["data"] as Array).size() > 0

# server-side: wipe a character's inventory (service-role; used by the admin tool)
func clear_inventory_as(char_id: String) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_DELETE, "/rest/v1/inventory?character_id=eq." + char_id, "", PackedStringArray(), service_key)

# server-side: atomically delete an item owned by this character and return its rarity (for the sell
# price). Scoped by character_id so a client can't sell items it doesn't own. The DELETE returns the
# row ONLY to the call that actually removed it (Prefer: return=representation) — so a second/concurrent
# sell of the same id gets an empty body and no payout (closes the GET-then-DELETE double-pay race).
func sell_item_as(char_id: String, item_id: String) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&select=rarity" % [item_id, char_id]
	var d = await _http(HTTPClient.METHOD_DELETE, "/rest/v1/inventory" + q, "", PackedStringArray(["Prefer: return=representation"]), service_key)
	if d["code"] >= 200 and d["code"] < 300 and d["data"] is Array and (d["data"] as Array).size() > 0:
		return {"ok": true, "rarity": str(d["data"][0].get("rarity", "common"))}
	return {"ok": false}

# server-side: like sell_item_as, but the DELETE filter also requires equipped=false AND locked=false,
# so an equipped or locked item is NEVER removed (and yields no payout). Putting the guard IN the filter
# keeps it atomic: the row is only deleted — and the rarity only returned — to the call that legitimately
# removed an unequipped, unlocked item. This is the single sell path for both single + bulk selling.
func sell_item_safe_as(char_id: String, item_id: String) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&equipped=eq.false&locked=eq.false&select=rarity" % [item_id, char_id]
	var d = await _http(HTTPClient.METHOD_DELETE, "/rest/v1/inventory" + q, "", PackedStringArray(["Prefer: return=representation"]), service_key)
	if d["code"] >= 200 and d["code"] < 300 and d["data"] is Array and (d["data"] as Array).size() > 0:
		return {"ok": true, "rarity": str(d["data"][0].get("rarity", "common"))}
	return {"ok": false}

# --- materials (Phase 4): server-only writes via the atomic mats_add rpc; clients READ own via RLS ---
# atomically add (delta>0) or spend (delta<0) scrap. ok=false when a spend would underflow (insufficient).
func mats_add_as(char_id: String, delta: int) -> Dictionary:
	if service_key == "":
		return {"ok": false, "total": 0}
	var body := JSON.stringify({"p_char": char_id, "p_scrap": delta})
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/mats_add", body, PackedStringArray(), service_key)
	var val = r["data"]
	if val is Array and (val as Array).size() > 0:        # tolerate scalar-as-row shapes
		val = val[0]
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and val != null
	return {"ok": ok, "total": int(val) if ok else 0, "code": r["code"]}

# READ on the player's token (RLS-scoped). No row yet → scrap 0.
func get_mats_as(token: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/materials?select=scrap&limit=1", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array and (r["data"] as Array).size() > 0:
		return {"ok": true, "scrap": int(r["data"][0].get("scrap", 0))}
	return {"ok": r["code"] == 200, "scrap": 0}

# atomic item upgrade: PATCH gated on upgrade_level=eq.<old> so only the call that saw the old level wins
# (closes the read-modify-write race). Sets the new level + recomputed item_power.
func inv_upgrade_as(char_id: String, item_id: String, old_level: int, new_level: int, new_ip: int) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&upgrade_level=eq.%d&select=upgrade_level" % [item_id, char_id, old_level]
	var body := JSON.stringify({"upgrade_level": new_level, "item_power": new_ip})
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, body, PackedStringArray(["Prefer: return=representation"]), service_key)
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "code": r["code"]}

# atomic reforge: reroll the affixes, gated on reforge_count=eq.<old> so a duplicate/concurrent reforge
# can't double-apply or double-charge. affixes is a JSON array of {stat,amt}.
func inv_reforge_as(char_id: String, item_id: String, old_count: int, new_count: int, new_affixes: Array, new_ip: int) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&reforge_count=eq.%d&select=reforge_count" % [item_id, char_id, old_count]
	var body := JSON.stringify({"affixes": new_affixes, "reforge_count": new_count, "item_power": new_ip})
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, body, PackedStringArray(["Prefer: return=representation"]), service_key)
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "code": r["code"]}

# --- quests (server-authoritative progress; clients READ their own rows, server WRITES) ---
# READ on the player's token (RLS-scoped to their own character's quest rows)
func get_quests_as(token: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/character_quests?select=quest_id,progress,completed,rewarded", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "items": r["data"]}
	return {"ok": false, "items": []}

# UPSERT a quest row as service_role (accept + turn-in: writes completed/rewarded). Keyed on the
# (character_id, quest_id) unique constraint via on_conflict + merge-duplicates. Server-only.
func quest_save_as(char_id: String, quest_id: String, progress: int, completed: bool, rewarded: bool) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var body := {"character_id": char_id, "quest_id": quest_id, "progress": progress, "completed": completed, "rewarded": rewarded}
	var extra := PackedStringArray(["Prefer: resolution=merge-duplicates,return=minimal"])
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/character_quests?on_conflict=character_id,quest_id", JSON.stringify(body), extra, service_key)
	return {"ok": r["code"] >= 200 and r["code"] < 300, "code": r["code"]}

# Turn-in: mark completed WITHOUT touching rewarded (the row already exists from accept). Deliberately not
# a merge-upsert of the whole row — a concurrent second session's turn-in must never reset rewarded back to
# false (which would re-open the reward claim below). Atomic: row is scoped by (character_id, quest_id).
func quest_complete_as(char_id: String, quest_id: String, progress: int) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var filter := "character_id=eq.%s&quest_id=eq.%s&select=quest_id" % [char_id, quest_id]
	var body := JSON.stringify({"completed": true, "progress": progress})
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/character_quests?" + filter, body, PackedStringArray(["Prefer: return=representation"]), service_key)
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "code": r["code"]}

# Reward claim: atomically flip rewarded false→true, gated IN the filter on completed=true AND rewarded=false,
# with return=representation — so ONLY the first caller (across concurrent same-character sessions OR reconnect
# recovery) matches a row and is cleared to grant. A second/duplicate claim matches nothing (ok=false) → grants
# nothing. This is the dupe-safety contract for the reward payout (mirrors sell_item_safe_as / inv_upgrade_as).
func quest_mark_rewarded_as(char_id: String, quest_id: String) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var filter := "character_id=eq.%s&quest_id=eq.%s&completed=eq.true&rewarded=eq.false&select=quest_id" % [char_id, quest_id]
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/character_quests?" + filter, JSON.stringify({"rewarded": true}), PackedStringArray(["Prefer: return=representation"]), service_key)
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "code": r["code"]}

# PATCH only the progress column (the kill path). Deliberately does NOT touch completed/rewarded, so
# an out-of-order in-flight progress write can never clobber a turn-in's completed=true (dupe fix).
func quest_progress_as(char_id: String, quest_id: String, progress: int) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var filter := "character_id=eq.%s&quest_id=eq.%s" % [char_id, quest_id]
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/character_quests?" + filter, JSON.stringify({"progress": progress}), PackedStringArray(["Prefer: return=minimal"]), service_key)
	return {"ok": r["code"] >= 200 and r["code"] < 300, "code": r["code"]}

func refresh_as(rtoken: String) -> Dictionary:
	var r = await _http(HTTPClient.METHOD_POST, "/auth/v1/token?grant_type=refresh_token", JSON.stringify({"refresh_token": rtoken}))
	if r["code"] == 200 and r["data"] is Dictionary and r["data"].has("access_token"):
		return {"ok": true, "access_token": r["data"]["access_token"], "refresh_token": str(r["data"].get("refresh_token", rtoken))}
	return {"ok": false}

func _err(r) -> String:
	if str(r.get("error", "")) != "":
		return r["error"]
	var d = r["data"]
	if d is Dictionary:
		for k in ["msg", "message", "error_description", "error"]:
			if d.has(k):
				return str(d[k])
	return "HTTP %d" % int(r.get("code", 0))
