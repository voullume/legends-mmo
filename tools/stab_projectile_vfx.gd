extends "res://tools/stab/stab_base.gd"
## Soccer Projectile VFX — Step 3 snapshot contract, against the REAL server (headless, no net).
## Pins the additive presentation `key` field on projectile snapshot packets so online clients can pick
## the keyed Finesse Shot soccer ball and fall back cleanly otherwise:
##   • a keyed finesse projectile ships cls=="striker" + key=="finesse";
##   • the packet stays MINIMAL — {x,y,delay,cls,key} ONLY; no authoritative combat data (dmg/speed/tx/
##     riders/owner/team/born) leaks into presentation;
##   • a keyless / old-server / malformed projectile serializes key=="" (present, not missing) so the
##     client renders the generic fallback sphere — never an invisible projectile;
##   • interest filtering and the delay passthrough are unchanged.
## Handoff: too_add_models/projectile_vfx_previews/SOCCER_PROJECTILE_IMPLEMENTATION_HANDOFF.md (Step 3)
## Run: godot --headless --path . --script res://tools/stab_projectile_vfx.gd

const Abilities := preload("res://shared/Abilities.gd")

func _init() -> void:
	_run()

func _run() -> void:
	await boot()

	# 1) a real Striker in a live world
	var pl: Dictionary = await login("BallBoy", 1)          # stab_base default class is striker
	ok(pl["fid"] != "", "login: striker session established")
	var s = srv._session[1]
	var mapname := str(s["map"])
	var w = srv._worlds[mapname]
	var f = srv._find(str(s["fid"]))
	ok(f != null and str(f["classId"]) == "striker", "player is a striker in world '%s'" % mapname)
	f["x"] = 200.0
	f["y"] = 200.0
	var center := Vector2(float(f["x"]), float(f["y"]))

	# 2) authentic projectiles via the REAL Abilities.make_projectile (same construction site the sim uses)
	var ab := {}
	for a in GameData.CLASSES["striker"]["abilities"]:
		if str(a["key"]) == "finesse":
			ab = a
	ok(not ab.is_empty(), "finesse ability def found in GameData")
	var target = f                                          # any other fighter, else self — only its id matters
	for g in w["fighters"]:
		if str(g["id"]) != str(f["id"]):
			target = g
			break

	var near: Dictionary = Abilities.make_projectile(w, f, target, ab)
	near["x"] = center.x + 10.0
	near["y"] = center.y
	var delayed: Dictionary = Abilities.make_projectile(w, f, target, ab)
	delayed["x"] = center.x
	delayed["y"] = center.y + 10.0
	delayed["delay"] = 0.22
	var keyless: Dictionary = Abilities.make_projectile(w, f, target, ab)
	keyless["x"] = center.x - 10.0
	keyless["y"] = center.y
	keyless.erase("key")                                    # simulate an old/malformed projectile with no key
	var far: Dictionary = Abilities.make_projectile(w, f, target, ab)
	far["x"] = center.x + 9999.0                            # outside INTEREST_RADIUS
	far["y"] = center.y
	w["projectiles"] = [near, delayed, keyless, far]

	# 3) the REAL snapshot builder (pinfo empty — the projectile packet does not use it)
	var snap: Dictionary = srv._snapshot_for(w, mapname, center, {})
	var ps: Array = snap["projectiles"]
	ok(ps.size() == 3, "interest filtering: 3 in-range projectiles ship, the far one is dropped (got %d)" % ps.size())

	var p_near = null
	var p_delayed = null
	var p_keyless = null
	for p in ps:
		var k := str(p.get("key", ""))
		if k == "finesse" and absf(float(p["delay"])) < 0.001:
			p_near = p
		elif k == "finesse" and absf(float(p["delay"]) - 0.22) < 0.001:
			p_delayed = p
		elif k == "":
			p_keyless = p

	# 4) keyed finesse: identity present, packet minimal
	ok(p_near != null, "near finesse projectile is present in the snapshot")
	if p_near != null:
		ok(str(p_near.get("cls", "")) == "striker", "near finesse: cls == 'striker' (got '%s')" % str(p_near.get("cls", "")))
		ok(str(p_near.get("key", "")) == "finesse", "near finesse: key == 'finesse'")
		for banned in ["dmg", "speed", "tx", "stun", "slow", "wobble", "owner", "team", "basic", "born", "teamShieldPct"]:
			ok(not p_near.has(banned), "near finesse: authoritative field '%s' NOT leaked into presentation" % banned)
		ok(p_near.keys().size() == 5, "near finesse: packet is exactly {x,y,delay,cls,key} (got %s)" % str(p_near.keys()))

	# 5) delay passthrough
	ok(p_delayed != null and absf(float(p_delayed["delay"]) - 0.22) < 0.001, "delayed finesse: delay field passes through unchanged (0.22)")

	# 6) keyless / old-server → empty key present → client fallback (never invisible)
	ok(p_keyless != null, "keyless projectile is present (fallback path)")
	if p_keyless != null:
		ok(p_keyless.has("key"), "keyless projectile: 'key' field IS present (empty), not missing")
		ok(str(p_keyless.get("key", "x")) == "", "keyless projectile: key serializes to empty string → generic sphere")
		ok(str(p_keyless.get("cls", "")) == "striker", "keyless projectile: cls still resolves normally")

	# 7) Through Ball (second variant) — the SAME additive snapshot carries its key with no extra fields
	var tb_ab := {}
	for a in GameData.CLASSES["striker"]["abilities"]:
		if str(a["key"]) == "throughball":
			tb_ab = a
	ok(not tb_ab.is_empty(), "throughball ability def found in GameData")
	ok(tb_ab.get("slow", null) != null, "throughball still carries its slow rider in the sim def (unchanged)")
	var tb: Dictionary = Abilities.make_projectile(w, f, target, tb_ab)
	tb["x"] = center.x + 5.0
	tb["y"] = center.y - 5.0
	w["projectiles"] = [tb]
	var snap2: Dictionary = srv._snapshot_for(w, mapname, center, {})
	var ps2: Array = snap2["projectiles"]
	ok(ps2.size() == 1, "throughball ships (got %d)" % ps2.size())
	if ps2.size() == 1:
		var p_tb: Dictionary = ps2[0]
		ok(str(p_tb.get("cls", "")) == "striker", "throughball: cls == 'striker'")
		ok(str(p_tb.get("key", "")) == "throughball", "throughball: key == 'throughball' survives serialization")
		ok(p_tb.keys().size() == 5, "throughball: packet is exactly {x,y,delay,cls,key} (got %s)" % str(p_tb.keys()))
		for banned in ["dmg", "speed", "tx", "slow", "owner", "team", "born"]:
			ok(not p_tb.has(banned), "throughball: authoritative field '%s' NOT leaked (esp. the slow rider)" % banned)

	# 8) Clinical Finish (third variant) — same additive snapshot carries its key; low-HP bonus is a
	# shared-combat concern that stays SERVER-side (not in the presentation packet).
	var cl_ab := {}
	for a in GameData.CLASSES["striker"]["abilities"]:
		if str(a["key"]) == "clinical":
			cl_ab = a
	ok(not cl_ab.is_empty(), "clinical ability def found in GameData")
	var cl: Dictionary = Abilities.make_projectile(w, f, target, cl_ab)
	cl["x"] = center.x + 4.0
	cl["y"] = center.y - 4.0
	w["projectiles"] = [cl]
	var snap3: Dictionary = srv._snapshot_for(w, mapname, center, {})
	var ps3: Array = snap3["projectiles"]
	ok(ps3.size() == 1, "clinical ships (got %d)" % ps3.size())
	if ps3.size() == 1:
		var p_cl: Dictionary = ps3[0]
		ok(str(p_cl.get("cls", "")) == "striker", "clinical: cls == 'striker'")
		ok(str(p_cl.get("key", "")) == "clinical", "clinical: key == 'clinical' survives serialization")
		ok(p_cl.keys().size() == 5, "clinical: packet is exactly {x,y,delay,cls,key} (got %s)" % str(p_cl.keys()))
		for banned in ["dmg", "speed", "tx", "owner", "team", "born"]:
			ok(not p_cl.has(banned), "clinical: authoritative field '%s' NOT leaked" % banned)

	# 9) Golden Goal (ultimate) — projectile key survives the same minimal packet
	var gg_ab := {}
	for a in GameData.CLASSES["striker"]["abilities"]:
		if str(a["key"]) == "goldengoal":
			gg_ab = a
	ok(not gg_ab.is_empty(), "goldengoal ability def found in GameData")
	var gg: Dictionary = Abilities.make_projectile(w, f, target, gg_ab)
	gg["x"] = center.x + 3.0
	gg["y"] = center.y - 3.0
	w["projectiles"] = [gg]
	var snap4: Dictionary = srv._snapshot_for(w, mapname, center, {})
	if (snap4["projectiles"] as Array).size() == 1:
		var p_gg: Dictionary = (snap4["projectiles"] as Array)[0]
		ok(str(p_gg.get("cls", "")) == "striker", "goldengoal: cls == 'striker'")
		ok(str(p_gg.get("key", "")) == "goldengoal", "goldengoal: key == 'goldengoal' survives serialization")
		ok(p_gg.keys().size() == 5, "goldengoal: packet is exactly {x,y,delay,cls,key} (got %s)" % str(p_gg.keys()))

	# 10) additive CAST telegraph (Golden Goal charge) — castKey + castProg ship for a casting fighter,
	# and NO full ability def / combat riders leak into the fighter packet.
	w["projectiles"] = []
	f["casting"] = {"key": "goldengoal", "t": 0.2, "total": 0.4, "ab": gg_ab, "targetId": str(target["id"])}
	var snap5: Dictionary = srv._snapshot_for(w, mapname, center, {})
	var self_d = null
	for d in snap5["fighters"]:
		if str(d["id"]) == str(f["id"]):
			self_d = d
	ok(self_d != null, "casting striker present in the snapshot")
	if self_d != null:
		ok(str(self_d.get("castKey", "")) == "goldengoal", "cast telegraph: castKey == 'goldengoal'")
		ok(absf(float(self_d.get("castProg", -1.0)) - 0.5) < 0.001, "cast telegraph: castProg == 0.5 (0.2/0.4)")
		ok(not self_d.has("casting"), "cast telegraph: the full 'casting' object (incl. ab def / targetId) is NOT leaked")
		ok(not self_d.has("ab") and not self_d.has("targetId"), "cast telegraph: no ability def / target id leaked into the fighter packet")
	f["casting"] = null                                     # restore
	var snap6: Dictionary = srv._snapshot_for(w, mapname, center, {})
	for d in snap6["fighters"]:
		if str(d["id"]) == str(f["id"]):
			ok(not d.has("castKey") and not d.has("castProg"), "cast telegraph: absent when the fighter is NOT casting (additive)")

	finish("stab_projectile_vfx")
