extends SceneTree
## Shared harness for the stabilization test suites (tools/stab_*.gd). Boots the PRODUCTION server
## (via tools/stab/test_server.gd, which stubs only the two transport seams) against the deterministic
## fake Supabase + fake Net — no ENet, no live DB. Suites extend this, call boot()/login()/…,
## assert with ok(), and finish() exits non-zero on any failure (CI-gradeable, house style).

const TestServer := preload("res://tools/stab/test_server.gd")
const FakeSupa := preload("res://tools/stab/fake_supa.gd")
const FakeNet := preload("res://tools/stab/fake_net.gd")
const World := preload("res://shared/World.gd")
const GameData := preload("res://shared/GameData.gd")
const Protocol := preload("res://shared/Protocol.gd")

var pass_n := 0
var fail_n := 0
var srv = null      # the server under test (tools/stab/test_server.gd)
var supa = null     # FakeSupa
var fnet = null     # FakeNet

func ok(cond: bool, label: String) -> void:
	if cond:
		pass_n += 1
	else:
		fail_n += 1
		print("  ✗ FAIL: %s" % label)

func boot() -> void:
	supa = FakeSupa.new()
	fnet = FakeNet.new()
	srv = TestServer.new()
	root.add_child(supa)
	root.add_child(fnet)
	srv.net = fnet
	srv.supa = supa
	root.add_child(srv)
	srv.set_physics_process(false)      # tests drive ticks explicitly (deterministic)
	srv.init_worlds()
	await process_frame                 # _init runs before the tree goes live; wait one frame so the
	                                    # fakes' in-tree awaits (get_tree().process_frame) work from call #1

func settle(frames := 8) -> void:       # let in-flight coroutines/deferred cleanup resolve
	for i in frames:
		await process_frame

func wait_ms(ms: int) -> void:          # step past a server rate-limit window (real wall clock)
	await create_timer(float(ms) / 1000.0).timeout

# create a character + connect the fake peer + run the REAL authenticate; returns ids ("" fid = rejected)
func login(cname: String, pid: int, opts := {}) -> Dictionary:
	var acct: Dictionary = supa.add_character(cname, str(opts.get("class", "striker")), opts)
	if bool(opts.get("admin", false)):
		supa.admins[acct["user_id"]] = true
	srv.connect_peer(pid)
	await srv.authenticate(pid, acct["token"], Protocol.hello())
	await settle()
	var fid := ""
	if srv._session.has(pid):
		fid = str(srv._session[pid]["fid"])
	return {"pid": pid, "char_id": acct["char_id"], "token": acct["token"],
		"user_id": acct["user_id"], "fid": fid}

# count live team-0 non-resident fighters (i.e. real player fighters) across all worlds
func player_fighter_count() -> int:
	var n := 0
	for mapname in srv._worlds:
		for f in srv._worlds[mapname]["fighters"]:
			if int(f["team"]) == 0 and not f.get("resident", false):
				n += 1
	return n

# every per-pid structure _on_peer_disconnected must clear — the exhaustive cleanup contract
const PID_DICTS := ["_session", "_move", "_pending_ability", "_last_aseq", "_intent_age",
	"_meta_hash", "_meta_tick", "_chat_next", "_equipping", "_equip_next", "_party_invite_next",
	"_tal_busy", "_tal_next", "_par_busy", "_par_next", "_aud_busy", "_aud_next",
	"_shop_busy", "_shop_next", "_sellmany_busy", "_sellmany_next", "_vendor_busy", "_vendor_next",
	"_lock_busy", "_lock_next", "_salvage_busy", "_salvage_next", "_forge_busy", "_forge_next",
	"_craft_busy", "_craft_next", "_quest_busy", "_quest_next", "_bounty_busy", "_bounty_next",
	"_camp_next", "_key_busy", "_key_next", "_cos_busy", "_cos_next", "_locker_busy", "_locker_next",
	"_build_busy", "_build_next", "_lb_next", "_gate_prompt_next", "_authing"]

func pid_state_leaks(pid: int) -> Array:
	var leaks := []
	for d in PID_DICTS:
		if (srv.get(d) as Dictionary).has(pid):
			leaks.append(d)
	if pid in srv._peers:
		leaks.append("_peers")
	return leaks

func finish(suite: String) -> void:
	print("=== %s: %d passed, %d failed ===" % [suite, pass_n, fail_n])
	quit(1 if fail_n > 0 else 0)
