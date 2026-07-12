extends "res://tools/stab/stab_base.gd"
## Stabilization P2 — SINGLE ACTIVE SESSION per character (policy: REJECT the second connection):
##   • a second peer authenticating an already-online character is refused with a useful,
##     non-sensitive reason (recv_denied) and kicked — the first session is untouched;
##   • two NEAR-SIMULTANEOUS authentications for one character resolve to exactly ONE session;
##   • a normal disconnect releases the claim → a later login succeeds;
##   • a failed/abandoned authentication never leaves a claim behind;
##   • a stale claim with no live session (defensive) self-heals on the next login;
##   • the claim always maps the character to its live controlling peer.
## Run: godot --headless --path . --script res://tools/stab_sessions.gd

func _init() -> void:
	_run()

func _run() -> void:
	await boot()

	# ---- 1. second connection for an online character is refused with a reason ----
	var a: Dictionary = await login("Alice", 1)
	srv.connect_peer(2)
	await srv.authenticate(2, a["token"], Protocol.hello())                 # same character, second peer
	await settle()
	ok(not srv._session.has(2), "second connection: no session created")
	ok(srv._session.has(1) and int(srv._char_peer.get(a["char_id"], -1)) == 1,
		"second connection: the FIRST session keeps the character")
	ok(player_fighter_count() == 1, "second connection: exactly one fighter")
	var denies: Array = fnet.calls("recv_denied", 2)
	ok(denies.size() == 1 and str(denies[0]["args"][0]).contains("already online"),
		"second connection: refused with a useful reason before the drop")
	ok(srv.kicked.size() == 1 and int(srv.kicked[0]["pid"]) == 2, "second connection: peer kicked")

	# ---- 2. an authentication RACE resolves to exactly one winner ----
	var r: Dictionary = supa.add_character("Racer")
	supa.yield_frames = 4                                 # both auths in flight simultaneously
	srv.connect_peer(3)
	srv.connect_peer(4)
	srv.authenticate(3, r["token"], Protocol.hello())
	srv.authenticate(4, r["token"], Protocol.hello())
	await settle(30)
	supa.yield_frames = 1
	var winners := []
	for pid in [3, 4]:
		if srv._session.has(pid):
			winners.append(pid)
	ok(winners.size() == 1, "race: exactly one session (winners: %s)" % str(winners))
	ok(player_fighter_count() == 2, "race: exactly one new fighter (Alice + Racer)")
	ok(int(srv._char_peer.get(r["char_id"], -1)) == int(winners[0]) if winners.size() == 1 else false,
		"race: the claim maps to the winner")
	var loser: int = 4 if (winners.size() == 1 and int(winners[0]) == 3) else 3
	ok(fnet.calls("recv_denied", loser).size() == 1, "race: the loser was told why")

	# ---- 3. a normal disconnect releases the claim → relogin works ----
	if winners.size() == 1:
		srv.drop_peer(int(winners[0]))
	await settle()
	ok(not srv._char_peer.has(r["char_id"]), "disconnect: claim released")
	srv.connect_peer(5)
	await srv.authenticate(5, r["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(5) and int(srv._char_peer.get(r["char_id"], -1)) == 5,
		"disconnect: the character can log back in")
	srv.drop_peer(5)
	await settle()

	# ---- 4. an abandoned authentication leaves no claim ----
	supa.yield_frames = 4
	srv.connect_peer(6)
	srv.authenticate(6, r["token"], Protocol.hello())                       # fire…
	await settle(1)
	srv.drop_peer(6)                                      # …and vanish before the token check resolves
	await settle(20)
	supa.yield_frames = 1
	ok(not srv._char_peer.has(r["char_id"]), "abandoned auth: no claim left behind")
	srv.connect_peer(7)
	await srv.authenticate(7, r["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(7), "abandoned auth: a later valid login succeeds")
	srv.drop_peer(7)
	await settle()

	# ---- 5. an invalid token never claims ----
	srv.connect_peer(8)
	await srv.authenticate(8, "garbage-token", Protocol.hello())
	await settle()
	ok(srv._char_peer.size() == 1, "invalid token: no claim added (only Alice's remains)")

	# ---- 6. a stale claim with no live session self-heals ----
	var s2: Dictionary = supa.add_character("Stale")
	srv._char_peer[s2["char_id"]] = 999                   # forge a dead claim (no session 999)
	srv.connect_peer(9)
	await srv.authenticate(9, s2["token"], Protocol.hello())
	await settle()
	ok(srv._session.has(9) and int(srv._char_peer.get(s2["char_id"], -1)) == 9,
		"stale claim: reclaimed by the live login")

	finish("stab_sessions")
