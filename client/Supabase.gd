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
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/characters?id=eq." + char_id, JSON.stringify(fields), PackedStringArray(), token)
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
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/inventory?select=id,slot,rarity,bonus_stat,bonus_amt,equipped", "", PackedStringArray(), token)
	if r["code"] == 200 and r["data"] is Array:
		return {"ok": true, "items": r["data"]}
	return {"ok": false, "items": []}

func inv_set_equipped_as(token: String, filter: String, val: bool) -> Dictionary:
	var auth: String = service_key if service_key != "" else token
	var r = await _http(HTTPClient.METHOD_PATCH, "/rest/v1/inventory?" + filter, JSON.stringify({"equipped": val}), PackedStringArray(), auth)
	return {"ok": r["code"] >= 200 and r["code"] < 300, "code": r["code"]}

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
