extends Node
## Deterministic, in-memory stand-in for client/Supabase.gd's SERVER-facing surface, used by the
## stabilization tests (tools/stab_*.gd). No network, no live project. Return SHAPES match
## Supabase.gd exactly; mutation SEMANTICS match supabase/migrations/* (guarded single-row filters,
## gated compare-and-set functions, the inventory gear-cap trigger, underflow-guarded currency fns).
##
## Test controls:
##   yield_frames  — every call suspends this many process frames first (default 1: a real HTTP
##                   round-trip always suspends, and the server's busy-lock/dupe logic depends on it)
##   fail_once     — {method_name: n} → the next n calls of that method fail
##   fail_always   — {method_name: true} → every call fails
##   calls         — {method_name: count} observability counter

var service_key := "test-service-key"

# ---- storage (tables) ----
var characters := {}     # char_id -> row
var tokens := {}         # access token -> char_id
var inventory := {}      # item_id -> row
var materials := {}      # char_id -> scrap:int
var progression := {}    # char_id -> row
var cosmetics := {}      # char_id -> {owned:Array, equipped:String}
var quests := {}         # "<char>|<quest>" -> {progress, completed, rewarded}
var admins := {}         # user_id -> true
var boards := {}         # "cat|season|char" -> {name, score}
var bot_reports := []

# ---- injection / observability ----
var yield_frames := 1
var fail_once := {}
var fail_always := {}
var calls := {}
var _seq := 0

# every fake DB call funnels through here; returns true when THIS call must fail
func _enter(method: String) -> bool:
	calls[method] = int(calls.get(method, 0)) + 1
	for i in yield_frames:
		await get_tree().process_frame
	if bool(fail_always.get(method, false)):
		return true
	if int(fail_once.get(method, 0)) > 0:
		fail_once[method] = int(fail_once[method]) - 1
		return true
	return false

func _uuid() -> String:
	_seq += 1
	return "%08d-0000-4000-8000-%012d" % [_seq, _seq]   # well-formed for Server._is_uuid

# ---- test setup helpers ----
# creates a character + its access token; returns {char_id, token, user_id}
func add_character(cname: String, cls := "striker", opts := {}) -> Dictionary:
	var cid: String = str(opts.get("char_id", _uuid()))
	var uid: String = str(opts.get("user_id", _uuid()))
	characters[cid] = {"id": cid, "user_id": uid, "name": cname, "class": cls,
		"level": int(opts.get("level", 1)), "xp": int(opts.get("xp", 0)),
		"credits": int(opts.get("credits", 0)), "practice_tokens": int(opts.get("tokens", 0)),
		"locker_unlocked": bool(opts.get("locker_unlocked", false)),
		"created_at": str(opts.get("created_at", "2099-01-01T00:00:00Z")),   # post-epoch → ability-gated
		"last_map": str(opts.get("last_map", "home")),
		"last_x": float(opts.get("last_x", 480.0)), "last_y": float(opts.get("last_y", 270.0))}
	var tok := "tok-" + cid
	tokens[tok] = cid
	return {"char_id": cid, "token": tok, "user_id": uid}

func insert_item(char_id: String, item := {}) -> String:
	var id := _uuid()
	var row := {"id": id, "character_id": char_id, "name": "Test Item", "rarity": "common",
		"slot": "trinket", "equipped": false, "locked": false, "category": "gear", "model": null,
		"placed": false, "xform": null, "primary_stat": "PWR", "primary_amt": 3, "bonus_stat": "PWR",
		"bonus_amt": 3, "ilvl": 1, "affixes": [], "item_power": 4, "upgrade_level": 0,
		"reforge_count": 0, "set_id": "soccer", "unique_id": null, "proc_id": null, "proc_tier": 0,
		"created_at": "2099-01-01T00:00:%02dZ" % (_seq % 60)}
	for k in item:
		row[k] = item[k]
	inventory[id] = row
	return id

func items_of(char_id: String) -> Array:
	var out := []
	for id in inventory:
		if str(inventory[id]["character_id"]) == char_id:
			out.append(inventory[id])
	return out

func _char_of_token(token: String) -> String:
	return str(tokens.get(token, ""))

func _prog(char_id: String) -> Dictionary:   # ensure-row (mirrors the fns' insert..on conflict)
	if not progression.has(char_id):
		progression[char_id] = {"max_intensity": 1, "playbook_pages": 0, "has_master_key": false,
			"rested_xp": 0, "talents": {}, "talent_spent": 0, "overtime_xp": 0, "paragon_perks": {},
			"paragon_spent": 0, "gear_bag_bonus": 0, "bounty_claims": {}, "last_season": 0}
	return progression[char_id]

func _cos(char_id: String) -> Dictionary:
	if not cosmetics.has(char_id):
		cosmetics[char_id] = {"owned": [], "equipped": ""}
	return cosmetics[char_id]

func _gear_count(char_id: String) -> int:
	var n := 0
	for id in inventory:
		var r = inventory[id]
		if str(r["character_id"]) == char_id and str(r.get("category", "gear")) != "build":
			n += 1
	return n

# ---- characters ----
func get_character_as(token: String) -> Dictionary:
	if await _enter("get_character_as"):
		return {"ok": false, "character": null, "code": 0, "error": "network error (injected)"}
	var cid := _char_of_token(token)
	if cid == "" or not characters.has(cid):
		return {"ok": true, "character": null, "code": 200}   # valid HTTP, zero rows (bad/foreign token)
	return {"ok": true, "character": (characters[cid] as Dictionary).duplicate(true), "code": 200}

var last_save_fields := {}                                     # the most recent save PATCH body (assertable)

func save_character_as(_token: String, char_id: String, fields: Dictionary) -> Dictionary:
	if await _enter("save_character_as"):
		return {"ok": false, "code": 500}
	last_save_fields = fields.duplicate(true)
	if not characters.has(char_id):
		return {"ok": true, "code": 204}                       # PATCH matching zero rows still 2xx
	for k in fields:                                           # service-role write: nothing pinned
		characters[char_id][k] = fields[k]
	return {"ok": true, "code": 204}

func locker_unlock_as(char_id: String) -> bool:
	if await _enter("locker_unlock_as") or service_key == "":
		return false
	var ch = characters.get(char_id)
	if ch == null or bool(ch.get("locker_unlocked", false)):
		return false                                           # gated filter matched no row
	ch["locker_unlocked"] = true
	return true

# ---- inventory ----
func get_inventory_as(token: String) -> Dictionary:
	if await _enter("get_inventory_as"):
		return {"ok": false, "items": []}
	var cid := _char_of_token(token)
	var out := []
	for r in items_of(cid):
		out.append((r as Dictionary).duplicate(true))
	return {"ok": true, "items": out}

func add_item_as(_token: String, char_id: String, item: Dictionary) -> Dictionary:
	if await _enter("add_item_as"):
		return {"ok": false, "code": 500}
	var cap := 50 + int(_prog(char_id).get("gear_bag_bonus", 0))   # the inventory_gear_cap trigger
	if str(item.get("category", "gear")) != "build" and _gear_count(char_id) >= cap:
		return {"ok": false, "code": 400}                          # trigger RAISEs → PostgREST 4xx
	insert_item(char_id, item)
	return {"ok": true, "code": 201}

# PostgREST filter mini-parser for the eq./neq. filters equip() builds
func _filter_match(row: Dictionary, filter: String) -> bool:
	for part in filter.split("&"):
		var kv := str(part).split("=", true, 1)
		if kv.size() != 2:
			return false
		var col := str(kv[0])
		var opv := str(kv[1])
		if opv.begins_with("eq."):
			if str(row.get(col)) != opv.substr(3):
				return false
		elif opv.begins_with("neq."):
			if str(row.get(col)) == opv.substr(4):
				return false
		else:
			return false
	return true

func inv_set_equipped_as(_token: String, filter: String, val: bool) -> Dictionary:
	if await _enter("inv_set_equipped_as"):
		return {"ok": false, "code": 500}
	for id in inventory:
		if _filter_match(inventory[id], filter):
			inventory[id]["equipped"] = val
	return {"ok": true, "code": 204}                           # real call doesn't require a match

func inv_set_locked_as(_token: String, char_id: String, item_id: String, val: bool) -> Dictionary:
	if await _enter("inv_set_locked_as"):
		return {"ok": false, "code": 500}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id:
		return {"ok": false, "code": 200}                      # return=representation: no row matched
	r["locked"] = val
	return {"ok": true, "code": 200}

func sell_item_safe_as(char_id: String, item_id: String) -> Dictionary:
	if await _enter("sell_item_safe_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or bool(r["equipped"]) or bool(r["locked"]):
		return {"ok": false}                                   # guard IN the filter: no row deleted
	inventory.erase(item_id)
	return {"ok": true, "rarity": str(r.get("rarity", "common"))}

func sell_item_as(char_id: String, item_id: String) -> Dictionary:   # legacy unguarded variant
	if await _enter("sell_item_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id:
		return {"ok": false}
	inventory.erase(item_id)
	return {"ok": true, "rarity": str(r.get("rarity", "common"))}

func clear_inventory_as(char_id: String) -> void:
	if await _enter("clear_inventory_as") or service_key == "":
		return
	for id in inventory.keys():
		if str(inventory[id]["character_id"]) == char_id:
			inventory.erase(id)

func inv_upgrade_as(char_id: String, item_id: String, old_level: int, new_level: int, new_ip: int) -> Dictionary:
	if await _enter("inv_upgrade_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or int(r.get("upgrade_level", 0)) != old_level:
		return {"ok": false, "code": 200}                      # gated PATCH matched no row
	r["upgrade_level"] = new_level
	r["item_power"] = new_ip
	return {"ok": true, "code": 200}

func inv_reforge_as(char_id: String, item_id: String, old_count: int, new_count: int, new_affixes: Array, new_ip: int) -> Dictionary:
	if await _enter("inv_reforge_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or int(r.get("reforge_count", 0)) != old_count:
		return {"ok": false, "code": 200}
	r["affixes"] = new_affixes
	r["reforge_count"] = new_count
	r["item_power"] = new_ip
	return {"ok": true, "code": 200}

# ---- build items ----
func get_placed_build_items_as(_token: String, char_id: String):
	if await _enter("get_placed_build_items_as"):
		return null
	var out := []
	for r in items_of(char_id):
		if str(r.get("category", "")) == "build" and bool(r.get("placed", false)):
			out.append({"id": r["id"], "model": r["model"], "xform": r["xform"]})
	return out

func build_owned_models_as(char_id: String):
	if await _enter("build_owned_models_as") or service_key == "":
		return null
	var out := []
	for r in items_of(char_id):
		if str(r.get("category", "")) == "build":
			out.append(str(r.get("model", "")))
	return out

func add_build_item_as(char_id: String, model: String) -> Dictionary:
	if await _enter("add_build_item_as") or service_key == "":
		return {"ok": false}
	var id := insert_item(char_id, {"category": "build", "model": model, "name": model,
		"rarity": "common", "slot": "build", "placed": false})
	return {"ok": true, "id": id, "code": 201}

func build_place_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
	if await _enter("build_place_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or str(r.get("category", "")) != "build" or bool(r.get("placed", false)):
		return {"ok": false}
	r["placed"] = true
	r["xform"] = xform
	return {"ok": true}

func build_move_as(char_id: String, item_id: String, xform: Dictionary) -> Dictionary:
	if await _enter("build_move_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or str(r.get("category", "")) != "build" or not bool(r.get("placed", false)):
		return {"ok": false}
	r["xform"] = xform
	return {"ok": true}

func build_remove_as(char_id: String, item_id: String) -> Dictionary:
	if await _enter("build_remove_as") or service_key == "":
		return {"ok": false}
	var r = inventory.get(item_id)
	if r == null or str(r["character_id"]) != char_id or str(r.get("category", "")) != "build" or not bool(r.get("placed", false)):
		return {"ok": false}
	r["placed"] = false
	r["xform"] = null
	return {"ok": true}

# ---- admin / reports ----
func is_admin_as(user_id: String) -> bool:
	if await _enter("is_admin_as") or service_key == "" or user_id == "":
		return false
	return admins.has(user_id)

func bot_report_as(resident_id: String, resident_name: String, zone: String, kind: String, detail: String, metrics: Dictionary) -> void:
	if await _enter("bot_report_as") or service_key == "":
		return
	bot_reports.append({"resident_id": resident_id, "resident_name": resident_name, "zone": zone,
		"kind": kind, "detail": detail, "metrics": metrics})

# ---- materials ----
func mats_add_as(char_id: String, delta: int) -> Dictionary:
	if await _enter("mats_add_as") or service_key == "":
		return {"ok": false, "total": 0}
	var cur := int(materials.get(char_id, 0))
	if cur + delta < 0:
		return {"ok": false, "total": 0, "code": 200}          # underflow-guarded (fn returns NULL)
	materials[char_id] = cur + delta
	return {"ok": true, "total": cur + delta, "code": 200}

func get_mats_as(token: String) -> Dictionary:
	if await _enter("get_mats_as"):
		return {"ok": false, "scrap": 0}
	return {"ok": true, "scrap": int(materials.get(_char_of_token(token), 0))}

# ---- progression ----
func get_progression_as(token: String) -> Dictionary:
	if await _enter("get_progression_as"):
		return {"ok": false, "max_intensity": 1, "pages": 0, "has_key": false, "talents": {},
			"talent_spent": 0, "overtime_xp": 0, "paragon_perks": {}, "paragon_spent": 0,
			"gear_bag_bonus": 0, "bounty_claims": {}, "last_season": 0}
	var cid := _char_of_token(token)
	var p := _prog(cid) if cid != "" else {}
	return {"ok": true, "max_intensity": int(p.get("max_intensity", 1)),
		"pages": int(p.get("playbook_pages", 0)), "has_key": bool(p.get("has_master_key", false)),
		"talents": (p.get("talents", {}) as Dictionary).duplicate(true),
		"talent_spent": int(p.get("talent_spent", 0)), "overtime_xp": int(p.get("overtime_xp", 0)),
		"paragon_perks": (p.get("paragon_perks", {}) as Dictionary).duplicate(true),
		"paragon_spent": int(p.get("paragon_spent", 0)), "gear_bag_bonus": int(p.get("gear_bag_bonus", 0)),
		"bounty_claims": (p.get("bounty_claims", {}) as Dictionary).duplicate(true),
		"last_season": int(p.get("last_season", 0))}

func progression_unlock_as(char_id: String, tier: int) -> int:
	if await _enter("progression_unlock_as") or service_key == "":
		return 0
	var p := _prog(char_id)
	if int(p["max_intensity"]) == tier and tier < 30:
		p["max_intensity"] = tier + 1
	return int(p["max_intensity"])

func progression_add_pages_as(char_id: String, delta: int) -> Dictionary:
	if await _enter("progression_add_pages_as") or service_key == "":
		return {"ok": false, "total": 0}
	var p := _prog(char_id)
	if int(p["playbook_pages"]) + delta < 0:
		return {"ok": false, "total": 0}
	p["playbook_pages"] = int(p["playbook_pages"]) + delta
	return {"ok": true, "total": int(p["playbook_pages"])}

func progression_craft_key_as(char_id: String, cost: int) -> bool:
	if await _enter("progression_craft_key_as") or service_key == "":
		return false
	var p := _prog(char_id)
	if int(p["playbook_pages"]) < cost or bool(p["has_master_key"]):
		return false
	p["playbook_pages"] = int(p["playbook_pages"]) - cost
	p["has_master_key"] = true
	return true

func progression_rest_login_as(char_id: String, _rate: float, _cap: int) -> int:
	if await _enter("progression_rest_login_as") or service_key == "":
		return 0
	var p := _prog(char_id)                                     # lease the pool to this session, zero the bank
	var pool := int(p["rested_xp"])
	p["rested_xp"] = 0
	return pool

func progression_rest_logout_as(char_id: String, rested: int) -> void:
	if await _enter("progression_rest_logout_as") or service_key == "":
		return
	var p := _prog(char_id)
	p["rested_xp"] = maxi(0, int(p["rested_xp"]) + maxi(0, rested))

func progression_set_overtime_as(char_id: String, overtime: int, bag_bonus: int) -> int:
	if await _enter("progression_set_overtime_as") or service_key == "":
		return 0
	var p := _prog(char_id)                                     # monotonic greatest()
	p["overtime_xp"] = maxi(int(p["overtime_xp"]), maxi(overtime, 0))
	p["gear_bag_bonus"] = maxi(int(p["gear_bag_bonus"]), maxi(bag_bonus, 0))
	return int(p["overtime_xp"])

func talents_spend_as(char_id: String, node: String, ranks: int, budget: int, node_max: int) -> Dictionary:
	if await _enter("talents_spend_as") or service_key == "":
		return {"ok": false, "talents": {}}
	var p := _prog(char_id)
	var cur := int((p["talents"] as Dictionary).get(node, 0))
	if ranks <= 0 or int(p["talent_spent"]) + ranks > budget or cur + ranks > node_max:
		return {"ok": false, "talents": {}}
	(p["talents"] as Dictionary)[node] = cur + ranks
	p["talent_spent"] = int(p["talent_spent"]) + ranks
	return {"ok": true, "talents": (p["talents"] as Dictionary).duplicate(true)}

func talents_respec_as(char_id: String) -> bool:
	if await _enter("talents_respec_as") or service_key == "":
		return false
	var p := _prog(char_id)
	p["talents"] = {}
	p["talent_spent"] = 0
	return true

func paragon_set_as(char_id: String, perks: Dictionary, spent: int, budget: int) -> Dictionary:
	if await _enter("paragon_set_as") or service_key == "":
		return {"ok": false, "perks": {}}
	if spent < 0 or spent > budget:
		return {"ok": false, "perks": {}}
	var p := _prog(char_id)
	p["paragon_perks"] = perks.duplicate(true)
	p["paragon_spent"] = spent
	return {"ok": true, "perks": perks.duplicate(true)}

# ---- cosmetics ----
func get_cosmetics_as(token: String) -> Dictionary:
	if await _enter("get_cosmetics_as"):
		return {"ok": false, "owned": [], "equipped": ""}
	var c := _cos(_char_of_token(token))
	return {"ok": true, "owned": (c["owned"] as Array).duplicate(), "equipped": str(c["equipped"])}

func cosmetics_grant_as(char_id: String, dye: String) -> bool:
	if await _enter("cosmetics_grant_as") or service_key == "":
		return false
	var c := _cos(char_id)
	if dye in (c["owned"] as Array):
		return false                                            # add-if-not-owned: dupe grants refuse
	(c["owned"] as Array).append(dye)
	return true

func cosmetics_equip_as(char_id: String, dye: String) -> bool:
	if await _enter("cosmetics_equip_as") or service_key == "":
		return false
	var c := _cos(char_id)
	if dye != "" and not (dye in (c["owned"] as Array)):
		return false
	c["equipped"] = dye
	return true

# ---- quests ----
func get_quests_as(token: String) -> Dictionary:
	if await _enter("get_quests_as"):
		return {"ok": false, "items": []}
	var cid := _char_of_token(token)
	var out := []
	for k in quests:
		if str(k).begins_with(cid + "|"):
			var st = quests[k]
			out.append({"quest_id": str(k).split("|")[1], "progress": int(st["progress"]),
				"completed": bool(st["completed"]), "rewarded": bool(st["rewarded"])})
	return {"ok": true, "items": out}

func quest_save_as(char_id: String, quest_id: String, progress: int, completed: bool, rewarded: bool) -> Dictionary:
	if await _enter("quest_save_as") or service_key == "":
		return {"ok": false}
	quests[char_id + "|" + quest_id] = {"progress": progress, "completed": completed, "rewarded": rewarded}
	return {"ok": true, "code": 201}

func quest_complete_as(char_id: String, quest_id: String, progress: int) -> Dictionary:
	if await _enter("quest_complete_as") or service_key == "":
		return {"ok": false}
	var st = quests.get(char_id + "|" + quest_id)
	if st == null:
		return {"ok": false, "code": 200}                       # return=representation: no row
	st["completed"] = true
	st["progress"] = progress
	return {"ok": true, "code": 200}

func quest_mark_rewarded_as(char_id: String, quest_id: String) -> Dictionary:
	if await _enter("quest_mark_rewarded_as") or service_key == "":
		return {"ok": false}
	var st = quests.get(char_id + "|" + quest_id)
	if st == null or not bool(st["completed"]) or bool(st["rewarded"]):
		return {"ok": false, "code": 200}                       # gated flip: exactly one winner
	st["rewarded"] = true
	return {"ok": true, "code": 200}

func quest_progress_as(char_id: String, quest_id: String, progress: int) -> Dictionary:
	if await _enter("quest_progress_as") or service_key == "":
		return {"ok": false}
	var st = quests.get(char_id + "|" + quest_id)
	if st != null:
		st["progress"] = progress
	return {"ok": true, "code": 204}                            # return=minimal: 2xx either way

# ---- bounties / seasons / leaderboards ----
func bounty_claim_as(char_id: String, bounty_id: String, period: int) -> bool:
	if await _enter("bounty_claim_as") or service_key == "":
		return false
	var p := _prog(char_id)
	var led: Dictionary = p["bounty_claims"]
	if int(led.get(bounty_id, -1)) >= period:
		return false                                            # CAS: stored < p_period only
	led[bounty_id] = period
	return true

func season_claim_as(char_id: String, season: int) -> bool:
	if await _enter("season_claim_as") or service_key == "":
		return false
	var p := _prog(char_id)
	if int(p["last_season"]) >= season:
		return false
	p["last_season"] = season
	return true

func leaderboard_submit_as(category: String, season: int, char_id: String, cname: String, score: int) -> void:
	if await _enter("leaderboard_submit_as") or service_key == "":
		return
	var k := "%s|%d|%s" % [category, season, char_id]
	var cur = boards.get(k)
	boards[k] = {"name": cname, "score": maxi(score, int(cur["score"]) if cur != null else 0)}

func leaderboard_top_as(category: String, season: int, lim: int) -> Dictionary:
	if await _enter("leaderboard_top_as") or service_key == "":
		return {"entries": []}
	var rows := []
	for k in boards:
		var parts := str(k).split("|")
		if parts[0] == category and int(parts[1]) == season:
			rows.append({"name": boards[k]["name"], "score": int(boards[k]["score"])})
	rows.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	return {"entries": rows.slice(0, lim)}

func leaderboard_rank_as(category: String, season: int, char_id: String) -> int:
	if await _enter("leaderboard_rank_as") or service_key == "":
		return 0
	var mine = boards.get("%s|%d|%s" % [category, season, char_id])
	if mine == null:
		return 0
	var rank := 1
	for k in boards:
		var parts := str(k).split("|")
		if parts[0] == category and int(parts[1]) == season and int(boards[k]["score"]) > int(mine["score"]):
			rank += 1
	return rank

# ---- stabilization P3: atomic economy (mirrors 20260714000000_stab_atomic_economy.sql) ----
# Each fn is one "transaction": after the _enter yield, the mutation block runs synchronously
# (single-threaded), guarded exactly like the SQL, and the op ledger dedupes replays. An injected
# failure is a TRANSPORT failure: nothing mutates, nothing is recorded (retry with the same op is safe).
var econ_ops := {}        # op_id -> recorded result (the idempotency ledger)

func econ_available() -> bool:
	if await _enter("econ_available"):
		return false
	return service_key != ""

func _econ_seen(op: String):
	return econ_ops.get(op)

func _econ_record(op: String, result: Dictionary) -> Dictionary:
	econ_ops[op] = result.duplicate(true)
	return result

func _econ_dup(prev) -> Dictionary:
	var d: Dictionary = (prev as Dictionary).duplicate(true)
	d["duplicate"] = true
	return d

func econ_award(op: String, char_id: String, credits: int, tokens: int) -> Dictionary:
	if await _enter("econ_award"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	ch["credits"] = maxi(0, int(ch["credits"]) + credits)      # credits deltas may be negative (floor 0)
	ch["practice_tokens"] = maxi(0, int(ch["practice_tokens"]) + maxi(tokens, 0))
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"]), "tokens": int(ch["practice_tokens"])})

func econ_buy_item(op: String, char_id: String, credits: int, tokens: int, item: Dictionary) -> Dictionary:
	if await _enter("econ_buy_item"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	if credits < 0 or tokens < 0:
		return _econ_record(op, {"ok": false, "reason": "bad_price"})
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"]), "tokens": int(ch["practice_tokens"])})
	if int(ch["practice_tokens"]) < tokens:
		return _econ_record(op, {"ok": false, "reason": "insufficient_tokens", "credits": int(ch["credits"]), "tokens": int(ch["practice_tokens"])})
	var cap := 50 + int(_prog(char_id).get("gear_bag_bonus", 0))
	if str(item.get("category", "gear")) != "build" and _gear_count(char_id) >= cap:
		return _econ_record(op, {"ok": false, "reason": "inventory_full", "credits": int(ch["credits"]), "tokens": int(ch["practice_tokens"])})
	var iid := insert_item(char_id, item)
	ch["credits"] = int(ch["credits"]) - credits
	ch["practice_tokens"] = int(ch["practice_tokens"]) - tokens
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"]), "tokens": int(ch["practice_tokens"]), "item_id": iid})

func econ_sell_items(op: String, char_id: String, ids: Array, prices: Dictionary) -> Dictionary:
	if await _enter("econ_sell_items"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	var payout := 0
	var sold := []
	for raw in ids:
		var id := str(raw)
		var r = inventory.get(id)
		if r == null or str(r["character_id"]) != char_id or bool(r["equipped"]) or bool(r["locked"]) \
				or str(r.get("category", "gear")) == "build":
			continue
		inventory.erase(id)
		payout += int(prices.get(str(r.get("rarity", "common")), 10))
		sold.append(id)
	if payout > 0:
		ch["credits"] = int(ch["credits"]) + payout
	return _econ_record(op, {"ok": true, "payout": payout, "credits": int(ch["credits"]), "sold": sold})

func econ_salvage_items(op: String, char_id: String, ids: Array, yields: Dictionary) -> Dictionary:
	if await _enter("econ_salvage_items"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	if not characters.has(char_id):
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	var total := 0
	var salvaged := []
	for raw in ids:
		var id := str(raw)
		var r = inventory.get(id)
		if r == null or str(r["character_id"]) != char_id or bool(r["equipped"]) or bool(r["locked"]) \
				or str(r.get("category", "gear")) == "build":
			continue
		inventory.erase(id)
		total += maxi(1, int(yields.get(str(r.get("rarity", "common")), 1)))
		salvaged.append(id)
	if total > 0:
		materials[char_id] = int(materials.get(char_id, 0)) + total
	return _econ_record(op, {"ok": true, "scrap": int(materials.get(char_id, 0)), "salvaged": salvaged})

func econ_forge_upgrade(op: String, char_id: String, item_id: String, old_level: int, new_ip: int, credits: int, scrap: int) -> Dictionary:
	if await _enter("econ_forge_upgrade"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	var cur_scrap := int(materials.get(char_id, 0))
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"]), "scrap": cur_scrap})
	if cur_scrap < scrap:
		return _econ_record(op, {"ok": false, "reason": "insufficient_scrap", "credits": int(ch["credits"]), "scrap": cur_scrap})
	var it = inventory.get(item_id)
	if it == null or str(it["character_id"]) != char_id or int(it.get("upgrade_level", 0)) != old_level \
			or str(it.get("category", "gear")) == "build":
		return _econ_record(op, {"ok": false, "reason": "stale_item", "credits": int(ch["credits"]), "scrap": cur_scrap})
	it["upgrade_level"] = old_level + 1
	it["item_power"] = new_ip
	ch["credits"] = int(ch["credits"]) - credits
	materials[char_id] = cur_scrap - scrap
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"]), "scrap": int(materials[char_id])})

func econ_forge_reforge(op: String, char_id: String, item_id: String, old_count: int, affixes: Array, new_ip: int, credits: int, scrap: int) -> Dictionary:
	if await _enter("econ_forge_reforge"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	var cur_scrap := int(materials.get(char_id, 0))
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"]), "scrap": cur_scrap})
	if cur_scrap < scrap:
		return _econ_record(op, {"ok": false, "reason": "insufficient_scrap", "credits": int(ch["credits"]), "scrap": cur_scrap})
	var it = inventory.get(item_id)
	if it == null or str(it["character_id"]) != char_id or int(it.get("reforge_count", 0)) != old_count \
			or str(it.get("category", "gear")) == "build":
		return _econ_record(op, {"ok": false, "reason": "stale_item", "credits": int(ch["credits"]), "scrap": cur_scrap})
	it["affixes"] = affixes
	it["reforge_count"] = old_count + 1
	it["item_power"] = new_ip
	ch["credits"] = int(ch["credits"]) - credits
	materials[char_id] = cur_scrap - scrap
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"]), "scrap": int(materials[char_id])})

func econ_craft(op: String, char_id: String, scrap: int, item: Dictionary) -> Dictionary:
	if await _enter("econ_craft"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	if not characters.has(char_id):
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	var cur_scrap := int(materials.get(char_id, 0))
	if cur_scrap < scrap:
		return _econ_record(op, {"ok": false, "reason": "insufficient_scrap", "scrap": cur_scrap})
	var cap := 50 + int(_prog(char_id).get("gear_bag_bonus", 0))
	if _gear_count(char_id) >= cap:
		return _econ_record(op, {"ok": false, "reason": "inventory_full", "scrap": cur_scrap})
	var iid := insert_item(char_id, item)
	materials[char_id] = cur_scrap - scrap
	return _econ_record(op, {"ok": true, "scrap": int(materials[char_id]), "item_id": iid})

func econ_buy_cosmetic(op: String, char_id: String, dye: String, credits: int) -> Dictionary:
	if await _enter("econ_buy_cosmetic"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"])})
	var c := _cos(char_id)
	if dye in (c["owned"] as Array):
		return _econ_record(op, {"ok": false, "reason": "owned", "credits": int(ch["credits"])})
	(c["owned"] as Array).append(dye)
	ch["credits"] = int(ch["credits"]) - credits
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"])})

func econ_unlock_locker(op: String, char_id: String, credits: int) -> Dictionary:
	if await _enter("econ_unlock_locker"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	if bool(ch.get("locker_unlocked", false)):
		return _econ_record(op, {"ok": false, "reason": "owned", "credits": int(ch["credits"])})
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"])})
	ch["credits"] = int(ch["credits"]) - credits
	ch["locker_unlocked"] = true
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"])})

func econ_respec_talents(op: String, char_id: String, credits: int) -> Dictionary:
	if await _enter("econ_respec_talents"):
		return {"ok": false, "reason": "network"}
	var prev = _econ_seen(op)
	if prev != null:
		return _econ_dup(prev)
	var ch = characters.get(char_id)
	if ch == null:
		return {"ok": false, "reason": "no_character"}   # never recorded (mirrors the FK rule)
	if int(ch["credits"]) < credits:
		return _econ_record(op, {"ok": false, "reason": "insufficient_credits", "credits": int(ch["credits"])})
	var p := _prog(char_id)
	if int(p["talent_spent"]) <= 0:
		return _econ_record(op, {"ok": false, "reason": "nothing", "credits": int(ch["credits"])})
	p["talents"] = {}
	p["talent_spent"] = 0
	ch["credits"] = int(ch["credits"]) - credits
	return _econ_record(op, {"ok": true, "credits": int(ch["credits"])})

# ---- misc plumbing Server.gd touches ----
func refresh_as(_rtoken: String) -> Dictionary:
	if await _enter("refresh_as"):
		return {"ok": false}
	return {"ok": false}

func _http(_method: int, _path: String, _body := "", _extra := PackedStringArray(), _token := "") -> Dictionary:
	calls["_http"] = int(calls.get("_http", 0)) + 1
	return {"code": 200, "data": [], "error": ""}
