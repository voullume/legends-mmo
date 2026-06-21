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

func _headers() -> PackedStringArray:
	var h := PackedStringArray(["apikey: " + ANON, "Content-Type: application/json"])
	if access_token != "":
		h.append("Authorization: Bearer " + access_token)
	return h

# One-shot HTTP request → { code, data, error }. A fresh HTTPRequest per call (await-friendly);
# bounded by TIMEOUT so a hung connection always resolves instead of suspending the UI forever.
func _http(method: int, path: String, body := "", extra := PackedStringArray()) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = TIMEOUT
	add_child(req)
	var headers := _headers()
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

func _err(r) -> String:
	if str(r.get("error", "")) != "":
		return r["error"]
	var d = r["data"]
	if d is Dictionary:
		for k in ["msg", "message", "error_description", "error"]:
			if d.has(k):
				return str(d[k])
	return "HTTP %d" % int(r.get("code", 0))
