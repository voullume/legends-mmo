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

# server-side (P0 Builder Mode): atomically buy the Locker-Room unlock — flip locker_unlocked false→true. Gated IN
# the filter on locker_unlocked=eq.false with Prefer: return=representation, so ONLY the first caller (across
# concurrent same-character sessions OR a reconnect) matches a row and unlocks; a second/duplicate call matches
# nothing → ok=false → the server refunds the credits. Idempotent + dupe-safe (mirrors quest_mark_rewarded_as).
# service_role only: it bypasses RLS AND the characters_guard_progression pin (a player token would be pinned back
# to false by the trigger, so there is no dev fallback — the zone server always runs with the service key).
func locker_unlock_as(char_id: String) -> bool:
	if service_key == "":
		return false
	var q := "?id=eq.%s&locker_unlocked=eq.false&select=id" % char_id
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/characters" + q, JSON.stringify({"locker_unlocked": true}), PackedStringArray(["Prefer: return=representation"]), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0

# server-side (P1 Builder Mode): a character's PLACED build items = their Locker-Room layout. The zone server reads
# it on room entry and caches the result as snapshot decals. Scoped by character_id (the server passes the entering
# player's own id). Service-role read (reliable, server-owned); falls back to the player token in dev.
func get_placed_build_items_as(token: String, char_id: String):
	var auth: String = service_key if service_key != "" else token
	var q := "?character_id=eq.%s&category=eq.build&placed=eq.true&select=id,model,xform" % char_id
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/inventory" + q, "", PackedStringArray(), auth)
	return r["data"] if r["code"] == 200 and r["data"] is Array else null   # null on a read error → callers keep the prior cache (don't blank the room)

# server-side (P2 Builder Mode): the models of a character's OWNED build items (placed + unplaced), for the cap
# check. Returns an Array of model strings, or NULL on a failed read so the caller FAILS CLOSED (deny the buy)
# rather than reading 0 owned and letting an unbounded buy through. Service-role, scoped by character_id.
func build_owned_models_as(char_id: String):
	if service_key == "":
		return null
	var q := "?character_id=eq.%s&category=eq.build&select=model" % char_id
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/inventory" + q, "", PackedStringArray(), service_key)
	if r["code"] != 200 or not (r["data"] is Array):
		return null
	var out := []
	for row in (r["data"] as Array):
		out.append(str((row as Dictionary).get("model", "")))
	return out

# server-side (P2): insert ONE unplaced build item. name=model (P3 can prettify); rarity/slot are the sentinels
# the build-shape CHECK requires. Service-role (inventory is server-write-only). ok iff a row was created.
func add_build_item_as(char_id: String, model: String) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var body := {"character_id": char_id, "category": "build", "model": model, "name": model,
		"rarity": "common", "slot": "build", "placed": false}
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/inventory", JSON.stringify(body), PackedStringArray(["Prefer: return=representation"]), service_key)
	var ok: bool = r["code"] == 201 and r["data"] is Array and (r["data"] as Array).size() > 0
	return {"ok": ok, "id": str((r["data"][0] as Dictionary).get("id", "")) if ok else "", "code": r["code"]}

# server-side (P2): PLACE an owned, unplaced build item — gated IN the filter on category=build & placed=false so a
# duplicate/concurrent place can't double-apply, and a client can't place gear or another character's item (scoped
# by character_id). Sets placed=true + the (server-clamped) xform. ok iff a row actually flipped. Service-role.
func build_place_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&category=eq.build&placed=eq.false&select=id" % [item_id, char_id]
	var body := JSON.stringify({"placed": true, "xform": xform})
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, body, PackedStringArray(["Prefer: return=representation"]), service_key)
	return {"ok": r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0}

# server-side (P2): MOVE/rotate/lift an already-PLACED build item (gated on placed=true). Only the xform changes.
func build_move_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&category=eq.build&placed=eq.true&select=id" % [item_id, char_id]
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, JSON.stringify({"xform": xform}), PackedStringArray(["Prefer: return=representation"]), service_key)
	return {"ok": r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0}

# server-side (P2): REMOVE a placed item back to the Build tab (placed=false, xform cleared) — gated on placed=true
# so it returns the SAME item (no refund, no dupe). ok iff a placed row actually flipped. Service-role.
func build_remove_as(char_id: String, item_id: String) -> Dictionary:
	if service_key == "":
		return {"ok": false}
	var q := "?id=eq.%s&character_id=eq.%s&category=eq.build&placed=eq.true&select=id" % [item_id, char_id]
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory" + q, JSON.stringify({"placed": false, "xform": null}), PackedStringArray(["Prefer: return=representation"]), service_key)
	return {"ok": r["code"] >= 200 and r["code"] < 300 and r["data"] is Array and (r["data"] as Array).size() > 0}

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

# --- progression (endgame P1): Intensity ladder + Playbook Pages. Server-only writes; client READS own. ---
# READ on the player's token (RLS-scoped). No row yet → defaults (max_intensity 1, pages 0).
func get_progression_as(token: String) -> Dictionary:
	# select=* (not a column list) so a not-yet-applied column (e.g. has_master_key before its migration lands)
	# can't 400 the whole read and transiently reset the live Intensity ladder to 1 during a deploy window.
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/progression?select=*&limit=1", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array and (r["data"] as Array).size() > 0:
		var row = r["data"][0]
		var tal = row.get("talents", {})
		var par = row.get("paragon_perks", {})
		return {"ok": true, "max_intensity": int(row.get("max_intensity", 1)), "pages": int(row.get("playbook_pages", 0)), "has_key": bool(row.get("has_master_key", false)),
			"talents": (tal if tal is Dictionary else {}), "talent_spent": int(row.get("talent_spent", 0)),
			"overtime_xp": int(row.get("overtime_xp", 0)), "paragon_perks": (par if par is Dictionary else {}), "paragon_spent": int(row.get("paragon_spent", 0)), "gear_bag_bonus": int(row.get("gear_bag_bonus", 0))}
	return {"ok": r["code"] == 200, "max_intensity": 1, "pages": 0, "has_key": false, "talents": {}, "talent_spent": 0,
		"overtime_xp": 0, "paragon_perks": {}, "paragon_spent": 0, "gear_bag_bonus": 0}

# atomically add (+earn) or spend (−) Playbook Pages via progression_add_pages. Returns {ok,total}: ok=false
# when a spend underflows (insufficient). Service-role only.
func progression_add_pages_as(char_id: String, delta: int) -> Dictionary:
	if service_key == "":
		return {"ok": false, "total": 0}
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_add_pages", JSON.stringify({"p_char": char_id, "p_delta": delta}), PackedStringArray(), service_key)
	var val = r["data"]
	if val is Array and (val as Array).size() > 0:
		val = val[0]
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and val != null
	return {"ok": ok, "total": int(val) if ok else 0}

# atomically forge the Master Key: spend `cost` pages + set has_master_key in ONE gated update. Returns true
# only if it crafted (enough pages AND not already keyed) — no double-spend/craft. Service-role only.
func progression_craft_key_as(char_id: String, cost: int) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_craft_key", JSON.stringify({"p_char": char_id, "p_cost": cost}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] == true

# gameplay-length P4: atomically spend `ranks` talent points into `node`, with the level budget + node cap enforced
# in-DB (dupe-safe backstop). Returns {ok,talents}: ok=false when the spend is refused (over budget / node full /
# bad ranks → the RPC returns null). p_budget = level-1 (point budget), p_node_max = the node's rank cap. Service-role only.
func talents_spend_as(char_id: String, node: String, ranks: int, budget: int, node_max: int) -> Dictionary:
	if service_key == "":
		return {"ok": false, "talents": {}}
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_talent_spend", JSON.stringify({"p_char": char_id, "p_node": node, "p_ranks": ranks, "p_budget": budget, "p_node_max": node_max}), PackedStringArray(), service_key)
	var val = r["data"]
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and val != null and val is Dictionary
	return {"ok": ok, "talents": (val if ok else {})}

# gameplay-length P4: atomically wipe the talent allocation (credit cost charged server-side beforehand). Returns
# true on success. Service-role only.
func talents_respec_as(char_id: String) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_talent_respec", JSON.stringify({"p_char": char_id}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] != null

# gameplay-length P5: flush the monotonic post-cap overtime odometer + the derived gear-bag bonus (greatest() in-DB, so
# a stale/late write can never lower either). Returns the resulting overtime_xp. Service-role only.
func progression_set_overtime_as(char_id: String, overtime: int, bag_bonus: int) -> int:
	if service_key == "":
		return 0
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_set_overtime", JSON.stringify({"p_char": char_id, "p_overtime": overtime, "p_bag_bonus": bag_bonus}), PackedStringArray(), service_key)
	var val = r["data"]
	if val is Array and (val as Array).size() > 0:
		val = val[0]
	return int(val) if (r["code"] >= 200 and r["code"] < 300 and val != null) else 0

# gameplay-length P5: SET the whole paragon Bench Board (idempotent, budget-guarded in-DB). Returns {ok,perks}: ok=false
# when refused (spent out of [0,budget] → RPC returns null). p_budget = paragon_level (server-derived). Service-role only.
func paragon_set_as(char_id: String, perks: Dictionary, spent: int, budget: int) -> Dictionary:
	if service_key == "":
		return {"ok": false, "perks": {}}
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_paragon_set", JSON.stringify({"p_char": char_id, "p_perks": perks, "p_spent": spent, "p_budget": budget}), PackedStringArray(), service_key)
	var val = r["data"]
	var ok: bool = r["code"] >= 200 and r["code"] < 300 and val != null and val is Dictionary
	return {"ok": ok, "perks": (val if ok else {})}

# gameplay-length P1(d): rested XP. LOGIN — atomically accrue the offline pool (p_rate per hour, capped at p_cap,
# both level-scaled by the caller), mark the character online, and return the resulting rested pool. Service-role only.
func progression_rest_login_as(char_id: String, rate_per_hr: float, cap: int) -> int:
	if service_key == "":
		return 0
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_rest_login", JSON.stringify({"p_char": char_id, "p_rate": rate_per_hr, "p_cap": cap}), PackedStringArray(), service_key)
	var val = r["data"]
	if val is Array and (val as Array).size() > 0:
		val = val[0]
	return int(val) if (r["code"] >= 200 and r["code"] < 300 and val != null) else 0

# LOGOUT — persist the remaining rested pool + stamp the offline time (next login accrues from here). Service-role only.
func progression_rest_logout_as(char_id: String, rested: int) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_rest_logout", JSON.stringify({"p_char": char_id, "p_rested": rested}), PackedStringArray(), service_key)

# --- cosmetics (P4): dyes. Server-only writes; client READS own row. ---
func get_cosmetics_as(token: String) -> Dictionary:
	# select=* (resilient) — before the migration lands the table 404s → defaults, never a hard column error
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/character_cosmetics?select=*&limit=1", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array and (r["data"] as Array).size() > 0:
		var owned = r["data"][0].get("owned", [])
		return {"ok": true, "owned": owned if owned is Array else [], "equipped": str(r["data"][0].get("equipped", "")) if r["data"][0].get("equipped") != null else ""}
	return {"ok": r["code"] == 200, "owned": [], "equipped": ""}

# atomic dye grant (add-if-not-owned). Returns true iff newly granted. Service-role only.
func cosmetics_grant_as(char_id: String, dye: String) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/cosmetics_grant", JSON.stringify({"p_char": char_id, "p_dye": dye}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] == true

# equip a dye (ownership enforced in the write; "" clears to default). Returns true on success. Service-role only.
func cosmetics_equip_as(char_id: String, dye: String) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/cosmetics_equip", JSON.stringify({"p_char": char_id, "p_dye": dye}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] == true

# --- leaderboards (P5): server-authoritative. Submit keeps the personal best; the board is read server-side. ---
func leaderboard_submit_as(category: String, char_id: String, name: String, score: int) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/leaderboard_submit",
		JSON.stringify({"p_cat": category, "p_char": char_id, "p_name": name, "p_score": score}), PackedStringArray(), service_key)

# --- RP4: append one AI-resident playtest anomaly row (service_role; clients never touch this table) ---
func bot_report_as(resident_id: String, resident_name: String, zone: String, kind: String, detail: String, metrics: Dictionary) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_POST, "/rest/v1/bot_reports",
		JSON.stringify({"resident_id": resident_id, "resident_name": resident_name, "zone": zone, "kind": kind, "detail": detail, "metrics": metrics}), PackedStringArray(), service_key)

# top-N for a category (service_role read — clients never SELECT the table directly). Returns [{name,score}].
func leaderboard_top_as(category: String, lim: int) -> Dictionary:
	if service_key == "":
		return {"entries": []}
	var q := "?category=eq.%s&select=name,score&order=score.desc&limit=%d" % [category, lim]
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/leaderboards" + q, "", PackedStringArray(), service_key)
	if r["code"] == 200 and r["data"] is Array:
		return {"entries": r["data"]}
	return {"entries": []}

# atomic Intensity unlock via the progression_unlock rpc (ensures the row + bumps only from the cleared tier).
# Returns the resulting max_intensity. Service-role only (clients can't self-unlock).
func progression_unlock_as(char_id: String, tier: int) -> int:
	if service_key == "":
		return 0
	var body := JSON.stringify({"p_char": char_id, "p_tier": tier})
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/progression_unlock", body, PackedStringArray(), service_key)
	var val = r["data"]
	if val is Array and (val as Array).size() > 0:
		val = val[0]
	if r["code"] >= 200 and r["code"] < 300 and val != null:
		return int(val)
	return 0

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

# gameplay-length P6b: atomically claim a bounty for the current UTC period. Returns true iff THIS call won the
# claim (a replay / concurrent same-character session / stale-period request matches no row → false → grant
# nothing). p_period is the server-computed UTC day/week integer (never client-supplied). Service-role only.
func bounty_claim_as(char_id: String, bounty_id: String, period: int) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/bounty_claim", JSON.stringify({"p_char": char_id, "p_bounty": bounty_id, "p_period": period}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] == true

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
