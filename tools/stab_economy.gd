extends "res://tools/stab/stab_base.gd"
## Stabilization P1 — ECONOMY + PERSISTENCE invariants (headless, no net, no live DB):
##   • a duplicate purchase request (same-frame double-send) debits and mints exactly once;
##   • a failure AFTER the debit refunds — and the refund is persisted (no silently lost currency);
##   • a failure AFTER item creation is a save failure that is OBSERVABLE (never a false success);
##   • selling dedups ids, pays once per removed row, and never touches equipped/locked/foreign items;
##   • one item raced by sell + salvage pays exactly ONE of the two (atomic single-row delete);
##   • forge upgrade refunds both currencies when the gated write loses; an unaffordable op spends 0;
##   • craft refunds scrap when the insert fails; vendor/locker/cosmetic double-buys charge once;
##   • a disconnect mid-bulk-sell leaves a CONSISTENT persisted balance (deferred-save contract);
##   • equipped-slot capacity holds at read time even if the DB holds > cap rows.
## Run: godot --headless --path . --script res://tools/stab_economy.gd

const SP := preload("res://server/Server.gd")   # constants (prices/yields) — never literal-asserted

func _init() -> void:
	_run()

func _sync_credits(pid: int, cid: String, amt: int) -> void:
	srv._session[pid]["credits"] = amt
	supa.characters[cid]["credits"] = amt

func _run() -> void:
	await boot()
	var a: Dictionary = await login("Alice", 1)
	var cid: String = a["char_id"]
	var buy_price := int(SP.BUY_PRICE["common"])
	var sell_price := int(SP.SELL_PRICE["common"])

	# ---- 1. duplicate purchase: same-frame double-send debits/mints once ----
	_sync_credits(1, cid, buy_price * 2)                   # could afford two — must still buy ONE
	supa.yield_frames = 3
	srv.shop_buy(1, "head", "common")
	srv.shop_buy(1, "head", "common")
	await settle(20)
	supa.yield_frames = 1
	ok(int(srv._session[1]["credits"]) == buy_price, "dup buy: exactly one debit")
	ok(supa.items_of(cid).size() == 1, "dup buy: exactly one item minted")
	ok(int(supa.calls.get("add_item_as", 0)) == 1, "dup buy: one DB insert")
	ok(int(supa.characters[cid]["credits"]) == buy_price, "dup buy: debited balance persisted")

	# ---- 2. failure after debit → refund, persisted ----
	await wait_ms(350)
	_sync_credits(1, cid, buy_price)
	var items_before: int = supa.items_of(cid).size()
	supa.fail_once["add_item_as"] = 1
	await srv.shop_buy(1, "head", "common")
	await settle()
	ok(int(srv._session[1]["credits"]) == buy_price, "debit-then-fail: refunded in-session")
	ok(int(supa.characters[cid]["credits"]) == buy_price, "debit-then-fail: refund PERSISTED")
	ok(supa.items_of(cid).size() == items_before, "debit-then-fail: no unpaid item")

	# ---- 3. persistence failure is observable, never a false success ----
	var fails_before: int = srv._save_fail_n
	supa.fail_once["save_character_as"] = 1
	srv._award_xp(1, 1)
	await settle()
	ok(srv._save_fail_n == fails_before + 1, "save failure: counted + logged (observable)")

	# ---- 4. selling: dedup, pay-per-removed-row, equipped/locked protected ----
	await wait_ms(350)
	var i1: String = supa.insert_item(cid, {"slot": "feet"})
	var i2: String = supa.insert_item(cid, {"slot": "neck"})
	var eq: String = supa.insert_item(cid, {"slot": "chest", "equipped": true})
	var lk: String = supa.insert_item(cid, {"slot": "hands", "locked": true})
	_sync_credits(1, cid, 0)
	await srv.shop_sell_many(1, [i1, i1, i2, eq, lk])
	await settle()
	ok(int(srv._session[1]["credits"]) == sell_price * 2, "sell: duplicate ids paid once each row")
	ok(not supa.inventory.has(i1) and not supa.inventory.has(i2), "sell: sold rows removed")
	ok(supa.inventory.has(eq) and supa.inventory.has(lk), "sell: equipped + locked items survive")
	await wait_ms(350)
	await srv.shop_sell_many(1, [i1])                      # replay a consumed id
	await settle()
	ok(int(srv._session[1]["credits"]) == sell_price * 2, "sell: replaying a sold id pays nothing")

	# ---- 5. sell vs salvage race on ONE item → exactly one payout ----
	await wait_ms(350)
	var i3: String = supa.insert_item(cid, {"slot": "ring"})
	_sync_credits(1, cid, 0)
	supa.materials[cid] = 0
	srv._session[1]["scrap"] = 0
	supa.yield_frames = 2
	srv.shop_sell_many(1, [i3])                            # different locks → both flows run
	srv.salvage_many(1, [i3])                              # the row delete is the atomic arbiter
	await settle(24)
	supa.yield_frames = 1
	var got_credits := int(srv._session[1]["credits"]) > 0
	var got_scrap := int(supa.materials.get(cid, 0)) > 0
	ok(got_credits != got_scrap, "race: sell XOR salvage paid (never both, never neither)")
	ok(not supa.inventory.has(i3), "race: the item is gone exactly once")

	# ---- 6. forge upgrade: refund on lost write; zero spend when unaffordable ----
	await wait_ms(350)
	var up: String = supa.insert_item(cid, {"slot": "main_hand", "rarity": "common"})
	_sync_credits(1, cid, 100)
	supa.materials[cid] = 10
	srv._session[1]["scrap"] = 10
	supa.fail_once["inv_upgrade_as"] = 1
	await srv.forge_upgrade(1, up)
	await settle()
	ok(int(srv._session[1]["credits"]) == 100 and int(supa.materials[cid]) == 10,
		"forge: lost gated write refunds credits AND scrap")
	ok(int(supa.inventory[up]["upgrade_level"]) == 0, "forge: item unchanged after refund")
	await wait_ms(350)
	supa.materials[cid] = 0                                # can't afford the scrap cost
	srv._session[1]["scrap"] = 0
	await srv.forge_upgrade(1, up)
	await settle()
	ok(int(srv._session[1]["credits"]) == 100 and int(supa.inventory[up]["upgrade_level"]) == 0,
		"forge: unaffordable op spends nothing")

	# ---- 7. craft: refund on insert failure, single spend on success ----
	await wait_ms(350)
	supa.materials[cid] = 12
	srv._session[1]["scrap"] = 12
	var n_before: int = supa.items_of(cid).size()
	supa.fail_once["add_item_as"] = 1
	await srv.craft(1, "forge_unc")                        # costs 12 scrap
	await settle()
	ok(int(supa.materials[cid]) == 12, "craft: failed insert refunds the scrap")
	ok(supa.items_of(cid).size() == n_before, "craft: no item on failure")
	await wait_ms(350)
	await srv.craft(1, "forge_unc")
	await settle()
	ok(int(supa.materials[cid]) == 0, "craft: success spends the scrap once")
	ok(supa.items_of(cid).size() == n_before + 1, "craft: success mints one item")

	# ---- 8. vendor double-buy charges once ----
	await wait_ms(350)
	srv._session[1]["tokens"] = SP.TOKEN_PRICE * 2
	supa.characters[cid]["practice_tokens"] = SP.TOKEN_PRICE * 2
	var v_before: int = supa.items_of(cid).size()
	supa.yield_frames = 3
	srv.vendor_buy(1, "head")
	srv.vendor_buy(1, "head")
	await settle(20)
	supa.yield_frames = 1
	ok(int(srv._session[1]["tokens"]) == SP.TOKEN_PRICE, "vendor: double-send debits tokens once")
	ok(supa.items_of(cid).size() == v_before + 1, "vendor: one Rookie piece minted")

	# ---- 9. locker unlock: double-send charges once; re-buy after owning is free no-op ----
	await wait_ms(350)
	_sync_credits(1, cid, SP.LOCKER_UNLOCK_COST * 2)
	supa.yield_frames = 3
	srv.buy_locker_room(1)
	srv.buy_locker_room(1)
	await settle(20)
	supa.yield_frames = 1
	ok(int(srv._session[1]["credits"]) == SP.LOCKER_UNLOCK_COST, "locker: double-send debits once")
	ok(bool(supa.characters[cid]["locker_unlocked"]), "locker: flag flipped in the DB")
	await wait_ms(350)
	await srv.buy_locker_room(1)                           # already owned
	await settle()
	ok(int(srv._session[1]["credits"]) == SP.LOCKER_UNLOCK_COST, "locker: owning it makes re-buy free no-op")

	# ---- 10. cosmetics: double-buy charges once; lost grant race refunds ----
	await wait_ms(350)
	var dye_price := int(GameData.DYE_CATALOG["crimson"]["price"])
	_sync_credits(1, cid, dye_price * 3)
	await srv.buy_cosmetic(1, "crimson")
	await wait_ms(350)
	await srv.buy_cosmetic(1, "crimson")                   # already owned in-session → no charge
	await settle()
	ok(int(srv._session[1]["credits"]) == dye_price * 2, "cosmetic: second buy of an owned dye is free")
	supa.fail_once["cosmetics_grant_as"] = 1               # ≈ another session won the grant race
	await wait_ms(350)
	await srv.buy_cosmetic(1, "azure")
	await settle()
	ok(int(srv._session[1]["credits"]) == dye_price * 2, "cosmetic: lost grant refunds the debit")
	ok(not ("azure" in (srv._session[1]["cos_owned"] as Array)), "cosmetic: lost grant grants nothing")

	# ---- 11. disconnect mid-bulk-sell → consistent persisted balance (deferred-save contract) ----
	var d: Dictionary = await login("Dana", 3)
	var did: String = d["char_id"]
	var j := [supa.insert_item(did, {}), supa.insert_item(did, {}), supa.insert_item(did, {})]
	_sync_credits(3, did, 0)
	supa.yield_frames = 2
	srv.shop_sell_many(3, [j[0], j[1], j[2]])
	await settle(3)                                        # mid-loop…
	srv.drop_peer(3)                                       # …the peer vanishes
	await settle(24)
	supa.yield_frames = 1
	var remaining := 0
	for id in j:
		if supa.inventory.has(id):
			remaining += 1
	var persisted := int(supa.characters[did]["credits"])
	ok(persisted == sell_price * (3 - remaining),
		"disconnect mid-sell: persisted credits exactly match removed rows (%d left, %d cr)" % [remaining, persisted])

	# ---- 12. equip-slot capacity holds at read time even if the DB exceeds it ----
	var e: Dictionary = await login("Evan", 4)
	for k in 3:                                            # 3 equipped HEAD items (cap is 1)
		supa.insert_item(e["char_id"], {"slot": "head", "equipped": true, "item_power": 50})
	await srv._apply_equipment(4)
	await settle()
	ok(int(srv._session[4]["item_power"]) == 50, "slot cap: only capacity-many equipped items count")

	finish("stab_economy")
