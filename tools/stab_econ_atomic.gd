extends "res://tools/stab/stab_base.gd"
## Stabilization P3 — ATOMIC + IDEMPOTENT ECONOMY (the DB-function path, `_atomic_econ = true`):
##   • purchases debit + mint in one op; a same-frame duplicate request charges once;
##   • a REPLAYED op id returns the ORIGINAL result and never applies twice (the op ledger);
##   • kill/quest awards flush as idempotent deltas; the save PATCH no longer carries currencies;
##   • a transport-failed award flush retries with the SAME op id and lands exactly once;
##   • sell removes rows + credits the payout in one op; equipped items survive;
##   • forge upgrade with a stale item version spends NOTHING (no refund path to get wrong);
##   • locker/cosmetic/respec: owned/nothing states charge nothing; success charges once;
##   • in PRODUCTION with the DB functions missing, economy ops FAIL CLOSED (legacy path refused).
## Run: godot --headless --path . --script res://tools/stab_econ_atomic.gd

const SP := preload("res://server/Server.gd")

func _init() -> void:
	_run()

func _sync(pid: int, cid: String, credits: int) -> void:
	srv._session[pid]["credits"] = credits
	supa.characters[cid]["credits"] = credits

func _run() -> void:
	await boot()
	srv._atomic_econ = true                                # the probe result under test
	var a: Dictionary = await login("Alice", 1)
	var cid: String = a["char_id"]
	var buy := int(SP.BUY_PRICE["common"])
	var sellp := int(SP.SELL_PRICE["common"])

	# ---- 1. duplicate purchase request charges once; the DB row is debited immediately ----
	_sync(1, cid, buy * 2)
	supa.yield_frames = 3
	srv.shop_buy(1, "head", "common")
	srv.shop_buy(1, "head", "common")
	await settle(24)
	supa.yield_frames = 1
	ok(int(supa.characters[cid]["credits"]) == buy, "atomic buy: DB debited exactly once")
	ok(supa.items_of(cid).size() == 1, "atomic buy: one item minted")
	ok(int(srv._session[1]["credits"]) == buy, "atomic buy: session mirror matches the DB")

	# ---- 2. fn-level idempotency: a replayed op id returns the original result, applies once ----
	var op: String = srv._op_id()
	var before: int = int(supa.characters[cid]["credits"])
	var items0: int = supa.items_of(cid).size()
	var r1 = await supa.econ_buy_item(op, cid, 10, 0, {"name": "X", "rarity": "common", "slot": "feet", "bonus_amt": 1, "bonus_stat": "PWR"})
	var r2 = await supa.econ_buy_item(op, cid, 10, 0, {"name": "X", "rarity": "common", "slot": "feet", "bonus_amt": 1, "bonus_stat": "PWR"})
	ok(bool(r1.get("ok")) and bool(r2.get("ok")) and bool(r2.get("duplicate", false)),
		"op ledger: the replay is flagged duplicate with the original result")
	ok(int(supa.characters[cid]["credits"]) == before - 10, "op ledger: debited once across the replay")
	ok(supa.items_of(cid).size() == items0 + 1, "op ledger: minted once across the replay")

	# ---- 3. awards flush as deltas; the save PATCH stops carrying currencies ----
	var row_before: int = int(supa.characters[cid]["credits"])
	srv._session[1]["credits"] = row_before                # resync the mirror (section 2 bypassed the server)
	srv._award_credits(1, 100)
	ok(int(srv._session[1]["credits"]) == row_before + 100, "award: mirror is immediate")
	srv._save_one(srv._session[1], srv._find(a["fid"]))
	await settle(12)
	ok(int(supa.characters[cid]["credits"]) == row_before + 100, "award: flushed to the DB on save")
	ok(not supa.last_save_fields.has("credits") and not supa.last_save_fields.has("practice_tokens"),
		"atomic mode: the absolute save PATCH no longer carries currencies")

	# ---- 4. a transport-failed flush retries the SAME op and lands exactly once ----
	var row2: int = int(supa.characters[cid]["credits"])
	srv._award_credits(1, 50)
	supa.fail_once["econ_award"] = 1
	srv._save_one(srv._session[1], srv._find(a["fid"]))
	await settle(12)
	ok(int(supa.characters[cid]["credits"]) == row2, "flush retry: failed transport applied nothing")
	ok(not (srv._session[1].get("award_packet", {}) as Dictionary).is_empty(),
		"flush retry: the packet is kept for the retry")
	var pkt_op: String = str((srv._session[1]["award_packet"] as Dictionary)["op"])
	srv._save_one(srv._session[1], srv._find(a["fid"]))
	await settle(12)
	ok(int(supa.characters[cid]["credits"]) == row2 + 50, "flush retry: the retry landed the delta once")
	ok(supa.econ_ops.has(pkt_op), "flush retry: the SAME op id was used (ledger has it)")
	ok(int(srv._session[1]["credits"]) == int(supa.characters[cid]["credits"]), "flush retry: mirror reconciled")

	# ---- 5. atomic sell: rows out + payout in, one op; equipped survives ----
	await wait_ms(400)
	var s1: String = supa.insert_item(cid, {"slot": "feet"})
	var s2: String = supa.insert_item(cid, {"slot": "neck"})
	var se: String = supa.insert_item(cid, {"slot": "chest", "equipped": true})
	var row3: int = int(supa.characters[cid]["credits"])
	await srv.shop_sell_many(1, [s1, s1, s2, se])
	await settle()
	ok(int(supa.characters[cid]["credits"]) == row3 + sellp * 2, "atomic sell: paid per removed row, once")
	ok(not supa.inventory.has(s1) and not supa.inventory.has(s2) and supa.inventory.has(se),
		"atomic sell: sold rows removed, equipped survives")

	# ---- 6. forge upgrade: stale item version spends nothing ----
	await wait_ms(400)
	var up: String = supa.insert_item(cid, {"slot": "main_hand", "rarity": "common"})
	supa.inventory[up]["upgrade_level"] = 3                # the server will read 3, then we race it to 4
	_sync(1, cid, 1000)
	supa.materials[cid] = 50
	srv._session[1]["scrap"] = 50
	# legitimate upgrade first: 3 → 4
	await srv.forge_upgrade(1, up)
	await settle()
	ok(int(supa.inventory[up]["upgrade_level"]) == 4, "atomic forge: upgrade applied")
	var c_after: int = int(supa.characters[cid]["credits"])
	var m_after: int = int(supa.materials[cid])
	# stale replay straight at the fn (as if a second session raced): old_level=3 no longer matches
	var r3 = await supa.econ_forge_upgrade(srv._op_id(), cid, up, 3, 999, 100, 4)
	ok(str(r3.get("reason", "")) == "stale_item", "atomic forge: stale version refused")
	ok(int(supa.characters[cid]["credits"]) == c_after and int(supa.materials[cid]) == m_after,
		"atomic forge: stale attempt spent nothing")

	# ---- 7. locker + cosmetic + respec dupe/owned behavior ----
	await wait_ms(400)
	_sync(1, cid, SP.LOCKER_UNLOCK_COST * 2)
	supa.yield_frames = 3
	srv.buy_locker_room(1)
	srv.buy_locker_room(1)
	await settle(24)
	supa.yield_frames = 1
	ok(int(supa.characters[cid]["credits"]) == SP.LOCKER_UNLOCK_COST and bool(supa.characters[cid]["locker_unlocked"]),
		"atomic locker: double-send charged once, flag set")
	await wait_ms(400)
	await srv.buy_locker_room(1)
	await settle()
	ok(int(supa.characters[cid]["credits"]) == SP.LOCKER_UNLOCK_COST, "atomic locker: owned re-buy is free")
	var dye_price := int(GameData.DYE_CATALOG["crimson"]["price"])
	_sync(1, cid, dye_price * 3)
	await wait_ms(400)
	await srv.buy_cosmetic(1, "crimson")
	await wait_ms(400)
	await srv.buy_cosmetic(1, "crimson")
	await settle()
	ok(int(supa.characters[cid]["credits"]) == dye_price * 2, "atomic cosmetic: owned dye never re-charged")
	ok("crimson" in (supa._cos(cid)["owned"] as Array), "atomic cosmetic: dye granted in the DB")
	# respec: allocated talents reset + charged once; a second respec has nothing to reset → free
	supa._prog(cid)["talents"] = {"st_a": 1}
	supa._prog(cid)["talent_spent"] = 1
	srv._session[1]["talents"] = {"st_a": 1}
	srv._session[1]["talent_spent"] = 1
	_sync(1, cid, GameData.TALENT_RESPEC_CREDITS * 2)
	await wait_ms(500)
	await srv.respec_talents(1)
	await settle()
	ok(int(supa.characters[cid]["credits"]) == GameData.TALENT_RESPEC_CREDITS
		and int(supa._prog(cid)["talent_spent"]) == 0, "atomic respec: reset + charged once")
	await wait_ms(500)
	await srv.respec_talents(1)
	await settle()
	ok(int(supa.characters[cid]["credits"]) == GameData.TALENT_RESPEC_CREDITS,
		"atomic respec: nothing allocated → no charge")

	# ---- 8. craft: spend + mint in one op ----
	await wait_ms(400)
	supa.materials[cid] = 12
	srv._session[1]["scrap"] = 12
	var n0: int = supa.items_of(cid).size()
	await srv.craft(1, "forge_unc")
	await settle()
	ok(int(supa.materials[cid]) == 0 and supa.items_of(cid).size() == n0 + 1,
		"atomic craft: one spend, one item")

	# ---- 9. production without the DB functions FAILS CLOSED ----
	srv._atomic_econ = false
	OS.set_environment("LEGENDS_ENV", "production")
	_sync(1, cid, buy * 2)
	var n1: int = supa.items_of(cid).size()
	await wait_ms(400)
	await srv.shop_buy(1, "head", "common")
	await settle()
	ok(int(supa.characters[cid]["credits"]) == buy * 2 and supa.items_of(cid).size() == n1,
		"production fail-closed: legacy economy path refused (no debit, no item)")
	OS.set_environment("LEGENDS_ENV", "")
	srv._atomic_econ = true

	# ---- 10.–13. adversarial-review regressions (fresh character — Alice sits at the gear cap) ----
	var fr: Dictionary = await login("Fresh", 9)
	var fcid: String = fr["char_id"]

	# 10. a NEGATIVE admin adjustment persists in atomic mode (HEAD parity)
	_sync(9, fcid, 200)
	srv._award_credits(9, -30)                             # admin_cmd add_credits with a negative amt
	srv._save_one(srv._session[9], srv._find(fr["fid"]))
	await settle(12)
	ok(int(supa.characters[fcid]["credits"]) == 170, "negative admin adjustment lands in the DB")
	ok(int(srv._session[9]["credits"]) == 170, "negative adjustment: mirror reconciled")

	# 11. econ GATE: an award flush and a purchase in flight together never drift the mirror
	await wait_ms(400)
	_sync(9, fcid, 100)
	srv._award_credits(9, 10)                              # pending award (mirror shows 110)
	supa.yield_frames = 4
	srv._save_one(srv._session[9], srv._find(fr["fid"]))   # flush starts (holds the gate)…
	srv.shop_buy(9, "head", "common")                      # …the buy queues behind it
	await settle(48)
	supa.yield_frames = 1
	ok(int(supa.characters[fcid]["credits"]) == 100 + 10 - buy,
		"gate: award and debit both landed exactly once")
	ok(int(srv._session[9]["credits"]) == int(supa.characters[fcid]["credits"]),
		"gate: mirror matches the DB after a concurrent flush+buy")

	# 12. an ORPHANED award packet (disconnect while transport is down) retries in the background
	var orp: Dictionary = await login("Orphan", 10)
	var ocid: String = orp["char_id"]
	srv._award_credits(10, 50)
	supa.fail_always["econ_award"] = true
	srv.drop_peer(10)                                      # logout flush fails → orphan queue
	await settle(20)
	supa.fail_always.erase("econ_award")
	ok(int(supa.characters[ocid]["credits"]) == 0, "orphan: nothing landed while transport was down")
	ok(srv._orphan_awards.size() >= 1, "orphan: packet queued for background retry")
	srv._retry_orphan_awards()
	await settle(12)
	ok(int(supa.characters[ocid]["credits"]) == 50, "orphan: the retry landed the award once")
	srv._retry_orphan_awards()
	await settle(12)
	ok(int(supa.characters[ocid]["credits"]) == 50 and srv._orphan_awards.is_empty(),
		"orphan: further ticks can't double-pay and the queue drains")

	# 13. craft succeeds when the scrap MIRROR is stale-low (the DB guard decides, like legacy)
	await wait_ms(400)
	supa.materials[fcid] = 12
	srv._session[9]["scrap"] = 0                           # e.g. a transiently failed login read
	var n2: int = supa.items_of(fcid).size()
	await srv.craft(9, "forge_unc")
	await settle()
	ok(supa.items_of(fcid).size() == n2 + 1 and int(supa.materials[fcid]) == 0,
		"craft: a stale-low scrap mirror no longer blocks a DB-affordable craft")

	finish("stab_econ_atomic")
