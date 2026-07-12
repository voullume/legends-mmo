extends "res://client/Supabase.gd"
## SERVER-ONLY Supabase repository (stabilization P3). The dedicated zone server instantiates THIS
## class (see Main.gd _make_zone_server) instead of the plain client adapter; it adds the atomic
## economy RPCs from supabase/migrations/20260714000000_stab_atomic_economy.sql. Clients never
## construct it, and the service_role key only ever exists on this object, at runtime, from env.
##
## Retry contract: every econ_* op carries a SERVER-GENERATED op id and the DB keeps an op ledger,
## so a TRANSPORT failure (timeout / connection reset — outcome unknown) is retried exactly once
## with the SAME id; if the first attempt actually committed, the retry returns the recorded result
## instead of applying twice. HTTP-level rejections (4xx/5xx with a response) are NOT retried.
##
## Result shape mirrors the SQL contract: {ok, reason?, credits?, tokens?, scrap?, payout?, sold?,
## salvaged?, item_id?, duplicate?} — plus {"ok": false, "reason": "network"} when both attempts
## failed to reach the database at all.

# POST /rest/v1/rpc/<fn> as service_role; retry once on a transport-level failure (code 0).
func _econ_rpc(fn: String, body: Dictionary) -> Dictionary:
	if service_key == "":
		return {"ok": false, "reason": "no_service_key"}
	var payload := JSON.stringify(body)
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/" + fn, payload, PackedStringArray(), service_key)
	if int(r.get("code", 0)) == 0:                       # transport failure — outcome unknown → safe retry (op ledger)
		r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/" + fn, payload, PackedStringArray(), service_key)
	var d = r.get("data")
	if int(r.get("code", 0)) >= 200 and int(r.get("code", 0)) < 300 and d is Dictionary:
		return d
	return {"ok": false, "reason": "network", "code": int(r.get("code", 0))}

# boot probe: are the atomic economy functions applied on this database?
func econ_available() -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/econ_version", "{}", PackedStringArray(), service_key)
	var v = r.get("data")
	return int(r.get("code", 0)) >= 200 and int(r.get("code", 0)) < 300 and v != null and int(v) >= 1

func econ_award(op: String, char_id: String, credits: int, tokens: int) -> Dictionary:
	return await _econ_rpc("econ_award", {"p_op": op, "p_char": char_id, "p_credits": credits, "p_tokens": tokens})

func econ_buy_item(op: String, char_id: String, credits: int, tokens: int, item: Dictionary) -> Dictionary:
	return await _econ_rpc("econ_buy_item", {"p_op": op, "p_char": char_id, "p_credits": credits, "p_tokens": tokens, "p_item": item})

func econ_sell_items(op: String, char_id: String, ids: Array, prices: Dictionary) -> Dictionary:
	return await _econ_rpc("econ_sell_items", {"p_op": op, "p_char": char_id, "p_ids": ids, "p_prices": prices})

func econ_salvage_items(op: String, char_id: String, ids: Array, yields: Dictionary) -> Dictionary:
	return await _econ_rpc("econ_salvage_items", {"p_op": op, "p_char": char_id, "p_ids": ids, "p_yields": yields})

func econ_forge_upgrade(op: String, char_id: String, item_id: String, old_level: int, new_ip: int, credits: int, scrap: int) -> Dictionary:
	return await _econ_rpc("econ_forge_upgrade", {"p_op": op, "p_char": char_id, "p_item": item_id,
		"p_old_level": old_level, "p_new_ip": new_ip, "p_credits": credits, "p_scrap": scrap})

func econ_forge_reforge(op: String, char_id: String, item_id: String, old_count: int, affixes: Array, new_ip: int, credits: int, scrap: int) -> Dictionary:
	return await _econ_rpc("econ_forge_reforge", {"p_op": op, "p_char": char_id, "p_item": item_id,
		"p_old_count": old_count, "p_affixes": affixes, "p_new_ip": new_ip, "p_credits": credits, "p_scrap": scrap})

func econ_craft(op: String, char_id: String, scrap: int, item: Dictionary) -> Dictionary:
	return await _econ_rpc("econ_craft", {"p_op": op, "p_char": char_id, "p_scrap": scrap, "p_item": item})

func econ_buy_cosmetic(op: String, char_id: String, dye: String, credits: int) -> Dictionary:
	return await _econ_rpc("econ_buy_cosmetic", {"p_op": op, "p_char": char_id, "p_dye": dye, "p_credits": credits})

func econ_unlock_locker(op: String, char_id: String, credits: int) -> Dictionary:
	return await _econ_rpc("econ_unlock_locker", {"p_op": op, "p_char": char_id, "p_credits": credits})

func econ_respec_talents(op: String, char_id: String, credits: int) -> Dictionary:
	return await _econ_rpc("econ_respec_talents", {"p_op": op, "p_char": char_id, "p_credits": credits})

# =====================================================================================================
# LEGACY SERVER METHODS (stabilization P6): moved here VERBATIM from client/Supabase.gd so the
# privileged surface (service-role reads/writes, token-scoped server reads, atomic-fn RPCs) lives in
# ONE server-only class. The client adapter keeps auth/account/own-reads only. NOTE: Godot exports
# embed ALL project scripts, so this split prevents accidental use from client code — it does NOT make
# an embedded secret safe; the service_role key stays runtime-only (env), never in code or exports.
var service_key := ""   # service_role JWT (zone server only, from env) — bypasses RLS for inventory writes

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
			"overtime_xp": int(row.get("overtime_xp", 0)), "paragon_perks": (par if par is Dictionary else {}), "paragon_spent": int(row.get("paragon_spent", 0)), "gear_bag_bonus": int(row.get("gear_bag_bonus", 0)),
			"bounty_claims": (row.get("bounty_claims", {}) if row.get("bounty_claims") is Dictionary else {}), "last_season": int(row.get("last_season", 0))}   # P6b ledger (was silently dropped from this dict) + P7d season marker
	return {"ok": r["code"] == 200, "max_intensity": 1, "pages": 0, "has_key": false, "talents": {}, "talent_spent": 0,
		"overtime_xp": 0, "paragon_perks": {}, "paragon_spent": 0, "gear_bag_bonus": 0, "bounty_claims": {}, "last_season": 0}

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
func leaderboard_submit_as(category: String, season: int, char_id: String, name: String, score: int) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/leaderboard_submit",
		JSON.stringify({"p_cat": category, "p_season": season, "p_char": char_id, "p_name": name, "p_score": score}), PackedStringArray(), service_key)

# --- RP4: append one AI-resident playtest anomaly row (service_role; clients never touch this table) ---
func bot_report_as(resident_id: String, resident_name: String, zone: String, kind: String, detail: String, metrics: Dictionary) -> void:
	if service_key == "":
		return
	await _http(HTTPClient.METHOD_POST, "/rest/v1/bot_reports",
		JSON.stringify({"resident_id": resident_id, "resident_name": resident_name, "zone": zone, "kind": kind, "detail": detail, "metrics": metrics}), PackedStringArray(), service_key)

# top-N for a category (service_role read — clients never SELECT the table directly). Returns [{name,score}].
func leaderboard_top_as(category: String, season: int, lim: int) -> Dictionary:
	if service_key == "":
		return {"entries": []}
	var q := "?category=eq.%s&season=eq.%d&select=name,score&order=score.desc&limit=%d" % [category, season, lim]
	var r = await _http(HTTPClient.METHOD_GET, "/rest/v1/leaderboards" + q, "", PackedStringArray(), service_key)
	if r["code"] == 200 and r["data"] is Array:
		return {"entries": r["data"]}
	return {"entries": []}

# gameplay-length P7d: a character's rank (1=best) in a (season, category), or 0 if unranked. Service-role only.
func leaderboard_rank_as(category: String, season: int, char_id: String) -> int:
	if service_key == "":
		return 0
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/leaderboard_rank",
		JSON.stringify({"p_cat": category, "p_season": season, "p_char": char_id}), PackedStringArray(), service_key)
	return int(r["data"]) if (r["code"] >= 200 and r["code"] < 300 and r["data"] != null) else 0

# gameplay-length P7d: advance the char's last-settled season to `season` iff strictly greater (guarded CAS). Service-role only.
func season_claim_as(char_id: String, season: int) -> bool:
	if service_key == "":
		return false
	var r = await _http(HTTPClient.METHOD_POST, "/rest/v1/rpc/season_claim",
		JSON.stringify({"p_char": char_id, "p_season": season}), PackedStringArray(), service_key)
	return r["code"] >= 200 and r["code"] < 300 and r["data"] == true

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
