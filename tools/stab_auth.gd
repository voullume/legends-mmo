extends "res://tools/stab/stab_base.gd"
## Stabilization P1 — AUTHENTICATION + SESSION LIFECYCLE invariants (headless, no net, no live DB):
##   • an unauthenticated peer can submit NOTHING that mutates state (movement, abilities, economy,
##     party, admin, quests, bounties, building, chat) — no state, no DB write, no reply;
##   • an invalid access token creates no fighter and no session, and the peer is kicked;
##   • reauthentication is accepted ONLY when the new token resolves to the same character;
##   • a disconnected peer is scrubbed from EVERY session/party/movement/rate-limit/busy-lock/
##     snapshot structure (the exhaustive PID_DICTS contract) and its fighter is removed;
##   • an auth abandoned by a mid-flight disconnect leaves nothing behind;
##   • a reconnect starts from a clean slate (no stale ability seq / movement / session fields).
## Run: godot --headless --path . --script res://tools/stab_auth.gd

func _init() -> void:
	_run()

func _run() -> void:
	await boot()

	# ---- 1. unauthenticated peers can do nothing ----
	var P := 99   # never authenticated
	srv.submit_intent(P, {"mx": 1.0, "my": 0.0})
	srv.submit_ability(P, "finesse", 1)
	srv.chat(P, "hello")
	await srv.equip(P, "00000000-0000-4000-8000-000000000001", "head")
	await srv.shop_buy(P, "head", "common")
	await srv.shop_roll(P, "common")
	await srv.shop_sell_many(P, ["00000000-0000-4000-8000-000000000001"])
	await srv.vendor_buy(P, "head")
	await srv.inv_set_locked(P, "00000000-0000-4000-8000-000000000001", true)
	await srv.salvage_many(P, ["00000000-0000-4000-8000-000000000001"])
	await srv.forge_upgrade(P, "00000000-0000-4000-8000-000000000001")
	await srv.forge_reforge(P, "00000000-0000-4000-8000-000000000001")
	await srv.craft(P, "craft_rare")
	await srv.buy_cosmetic(P, "crimson")
	await srv.equip_cosmetic(P, "crimson")
	await srv.buy_locker_room(P)
	await srv.build_buy(P, "tree_oak")
	await srv.build_place(P, "00000000-0000-4000-8000-000000000001", {})
	await srv.build_move(P, "00000000-0000-4000-8000-000000000001", {})
	await srv.build_remove(P, "00000000-0000-4000-8000-000000000001")
	await srv.spend_talent(P, "st_finishing_1", 1)
	await srv.respec_talents(P)
	await srv.set_paragon(P, {"payroll_credit": 1})
	await srv.buy_audible(P, "aud_bonus")
	srv.enter_camp(P, 1)
	await srv.craft_master_key(P)
	await srv.quest_action(P, "accept", "gy1_cones")
	await srv.bounty_action(P, "claim", "d_sweep")
	srv.party_invite(P, "p1")
	srv.party_accept(P, "p1")
	srv.party_decline(P)
	srv.party_leave(P)
	srv.loot_roll(P, 1, "need")
	await srv.fetch_leaderboard(P, "drill")
	await srv.admin_cmd(P, "add_credits", {"amt": 999999})
	await settle()
	ok(srv._session.is_empty(), "unauth: no session was created")
	ok(not srv._move.has(P) and not srv._pending_ability.has(P), "unauth: no movement/ability state")
	ok(player_fighter_count() == 0, "unauth: no fighter spawned")
	ok(fnet.sent.is_empty(), "unauth: server sent nothing back")
	for m in ["add_item_as", "mats_add_as", "save_character_as", "sell_item_safe_as",
			"cosmetics_grant_as", "locker_unlock_as", "add_build_item_as", "quest_save_as",
			"bounty_claim_as", "talents_spend_as", "paragon_set_as", "progression_add_pages_as"]:
		ok(int(supa.calls.get(m, 0)) == 0, "unauth: no DB mutation via %s" % m)

	# ---- 2. invalid access token → kicked, no fighter/session ----
	srv.connect_peer(7)
	await srv.authenticate(7, "not-a-real-token", Protocol.hello())
	await settle()
	ok(not srv._session.has(7), "bad token: no session")
	ok(player_fighter_count() == 0, "bad token: no fighter")
	ok(srv.kicked.size() == 1 and int(srv.kicked[0]["pid"]) == 7, "bad token: peer was kicked")
	ok(srv._authing.is_empty(), "bad token: no _authing leak")

	# ---- 3. valid login sanity ----
	var a: Dictionary = await login("Alice", 1, {"credits": 100})
	ok(srv._session.has(1) and a["fid"] != "", "login: session + fighter created")
	ok(fnet.calls("assign_fighter", 1).size() == 1, "login: assign_fighter sent")
	ok(fnet.calls("recv_shop_info", 1).size() == 1, "login: shop catalog pushed")
	ok(int(srv._session[1]["credits"]) == 100, "login: credits loaded from the DB row")

	# ---- 4. double-authenticate for an already-authed peer is a no-op ----
	var fid_before: String = str(srv._session[1]["fid"])
	await srv.authenticate(1, a["token"], Protocol.hello())
	await settle()
	ok(str(srv._session[1]["fid"]) == fid_before and player_fighter_count() == 1,
		"re-authenticate same peer: no duplicate fighter/session")

	# ---- 5. reauth only for the SAME character ----
	var b: Dictionary = await login("Bob", 2)
	await srv.reauth(1, b["token"])                    # Alice's peer offers Bob's token
	await settle()
	ok(str(srv._session[1]["access"]) == str(a["token"]), "reauth: foreign-character token REFUSED")
	supa.tokens["tok-fresh-alice"] = a["char_id"]      # a fresh token for the same character
	await srv.reauth(1, "tok-fresh-alice")
	await settle()
	ok(str(srv._session[1]["access"]) == "tok-fresh-alice", "reauth: same-character token accepted")
	await srv.reauth(555, a["token"])                  # unknown peer → no-op
	ok(not srv._session.has(555), "reauth: unknown peer is a no-op")

	# ---- 6. disconnect scrubs every per-peer structure ----
	srv.submit_intent(2, {"mx": 0.5, "my": 0.5})       # seed movement/rate-limit state
	srv.submit_ability(2, "finesse", 3)
	srv.chat(2, "seeding rate limit")
	await settle(2)
	srv.drop_peer(2)
	await settle()
	var leaks: Array = pid_state_leaks(2)
	ok(leaks.is_empty(), "disconnect: no per-peer state leaked (leaked: %s)" % str(leaks))
	ok(player_fighter_count() == 1, "disconnect: fighter removed from the world")

	# ---- 7. abandoned auth (peer drops mid-flight) leaves nothing ----
	supa.yield_frames = 4                              # stretch the token check across frames
	srv.connect_peer(8)
	srv.authenticate(8, a["token"], Protocol.hello())                    # fire WITHOUT await…
	await settle(1)
	srv.drop_peer(8)                                   # …and vanish before the token check lands
	await settle(12)
	supa.yield_frames = 1
	ok(not srv._session.has(8) and pid_state_leaks(8).is_empty(),
		"abandoned auth: no session/lease left behind")
	ok(player_fighter_count() == 1, "abandoned auth: no fighter spawned")

	# ---- 8. reconnect starts clean (no stale peer state inherited) ----
	var c: Dictionary = await login("Cara", 2)         # pid 2 reused after the disconnect above
	ok(c["fid"] != "" and int(srv._last_aseq[2]) == 0, "reconnect: fresh ability sequence")
	ok(float(srv._move[2]["mx"]) == 0.0 and float(srv._move[2]["my"]) == 0.0,
		"reconnect: fresh movement intent")
	ok(str(srv._session[2]["name"]) == "Cara", "reconnect: fresh session identity")

	# ---- 9. a normal disconnect permits a later login for the SAME character ----
	srv.drop_peer(2)
	await settle()
	srv.connect_peer(3)
	await srv.authenticate(3, c["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(3) and str(srv._session[3]["char_id"]) == str(c["char_id"]),
		"relogin after disconnect: same character logs back in")

	finish("stab_auth")
