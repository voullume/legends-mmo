extends "res://tools/stab/stab_base.gd"
## Stabilization P5 — PROTOCOL VERSION HANDSHAKE:
##   • a matching protocol version authenticates normally;
##   • a MISSING version (old client / empty hello) is refused with a "please update" reason,
##     BEFORE any token work (no DB call, no session, no claim);
##   • an OLDER version is refused ("out of date"), a NEWER version is refused ("newer than the
##     server") — both with the version numbers in the message;
##   • a malformed hello (junk types) counts as missing;
##   • no gameplay/economy command is accepted between transport-connect and a validated
##     authentication (the pre-auth rejection contract).
## Run: godot --headless --path . --script res://tools/stab_protocol.gd

func _init() -> void:
	_run()

func _deny_reason(pid: int) -> String:
	var d: Array = fnet.calls("recv_denied", pid)
	return str(d[0]["args"][0]) if d.size() > 0 else ""

func _run() -> void:
	await boot()
	var acct: Dictionary = supa.add_character("Versa")

	# ---- 1. matching version → normal login ----
	srv.connect_peer(1)
	await srv.authenticate(1, acct["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(1), "matching protocol: session created")
	srv.drop_peer(1)
	await settle()

	# ---- 2. missing version (legacy client): refused BEFORE any token work ----
	var token_checks: int = int(supa.calls.get("get_character_as", 0))
	srv.connect_peer(2)
	await srv.authenticate(2, acct["token"], {})
	await settle()
	ok(not srv._session.has(2), "missing protocol: no session")
	ok(int(supa.calls.get("get_character_as", 0)) == token_checks,
		"missing protocol: refused BEFORE the token was even checked")
	ok(_deny_reason(2).contains("update") and _deny_reason(2).contains("v%d" % Protocol.VERSION),
		"missing protocol: useful reason with the required version")
	ok(srv._char_peer.size() == 0, "missing protocol: no session claim")

	# ---- 3. older version → 'out of date' with both numbers ----
	srv.connect_peer(3)
	await srv.authenticate(3, acct["token"], {"protocol": Protocol.VERSION - 1})
	await settle()
	ok(not srv._session.has(3), "older protocol: no session")
	var r3 := _deny_reason(3)
	ok(r3.contains("out of date") and r3.contains("v%d" % Protocol.VERSION),
		"older protocol: 'out of date' + the server version")

	# ---- 4. newer version → 'newer than the server' ----
	srv.connect_peer(4)
	await srv.authenticate(4, acct["token"], {"protocol": Protocol.VERSION + 1})
	await settle()
	ok(not srv._session.has(4), "newer protocol: no session")
	ok(_deny_reason(4).contains("newer"), "newer protocol: tells the player the ZONE is behind")

	# ---- 5. malformed hello values count as missing ----
	for bad in [{"protocol": "one"}, {"protocol": [1]}, {"protocol": -3}]:
		srv.connect_peer(5)
		await srv.authenticate(5, acct["token"], bad)
		await settle()
		ok(not srv._session.has(5), "malformed hello %s: refused" % str(bad))
		srv.drop_peer(5)
		await settle()

	# ---- 6. nothing gameplay-facing works between connect and validated auth ----
	srv.connect_peer(6)                                   # transport-connected, never authenticated
	srv.submit_intent(6, {"mx": 1.0, "my": 0.0})
	srv.submit_ability(6, "finesse", 1)
	await srv.shop_buy(6, "head", "common")
	srv.chat(6, "pre-auth")
	await settle()
	ok(not srv._move.has(6) and not srv._session.has(6) and fnet.calls("recv_chat").is_empty(),
		"pre-auth: movement/ability/economy/chat all rejected")

	# ---- 7. a valid login still works after all the refusals ----
	srv.connect_peer(7)
	await srv.authenticate(7, acct["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(7), "handshake refusals never wedge a later valid login")

	finish("stab_protocol")
