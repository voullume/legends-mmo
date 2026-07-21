extends "res://tools/stab/stab_base.gd"
## W7 — THE BASE CAMP HUB invariants, against the REAL server (headless, no net):
##   • the basecamp boots as a static SAFE world (regen/aggro/fixed-spawn semantics);
##   • every inbound pad carries wild_gate (S1 rule) and gate_for_map derives it;
##   • the tier-2 shop: catalog at ilvl 17 with T2 prices, buy/roll priced by the BUYER'S map,
##     refused outside service zones; Home keeps its ilvl-8 tier untouched;
##   • forge family (salvage/upgrade/reforge/craft) works at the camp, refused in combat zones;
##   • HOME-only services stay home-only: vendor, build shop, master-key craft;
##   • quest giver #2: WILD chain accept/progress/turn-in at the camp pad, bounty claim co-located;
##   • WILD_ORDER governance: in display_order, NOT in ORDER (secret-boss gate untouched);
##   • residents: both camp residents spawn in-bounds in the safe zone;
##   • wildveil dye: in DYE_CATALOG, NOT in DYE_IDS (quest-exclusive, never buyable).
## Run: godot --headless --path . --script res://tools/stab_basecamp.gd

const Quests := preload("res://shared/Quests.gd")

func _init() -> void:
	_run()

func _run() -> void:
	await boot()

	# ---- 1. the zone boots safe ----
	ok(srv._worlds.has("basecamp"), "boot: basecamp boots as a static world")
	var bw = srv._worlds["basecamp"]
	ok(not bool(bw["aggro"]) and float(bw["regen"]) > 0.1, "basecamp: safe semantics (no aggro, strong regen)")
	var mobs := 0
	for f in bw["fighters"]:
		if int(f["team"]) == 1: mobs += 1
	ok(mobs == 0, "basecamp: no mobs (and no dummy — residents would attack it)")

	# ---- 2. gates: every inbound pad carries wild_gate; restore derives it ----
	for src in ["away_3", "home"]:
		var carried := false
		for p in World.PORTALS.get(src, []):
			if str(p.get("to", "")) == "basecamp" and str(p.get("gate", "")) == "wild_gate": carried = true
		ok(carried, "S1 rule: %s's Base Camp pad carries wild_gate" % src)
	ok(World.gate_for_map("basecamp") == "wild_gate", "restore: basecamp derives wild_gate from its inbound pads")

	# ---- 3. tier-2 shop at the camp; home tier untouched; combat zones refused ----
	var vet: Dictionary = await login("Camper", 2, {"level": 16, "credits": 20000, "last_map": "basecamp", "created_at": "2026-01-01T00:00:00Z"})
	ok(str(srv._session[2]["map"]) == "basecamp", "login: a grandfathered vet resumes at the camp")
	var cat2: Array = srv._catalog_for(2)
	var all17 := true
	for it in cat2:
		if int(it.get("ilvl", 0)) != srv.SHOP_ILVL_T2: all17 = false
	ok(cat2.size() > 0 and all17, "shop: the camp catalog rolls at ilvl %d" % srv.SHOP_ILVL_T2)
	ok(srv._roll_price_for(2) == srv.ROLL_PRICE_T2, "shop: the camp uses T2 roll prices")
	var invr: int = supa.items_of(vet["char_id"]).size()
	await srv._do_shop_roll(2, "epic")
	await settle()
	var rolled_items: Array = supa.items_of(vet["char_id"])
	ok(rolled_items.size() == invr + 1 and int((rolled_items[rolled_items.size() - 1] as Dictionary).get("ilvl", 0)) == srv.SHOP_ROLL_ILVL_T2,
		"shop: the T2 roll executes at the capped gamble ilvl %d (IP stays under the quest epics)" % srv.SHOP_ROLL_ILVL_T2)
	var pushed: Array = fnet.calls("recv_shop_info", 2)
	var t2ok := false
	for c in pushed:
		var info: Dictionary = c["args"][0]
		if (info.get("t2", {}) as Dictionary).has("catalog") and (info.get("t2", {}) as Dictionary).has("roll"): t2ok = true
	ok(t2ok, "shop: the auth push carries the t2 {catalog, roll} shape the client renders from")
	var inv0: int = supa.items_of(vet["char_id"]).size()
	await srv._do_shop_buy(2, "trinket", "rare")
	await settle()
	var bought: Array = supa.items_of(vet["char_id"])
	ok(bought.size() == inv0 + 1, "shop: a camp buy lands in the inventory")
	var got: Dictionary = bought[bought.size() - 1]
	ok(int(got.get("ilvl", 0)) == srv.SHOP_ILVL_T2, "shop: the bought item IS the tier-2 ilvl (server priced by buyer map)")
	var creds_after: int = int(srv._session[2]["credits"])
	ok(creds_after == 20000 - int(srv.ROLL_PRICE_T2["epic"]) - int(srv.BUY_PRICE_T2["rare"]), "shop: charged the T2 roll (%d) + buy (%d) prices" % [int(srv.ROLL_PRICE_T2["epic"]), int(srv.BUY_PRICE_T2["rare"])])
	# home keeps tier 1
	var homer: Dictionary = await login("Homer", 3, {"level": 16, "credits": 20000})
	ok(srv._catalog_for(3)[0].get("ilvl", 0) == srv.SHOP_ILVL, "shop: HOME still sells the ilvl-%d baseline" % srv.SHOP_ILVL)
	# combat zone refused
	srv._session[2]["quests"]["gy5_command"] = {"completed": true, "progress": 2, "rewarded": true}
	srv._relocate(srv._find(vet["fid"]), srv._session[2], "away_1", Vector2(300, 200))
	var inv1: int = supa.items_of(vet["char_id"]).size()
	await srv._do_shop_buy(2, "trinket", "rare")
	await settle()
	ok(supa.items_of(vet["char_id"]).size() == inv1, "shop: buying in a combat zone is refused")
	srv._relocate(srv._find(vet["fid"]), srv._session[2], "basecamp", Vector2(400, 450))

	# ---- 4. forge family at the camp; HOME-only services refused there ----
	await srv._do_salvage_many(2, [str(got.get("id", ""))])
	await settle()
	ok(supa.items_of(vet["char_id"]).size() == inv1 - 1, "forge: salvage works at the camp")
	var scrap0: int = int(srv._session[2].get("scrap", 0))
	ok(scrap0 > 0, "forge: salvage paid scrap")
	srv._session[2]["scrap"] = 500
	supa.materials[vet["char_id"]] = 500          # the fake DB is the authoritative scrap store (atomic econ)
	var invc: int = supa.items_of(vet["char_id"]).size()
	await srv._do_craft(2, "forge_rare2")
	await settle()
	var crafted: Array = supa.items_of(vet["char_id"])
	ok(crafted.size() == invc + 1 and int((crafted[crafted.size() - 1] as Dictionary).get("ilvl", 0)) == 24,
		"forge: the Wildforge Rare recipe crafts at ilvl 24 at the camp")
	var creds_b: int = int(srv._session[2]["credits"])
	await srv._do_vendor_buy(2, "head")
	await settle()
	ok(int(srv._session[2]["credits"]) == creds_b, "guard: the Practice Vendor stays HOME-only (camp refused)")
	var had_key: bool = bool(srv._session[2].get("has_key", false))
	await srv._do_craft_master_key(2)
	await settle()
	ok(bool(srv._session[2].get("has_key", false)) == had_key, "guard: master-key crafting stays HOME-only")

	# ---- 5. quest giver #2 + the WILD chain + bounty co-location ----
	ok(Quests.ORDER.size() == 9, "governance: the secret-boss gate list is untouched (9)")
	ok(Quests.display_order().has("wild1_stake") and not Quests.ORDER.has("wild1_stake"),
		"governance: WILD chain is in display_order, NOT in ORDER")
	var gp = World.service_pad("basecamp", "questgiver")
	var vf = srv._find(vet["fid"])
	vf["x"] = (gp as Vector2).x
	vf["y"] = (gp as Vector2).y
	ok(srv._at_questgiver(2), "giver: standing at the CAMP pad passes the guard")
	await srv._do_quest_accept(2, "wild1_stake")
	await settle()
	ok((srv._session[2]["quests"] as Dictionary).has("wild1_stake"), "quest: wild1_stake accepted at the camp giver")
	# progress via the real award path: kill an away_3 wildlife mob
	var target = null
	for f in srv._worlds["away_3"]["fighters"]:
		if int(f["team"]) == 1 and str(f["classId"]) == "rallywing_magpie": target = f
	srv._worlds["away_3"]["events"].append({"type": "kill", "victim": target["id"], "killer": vet["fid"]})
	# the killer must be in-zone for credit
	srv._relocate(vf, srv._session[2], "away_3", Vector2(300, 900))
	srv._award_kills()
	srv._worlds["away_3"]["events"].clear()
	await settle()
	ok(int((srv._session[2]["quests"]["wild1_stake"] as Dictionary).get("progress", 0)) == 1,
		"quest: an away_3 wildlife kill advances the WILD objective")
	srv._relocate(srv._find(vet["fid"]), srv._session[2], "basecamp", Vector2((gp as Vector2).x, (gp as Vector2).y))
	# bounty claim co-located: the camp giver passes the same guard the claim path uses
	ok(srv._at_questgiver(2), "bounty: claims share the camp giver guard (co-located)")
	ok(srv.BOUNTY_DAILY.has("d_wilds"), "bounty: the Camp Perimeter daily exists")

	# ---- 6. residents in-bounds; dye governance ----
	var res_in := 0
	for f in srv._worlds["basecamp"]["fighters"]:
		if bool(f.get("resident", false)):
			res_in += 1
			ok(float(f["x"]) < 1200.0 and float(f["y"]) < 640.0, "resident %s spawns in-bounds" % f.get("resName", "?"))
	ok(res_in == 2, "residents: both camp residents home at the camp (got %d)" % res_in)
	ok(GameData.DYE_CATALOG.has("wildveil") and not GameData.DYE_IDS.has("wildveil"),
		"dye: wildveil is quest-exclusive (in CATALOG, not in the buyable list)")

	finish("stab_basecamp")
