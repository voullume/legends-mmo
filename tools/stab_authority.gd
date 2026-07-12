extends "res://tools/stab/stab_base.gd"
## Stabilization P1 — AUTHORITY invariants (headless, no net, no live DB):
##   • movement components are clamped to [-1,1], diagonals normalized, and NaN/Inf/non-numeric
##     components are neutralized (never reach the sim);
##   • malformed ability keys (wrong type) are rejected; unknown keys are inert through a full sim
##     tick; LOCKED abilities are rejected without consuming the sequence; duplicate/out-of-order
##     sequence numbers are rejected;
##   • item operations (equip / lock / sell / forge) refuse items owned by ANOTHER character;
##   • admin commands require the server-established admin flag (the service-role admins table);
##   • a tampered client-writable last_map (private instance key, gated map, unknown map) restores
##     to HOME — and a LEGITIMATELY qualified character still restores into the gated map.
## Run: godot --headless --path . --script res://tools/stab_authority.gd

func _init() -> void:
	_run()

func _run() -> void:
	await boot()
	var a: Dictionary = await login("Alice", 1, {"credits": 10000})

	# ---- 1. movement clamp / normalize / poison-proofing ----
	srv.submit_intent(1, {"mx": 99.0, "my": -99.0})
	ok(float(srv._move[1]["mx"]) <= 1.0 and float(srv._move[1]["my"]) >= -1.0, "movement: clamped to [-1,1]")
	srv.submit_intent(1, {"mx": 1.0, "my": 1.0})
	var v := Vector2(float(srv._move[1]["mx"]), float(srv._move[1]["my"]))
	ok(absf(v.length() - 1.0) < 0.001, "movement: diagonal normalized to unit length")
	srv.submit_intent(1, {"mx": NAN, "my": INF})
	ok(float(srv._move[1]["mx"]) == 0.0 and float(srv._move[1]["my"]) == 0.0, "movement: NaN/Inf neutralized")
	srv.submit_intent(1, {"mx": "junk", "my": [1, 2]})
	ok(float(srv._move[1]["mx"]) == 0.0 and float(srv._move[1]["my"]) == 0.0, "movement: non-numeric neutralized")

	# ---- 2. ability validation ----
	srv.submit_ability(1, 12345, 1)                       # wrong type
	ok(str(srv._pending_ability[1]) == "" and int(srv._last_aseq[1]) == 0, "ability: non-string key rejected")
	srv.submit_ability(1, "yellowcard", 1)                # striker special #2 unlocks at level 6; Alice is 1 (gated char)
	ok(str(srv._pending_ability[1]) == "" and int(srv._last_aseq[1]) == 0,
		"ability: LOCKED key rejected without consuming the sequence")
	srv.submit_ability(1, "finesse", 5)                   # the basic — always unlocked
	ok(str(srv._pending_ability[1]) == "finesse" and int(srv._last_aseq[1]) == 5, "ability: unlocked key accepted")
	srv.submit_ability(1, "finesse", 5)                   # duplicate seq
	srv.submit_ability(1, "finesse", 3)                   # out-of-order seq
	ok(int(srv._last_aseq[1]) == 5, "ability: duplicate/out-of-order sequence rejected")
	srv._pending_ability[1] = ""
	srv.submit_ability(1, "nosuchability", 9)             # unknown key: gate fails open, sim must stay inert
	var pf = srv._find(a["fid"])
	var hp_before := float(pf["hp"])
	srv._tick_world(srv._worlds[World.HOME], World.HOME)  # one full sim tick consumes the intent
	ok(not (pf["cds"] as Dictionary).has("nosuchability") and float(pf["hp"]) == hp_before,
		"ability: unknown key is inert through a full sim tick")
	# grandfathered character (pre-epoch created_at) keeps the full kit at level 1
	var g: Dictionary = await login("Gramps", 5, {"created_at": ""})
	srv.submit_ability(5, "goldengoal", 1)                # the ult (normally level 18)
	ok(str(srv._pending_ability[5]) == "goldengoal", "ability: grandfathered char keeps the full kit")
	srv.drop_peer(5)
	await settle()

	# ---- 3. item ownership scoping ----
	var b: Dictionary = await login("Bob", 2)
	var bob_item: String = supa.insert_item(b["char_id"], {"slot": "head", "rarity": "rare"})
	await srv.equip(1, bob_item, "head")                  # Alice tries to equip Bob's item
	await settle()
	ok(not bool(supa.inventory[bob_item]["equipped"]), "ownership: can't equip another character's item")
	await wait_ms(350)
	await srv.inv_set_locked(1, bob_item, true)
	await settle()
	ok(not bool(supa.inventory[bob_item]["locked"]), "ownership: can't lock another character's item")
	var alice_credits := int(srv._session[1]["credits"])
	await srv.shop_sell_many(1, [bob_item])               # Alice (at HOME) tries to sell Bob's item
	await settle()
	ok(supa.inventory.has(bob_item), "ownership: can't sell another character's item")
	ok(int(srv._session[1]["credits"]) == alice_credits, "ownership: no payout for a foreign item")
	supa.materials[a["char_id"]] = 100
	await wait_ms(350)
	await srv.forge_upgrade(1, bob_item)                  # Alice tries to upgrade Bob's item
	await settle()
	ok(int(supa.inventory[bob_item]["upgrade_level"]) == 0, "ownership: can't forge another character's item")
	ok(int(supa.materials[a["char_id"]]) == 100, "ownership: no scrap spent on a foreign item")

	# ---- 4. admin gating ----
	var pre := int(srv._session[1]["credits"])
	await srv.admin_cmd(1, "add_credits", {"amt": 999999})
	ok(int(srv._session[1]["credits"]) == pre, "admin: non-admin add_credits ignored")
	await srv.admin_cmd(1, "god", {})
	ok(not bool(srv._session[1].get("god", false)), "admin: non-admin god-mode ignored")
	var adm: Dictionary = await login("Root", 9, {"admin": true})
	ok(bool(srv._session[9].get("admin", false)), "admin: admins-table member gets the flag")
	var apre := int(srv._session[9]["credits"])
	await srv.admin_cmd(9, "add_credits", {"amt": 500})
	await settle()
	ok(int(srv._session[9]["credits"]) == apre + 500, "admin: real admin command works")
	ok(fnet.calls("recv_admin", 9).size() == 1, "admin: recv_admin(true) pushed on login")
	srv.drop_peer(9)
	await settle()

	# ---- 5. tampered last_map restoration ----
	for tampered in ["camp#deadbeef#5", "locker_room#%s#1" % b["char_id"], "glitchyard_boss",
			"glitchyard_secret", "totally_fake_map"]:
		var t: Dictionary = await login("Tamper", 20, {"last_map": tampered})
		ok(str(srv._session[20]["map"]) == World.HOME,
			"restore: tampered last_map '%s' lands at HOME" % tampered)
		srv.drop_peer(20)
		await settle()
	# …but a character that LEGITIMATELY meets the boss gate (level 16 + gear score 800) restores there
	var q: Dictionary = supa.add_character("Qualified", "striker",
		{"level": 16, "last_map": "glitchyard_boss"})
	supa.insert_item(q["char_id"], {"slot": "trinket", "rarity": "epic", "equipped": true, "item_power": 800})
	srv.connect_peer(21)
	await srv.authenticate(21, q["token"], Protocol.hello())
	await settle()
	ok(str(srv._session[21]["map"]) == "glitchyard_boss",
		"restore: a qualified character keeps its gated-map position")
	srv.drop_peer(21)
	await settle()

	# ---- 6. forged identifiers ----
	var start_c := int(srv._session[1]["credits"])
	await srv.build_buy(1, "not_a_catalog_model")
	await settle()
	ok(int(srv._session[1]["credits"]) == start_c, "forged build model: no charge, no item")
	await wait_ms(350)
	await srv.equip(1, "not-a-uuid", "head")              # malformed id: inert
	await settle()
	ok(true, "forged item id: no crash")

	finish("stab_authority")
