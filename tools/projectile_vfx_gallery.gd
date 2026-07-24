extends Node3D
## Soccer Projectile VFX — Step 5 in-game capture harness (dev-only, NOT shipped).
## Boots the REAL Client local sandbox (player = Striker, PLAYABLE[0], vs frozen linebacker+setter bots)
## and drives it through the actual runtime paths: real finesse casts (Sim spawns real homing
## projectiles → real soccer-ball render + real impact + real damage numbers), injected concurrent
## balls, an unregistered projectile (fallback sphere), and reduced-effects mode. Captures viewport
## stills into contact sheets under too_add_models/projectile_vfx_previews/impl_previews/.
## Run WINDOWED (real GL): godot --path . --resolution 1600x900 res://tools/projectile_vfx_gallery.tscn
const ClientScript := preload("res://client/Client.gd")
const Abilities := preload("res://shared/Abilities.gd")
const GameData := preload("res://shared/GameData.gd")
const SoccerVFX := preload("res://client/vfx/projectiles/soccer_ball/soccer_projectile.tscn")
const OUT := "res://too_add_models/projectile_vfx_previews/impl_previews"
const OUT_TB := "res://too_add_models/projectile_vfx_previews/throughball_in_game"
const OUT_CL := "res://too_add_models/projectile_vfx_previews/clinical_in_game"
const OUT_GG := "res://too_add_models/projectile_vfx_previews/golden_goal_in_game"
const OUT_DR := "res://too_add_models/projectile_vfx_previews/dribble_in_game"
const OUT_YC := "res://too_add_models/projectile_vfx_previews/yellow_card_in_game"
const OUT_SO := "res://too_add_models/projectile_vfx_previews/step_over_in_game"
const OUT_BK := "res://too_add_models/projectile_vfx_previews/bicycle_kick_in_game"

var client

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	client = ClientScript.new()
	add_child(client)                                   # boots the practice sandbox (striker vs bots)
	await get_tree().process_frame
	await get_tree().process_frame
	_run()

func _cap() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _ab(key: String) -> Dictionary:
	for a in GameData.CLASSES["striker"]["abilities"]:
		if str(a["key"]) == key:
			return a
	return {}

func _finesse_ab() -> Dictionary:
	return _ab("finesse")

func _pf():
	return client._find_fighter(client._player_id)

func _bots() -> Array:
	var out := []
	for f in client._state["fighters"]:
		if int(f["team"]) == 1:
			out.append(f)
	return out

func _refill() -> void:
	for f in client._state["fighters"]:
		f["hp"] = f["maxHP"]
		f["alive"] = true

func _fire(key := "finesse") -> void:
	var pf = _pf()
	if pf != null and pf.has("cds"):
		pf["cds"][key] = 0.0                             # capture harness: never let the cd block a staged shot
	client._player.intent["ability"] = key

func _inject(px: float, py: float, key: String) -> void:
	var bots := _bots()
	if bots.is_empty():
		return
	var ab := _ab(key) if key != "" else _finesse_ab()
	var pr: Dictionary = Abilities.make_projectile(client._state, _pf(), bots[0], ab)
	pr["x"] = px
	pr["y"] = py
	if key == "":
		pr.erase("key")
	else:
		pr["key"] = key
	client._state["projectiles"].append(pr)

# tile images into a labelled grid contact sheet
func _sheet(imgs: Array, labels: Array, cols: int, path: String) -> void:
	if imgs.is_empty():
		return
	var iw: int = (imgs[0] as Image).get_width()
	var ih: int = (imgs[0] as Image).get_height()
	var sc := 0.5
	var cw := int(iw * sc)
	var ch := int(ih * sc)
	var rows := int(ceil(float(imgs.size()) / cols))
	var pad := 8
	var page := Image.create(cols * cw + (cols + 1) * pad, rows * ch + (rows + 1) * pad, false, Image.FORMAT_RGBA8)
	page.fill(Color(0.06, 0.07, 0.09, 1.0))
	var font := ThemeDB.fallback_font
	for i in range(imgs.size()):
		var im: Image = (imgs[i] as Image).duplicate()
		im.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
		if im.get_format() != Image.FORMAT_RGBA8:
			im.convert(Image.FORMAT_RGBA8)
		var cx := pad + (i % cols) * (cw + pad)
		var cy := pad + int(i / cols) * (ch + pad)
		page.blit_rect(im, Rect2i(0, 0, cw, ch), Vector2i(cx, cy))
	page.save_png(ProjectSettings.globalize_path(path))
	print("[vfx_gallery] saved ", path, "  (", imgs.size(), " frames, ", cols, "×", rows, ")")

func _stage() -> void:
	# frozen bots = stable stationary targets that still take damage / show numbers
	client._bots_frozen = true
	client._state["botsFrozen"] = true
	var pf = _pf()
	var bots := _bots()
	if pf == null or bots.is_empty():
		return
	var bx: float = float(pf["x"])
	var by: float = float(pf["y"])
	bots[0]["x"] = bx + 150.0                            # primary target: 150 sim units to +X (screen side)
	bots[0]["y"] = by
	for i in range(1, bots.size()):
		bots[i]["x"] = bx - 500.0                        # park the rest out of finesse range
		bots[i]["y"] = by - 300.0
	client._state["projectiles"].clear()
	_refill()

func _run() -> void:
	await _frames(30)                                    # let world/HUD/camera settle
	_stage()

	# --size-compare: render ONE mid-flight release→travel frame per candidate ball scale, identical
	# framing (deterministic sim), so the owner can pick the exact size. Full run otherwise.
	if "--size-compare" in OS.get_cmdline_user_args():
		await _size_compare()
		print("[vfx_gallery] DONE (size-compare)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--tuner-smoke" in OS.get_cmdline_user_args():
		await _tuner_smoke()
		await _frames(2)
		get_tree().quit(0)
		return

	if "--registry-check" in OS.get_cmdline_user_args():
		_registry_check()
		await _frames(2)
		get_tree().quit(0)
		return

	if "--throughball" in OS.get_cmdline_user_args():
		await _throughball()
		print("[vfx_gallery] DONE (throughball)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--clinical" in OS.get_cmdline_user_args():
		await _clinical()
		print("[vfx_gallery] DONE (clinical)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--goldengoal" in OS.get_cmdline_user_args():
		await _goldengoal()
		print("[vfx_gallery] DONE (goldengoal)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--dribble" in OS.get_cmdline_user_args():
		await _dribble()
		print("[vfx_gallery] DONE (dribble)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--yellowcard" in OS.get_cmdline_user_args():
		await _yellowcard()
		print("[vfx_gallery] DONE (yellowcard)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--stepover" in OS.get_cmdline_user_args():
		await _stepover()
		print("[vfx_gallery] DONE (stepover)")
		await _frames(2)
		get_tree().quit(0)
		return

	if "--bicyclekick" in OS.get_cmdline_user_args():
		await _bicyclekick()
		print("[vfx_gallery] DONE (bicyclekick)")
		await _frames(2)
		get_tree().quit(0)
		return

	# ── 1. Normal camera distance: release → travel ─────────────────────────────────────────────
	_refill()
	client._state["projectiles"].clear()
	_fire()
	var strip1 := []
	for i in range(14):
		await _frames(1)
		strip1.append(await _cap())
	_sheet(strip1, [], 5, OUT + "/01_release_to_travel.png")

	# ── 2. Impact: contact + damage number ──────────────────────────────────────────────────────
	# fire and capture a dense strip spanning the impact frames (ring + floating number)
	_stage()
	_fire()
	var strip2 := []
	for i in range(20):
		await _frames(1)
		strip2.append(await _cap())
	_sheet(strip2, [], 5, OUT + "/02_impact.png")

	# ── 3. Concurrent fire: many balls at once (pool/material isolation) ─────────────────────────
	_stage()
	var bx: float = float(_pf()["x"])
	var by: float = float(_pf()["y"])
	for off in [20.0, 55.0, 90.0, 125.0]:
		_inject(bx + off, by + (off - 70.0) * 0.15, "finesse")
	_fire()
	var conc := []
	for i in range(3):
		await _frames(2)
		conc.append(await _cap())
	_sheet(conc, [], 3, OUT + "/03_concurrent.png")

	# ── 4. Fallback: an UNREGISTERED striker projectile stays the generic sphere next to the ball ─
	_stage()
	bx = float(_pf()["x"])
	by = float(_pf()["y"])
	_inject(bx + 60.0, by - 18.0, "finesse")             # registered → soccer ball
	_inject(bx + 60.0, by + 18.0, "throughball")         # unregistered → generic fallback sphere
	var fb := []
	for i in range(3):
		await _frames(2)
		fb.append(await _cap())
	_sheet(fb, [], 3, OUT + "/04_fallback_sphere_vs_ball.png")

	# ── 5. Reduced effects: ball stays visible, trail/glow off, impact damped ────────────────────
	client.reduce_fx = true
	_stage()
	_fire()
	var red := []
	for i in range(16):
		await _frames(1)
		red.append(await _cap())
	_sheet(red, [], 4, OUT + "/05_reduced_effects.png")
	client.reduce_fx = false

	# ── full-resolution hero frames (true quality, not downscaled) ───────────────────────────────
	await _hero()

	# ── 6. Close inspection: the real ball asset, spin + panels, at close range ──────────────────
	await _close_up()

	print("[vfx_gallery] DONE")
	await _frames(2)
	get_tree().quit(0)

# Smoke-test the dev live tuner: a slider change updates the runtime tune, the ball ALREADY in flight,
# and persists — without touching gameplay.
func _tuner_smoke() -> void:
	var pass_n := 0
	var fail_n := 0
	_fire()
	await _frames(3)                                     # spawn a ball → pool node exists
	var fin_tune: Dictionary = client._vfx_tune["striker/finesse"]
	if abs(float(fin_tune["scale"]) - 0.34) < 0.001: pass_n += 1
	else: fail_n += 1; print("  FAIL default finesse scale = %s (want 0.34)" % fin_tune["scale"])
	client._toggle_vfx_tuner()                           # create the panel (as F3 would)
	if client._vfx_tuner != null: pass_n += 1
	else: fail_n += 1; print("  FAIL tuner not created")
	# select FINESSE explicitly (default is now the first-sorted style), then drag the Ball-size slider
	client._vfx_tuner._on_style_selected(int(client._vfx_tuner._styles.find("striker/finesse")))
	client._vfx_tuner._on_changed(0.30, "scale")
	if abs(float(client._vfx_tune["striker/finesse"]["scale"]) - 0.30) < 0.001: pass_n += 1
	else: fail_n += 1; print("  FAIL projectile tune not updated")
	var live_ok := false
	for n in client._vfx_pools.get("striker/finesse", []):
		if abs(float(n._scale) - 0.30) < 0.001: live_ok = true
	if live_ok: pass_n += 1
	else: fail_n += 1; print("  FAIL live ball not reconfigured")
	client._vfx_tuner._on_changed(0.60, "impact_scale")  # impact param path
	client._vfx_tuner._on_changed(0.20, "trail_b")       # trail-colour param path
	# DASH kind: select dribble, confirm its slider set + a dash param applies
	client._vfx_tuner._on_style_selected(int(client._vfx_tuner._styles.find("striker/dribble")))
	if client._vfx_tuner._kind_of("striker/dribble") == "dash" and client._vfx_tuner._sliders.has("ball_scale"): pass_n += 1
	else: fail_n += 1; print("  FAIL dribble did not switch to the dash slider set")
	client._vfx_tuner._on_changed(0.2, "ball_scale")
	if abs(float(client._vfx_tune["striker/dribble"]["ball_scale"]) - 0.2) < 0.001: pass_n += 1
	else: fail_n += 1; print("  FAIL dash tune not updated")
	# MELEE kind: select yellowcard, confirm its slider set + a melee param applies
	client._vfx_tuner._on_style_selected(int(client._vfx_tuner._styles.find("striker/yellowcard")))
	if client._vfx_tuner._kind_of("striker/yellowcard") == "melee" and client._vfx_tuner._sliders.has("card_scale"): pass_n += 1
	else: fail_n += 1; print("  FAIL yellowcard did not switch to the melee slider set")
	client._vfx_tuner._on_changed(1.5, "card_scale")
	if abs(float(client._vfx_tune["striker/yellowcard"]["card_scale"]) - 1.5) < 0.001: pass_n += 1
	else: fail_n += 1; print("  FAIL melee tune not updated")
	# clean up: this smoke test drove the REAL tuner, which persists to settings — erase what it wrote
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		for _s in ["vfx_striker_finesse", "vfx_striker_dribble", "vfx_striker_yellowcard"]:
			if cfg.has_section(_s): cfg.erase_section(_s)
		cfg.save("user://settings.cfg")
	print("[vfx_gallery] TUNER SMOKE: %d passed, %d failed" % [pass_n, fail_n])

# Client-side registry resolution: _proj_vfx_key must select the right style by COMBINED class/key, so
# another class's same-named key never borrows Striker art, and unregistered keys fall back.
func _registry_check() -> void:
	var p := 0
	var f := 0
	var cases := [
		[{"cls": "striker", "key": "throughball"}, "striker/throughball"],
		[{"cls": "striker", "key": "finesse"}, "striker/finesse"],
		[{"cls": "striker", "key": "clinical"}, "striker/clinical"],
		[{"cls": "striker", "key": "goldengoal"}, "striker/goldengoal"],
		[{"cls": "goalkeeper", "key": "goldengoal"}, ""],     # another class, same key → NOT striker art
		[{"cls": "striker", "key": "bicyclekick"}, ""],       # a non-projectile striker ability → fallback
		[{"cls": "striker", "key": ""}, ""],                  # empty key → fallback
		[{"key": "finesse"}, ""],                             # no class + no owner → fallback
	]
	for c in cases:
		var got := str(client._proj_vfx_key(c[0]))
		if got == str(c[1]):
			p += 1
		else:
			f += 1
			print("  FAIL _proj_vfx_key(%s) = '%s' (want '%s')" % [c[0], got, str(c[1])])
	print("[vfx_gallery] REGISTRY CHECK: %d passed, %d failed" % [p, f])

# Bicycle Kick capture set (addendum §"Required in-game captures") → bicycle_kick_in_game/. Bicycle Kick
# is a LEAP ATTACK: fire it and the player auto-targets the nearest enemy (a staged bot), the sim teleports
# adjacent + deals one hit the same tick, and the client plays the render-only arc + backward pitch (leap)
# plus the confirmed single-target impact. Camera follows the (leaping) player; we use a wide 3/4 shot.
func _bk_shot(dist_units: float, reduce: bool, frames: int, sheet: String, hero: String) -> void:
	_stage()                                             # bots frozen; bot[0] re-anchored near the player
	var pf = _pf()
	var bots := _bots()
	if pf == null or bots.is_empty():
		return
	bots[0]["x"] = float(pf["x"]) + dist_units           # the leap target: dist_units to +X
	bots[0]["y"] = float(pf["y"])
	var save_dist: float = client._dist
	var save_pitch: float = client._pitch
	var save_yaw: float = client._yaw
	client._dist = 13.0
	client._pitch = 0.6
	client._yaw = -0.4
	client.reduce_fx = reduce
	await _frames(40)                                    # settle: clear prior-shot floaters + seed the leap edge-tracker
	pf["cds"]["bicyclekick"] = 0.0
	client._player.intent["ability"] = "bicyclekick"
	var strip := []
	for i in range(frames):
		await _frames(2)                                # leap ~0.4s + landing/impact ~0.3s → ~0.8s over ~24 samples
		strip.append(await _cap())
	_sheet(strip, [], 6, sheet)
	if hero != "" and strip.size() > 5:
		(strip[5] as Image).save_png(ProjectSettings.globalize_path(hero))   # mid-arc (airborne rotation + contact)
	client.reduce_fx = false
	client._dist = save_dist
	client._pitch = save_pitch
	client._yaw = save_yaw

func _bicyclekick() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_BK))
	# 1-5. launch → airborne rotation → foot/ball contact → confirmed impact → landing/recovery (mid-range)
	await _bk_shot(150.0, false, 24, OUT_BK + "/01_leap_contact_impact_landing.png", OUT_BK + "/hero_airborne.png")
	# 6. long leap near max accepted range
	await _bk_shot(195.0, false, 24, OUT_BK + "/06_long_leap.png", "")
	# 7. out of range (beyond dist+30) — the cast is rejected: NO leap, NO impact, no false effect
	await _bk_shot(400.0, false, 20, OUT_BK + "/07_out_of_range_no_effect.png", "")
	# 9. reduced effects (ribbon → one segment, no cyan impact ring, no landing ring)
	await _bk_shot(150.0, true, 24, OUT_BK + "/09_reduced_effects.png", "")
	# 10. repeated use — two leaps proving model/pool reset (no stuck pivot/pitch)
	_stage()
	var pf = _pf()
	var bots := _bots()
	var save_dist: float = client._dist
	var save_pitch: float = client._pitch
	var save_yaw: float = client._yaw
	client._dist = 13.0
	client._pitch = 0.6
	client._yaw = -0.4
	bots[0]["x"] = float(pf["x"]) + 150.0
	bots[0]["y"] = float(pf["y"])
	await _frames(40)
	pf["cds"]["bicyclekick"] = 0.0
	client._player.intent["ability"] = "bicyclekick"
	var rep := []
	for i in range(40):
		await _frames(2)
		if i == 20:                                      # re-target ahead of the (now moved) player and leap again
			bots[0]["x"] = float(pf["x"]) + 150.0
			bots[0]["y"] = float(pf["y"])
			pf["cds"]["bicyclekick"] = 0.0
			client._player.intent["ability"] = "bicyclekick"
		rep.append(await _cap())
	_sheet(rep, [], 7, OUT_BK + "/10_repeated_reset.png")
	client._dist = save_dist
	client._pitch = save_pitch
	client._yaw = save_yaw
	print("[vfx_gallery] bicyclekick captures saved to ", OUT_BK)

# Step Over capture set (addendum §"Required in-game captures") → step_over_in_game/. Step Over is a
# SELF-BUFF: fire it (no target) — the client detects the cooldown edge and plays the feint then the
# ms/dr aura. Camera follows the (stationary) caster, so we zoom in.
func _stepover_shot(move: bool, frames: int, sheet: String, hero: String) -> void:
	_stage()
	var pf = _pf()
	# shallow 3/4 view (default is a steep overhead that flattens the ground chevrons under the generic
	# buff dome); the caster faces +X so the forward cyan chevrons and upright gold DR arc read clearly.
	var save_dist: float = client._dist
	var save_pitch: float = client._pitch
	var save_yaw: float = client._yaw
	client._dist = 9.0
	client._pitch = 0.60
	client._yaw = -0.55
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["stepover"] = 0.0
	client._player.intent["ability"] = "stepover"
	var strip := []
	# feint (~0.45 s) → 2 s ms/dr aura → fade: sample every ~4 process frames so a ~30-tile sheet spans
	# the whole buff instead of just the first half-second.
	for i in range(frames):
		await _frames(4)
		if move:
			pf["x"] = float(pf["x"]) + 5.0               # nudge the body so the aura is seen following it
		strip.append(await _cap())
	_sheet(strip, [], 6, sheet)
	if hero != "" and strip.size() > 8:
		(strip[8] as Image).save_png(ProjectSettings.globalize_path(hero))   # deep in the aura (feint done)
	client._dist = save_dist
	client._pitch = save_pitch
	client._yaw = save_yaw

func _stepover() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_SO))
	# 1-4+6. feint → ball removal + activation ring → cyan speed chevrons + gold DR arc, standing, into fade
	await _stepover_shot(false, 30, OUT_SO + "/01_feint_activation_aura.png", OUT_SO + "/hero_aura.png")
	# 5. aura following normal movement
	await _stepover_shot(true, 26, OUT_SO + "/05_aura_moving.png", "")
	# 9. reduced effects (ball + one foot pass, one chevron, one faint arc)
	client.reduce_fx = true
	await _stepover_shot(false, 26, OUT_SO + "/09_reduced_effects.png", "")
	client.reduce_fx = false
	# 10. repeated use — two activations, clean reset
	_stage()
	var pf = _pf()
	var save_dist: float = client._dist
	var save_pitch: float = client._pitch
	var save_yaw: float = client._yaw
	client._dist = 9.0
	client._pitch = 0.60
	client._yaw = -0.55
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["stepover"] = 0.0
	client._player.intent["ability"] = "stepover"
	var rep := []
	for i in range(34):
		await _frames(4)
		if i == 16:                                      # re-cast mid-buff → clean reset, no double feint replay
			pf["cds"]["stepover"] = 0.0
			client._player.intent["ability"] = "stepover"
		rep.append(await _cap())
	_sheet(rep, [], 6, OUT_SO + "/10_repeated_reset.png")
	client._dist = save_dist
	client._pitch = save_pitch
	client._yaw = save_yaw
	print("[vfx_gallery] stepover captures saved to ", OUT_SO)

# Yellow Card capture set (addendum §"Required in-game captures") → yellow_card_in_game/. Yellow Card is a
# MELEE stun (range 64): place a bot in/out of range, fire it; the client correlates the cast edge + the
# confirmed damage event and plays the TARGET cue (card + contact + stun orbit following st.stn).
func _yc_shot(hp_frac: float, dist: float, frames: int, sheet: String, hero: String) -> void:
	_stage()
	var pf = _pf()
	var bot = _bots()[0]
	bot["x"] = float(pf["x"]) + dist                     # dist < 64 = in melee range; > 64 = a whiff
	bot["y"] = float(pf["y"])
	bot["hp"] = float(bot["maxHP"]) * hp_frac
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["yellowcard"] = 0.0
	client._player.intent["ability"] = "yellowcard"
	var strip := []
	for i in range(frames):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 5, sheet)
	if hero != "" and strip.size() > 4:
		(strip[4] as Image).save_png(ProjectSettings.globalize_path(hero))

# Zoom the (player-following) game camera in on a hit at close range so the raised card + stun-star orbit
# read — the default view sits far. The camera follows the stationary caster, keeping the nearby target framed.
func _yc_fixed_cam(sheet: String, hero: String) -> void:
	_stage()
	var pf = _pf()
	var bot = _bots()[0]
	bot["x"] = float(pf["x"]) + 40.0
	bot["y"] = float(pf["y"])
	var save_dist: float = client._dist
	client._dist = 11.0                                  # zoom in (game camera follows the player)
	await _frames(3)                                     # settle the zoom + the target holder
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["yellowcard"] = 0.0
	client._player.intent["ability"] = "yellowcard"
	var strip := []
	for i in range(22):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 5, sheet)
	if hero != "" and strip.size() > 8:
		(strip[8] as Image).save_png(ProjectSettings.globalize_path(hero))
	client._dist = save_dist

func _yellowcard() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_YC))
	# 0. fixed-camera showcase (card + stun orbit read clearly)
	await _yc_fixed_cam(OUT_YC + "/00_fixed_cam_card_stun.png", OUT_YC + "/hero_card.png")
	# 1-4. valid hit at close range → foul contact, whistle+card raise, stun orbit, fade near expiry (1 s stun)
	await _yc_shot(1.0, 40.0, 26, OUT_YC + "/01_hit_card_stun_sequence.png", "")
	# 5. killing hit (30 dmg kills a low-HP target) → only the contact flash, NO lingering card
	await _yc_shot(0.02, 40.0, 14, OUT_YC + "/05_killing_hit_no_card.png", "")
	# 6. out-of-range attempt (bot beyond 64) → the attack whiffs, NO target cue
	await _yc_shot(1.0, 200.0, 12, OUT_YC + "/06_out_of_range_no_cue.png", "")
	# 8. reduced effects (one flash + still card + one star, no whistle)
	client.reduce_fx = true
	await _yc_shot(1.0, 40.0, 22, OUT_YC + "/08_reduced_effects.png", "")
	client.reduce_fx = false
	# 9. repeated use — two hits, clean pooled reset
	_stage()
	var pf = _pf()
	var bot = _bots()[0]
	bot["x"] = float(pf["x"]) + 40.0
	bot["y"] = float(pf["y"])
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["yellowcard"] = 0.0
	client._player.intent["ability"] = "yellowcard"
	var rep := []
	for i in range(26):
		await _frames(1)
		if i == 14:
			bot["hp"] = float(bot["maxHP"])
			pf["cds"]["yellowcard"] = 0.0
			client._player.intent["ability"] = "yellowcard"
		rep.append(await _cap())
	_sheet(rep, [], 6, OUT_YC + "/09_repeated_reset.png")
	print("[vfx_gallery] yellowcard captures saved to ", OUT_YC)

# Dribble capture set (addendum §"Required in-game captures") → dribble_in_game/. Dribble is a DASH: we
# set the fighter heading (hx/hy) — no keyboard in the harness — then fire it; the client detects the
# `dribble` cooldown edge and the DribbleVFX follows the rendered body.
func _dribble_shot(dir: Vector2, sheet: String, hero: String) -> void:
	_stage()
	var pf = _pf()
	var d := dir.normalized()
	pf["hx"] = d.x
	pf["hy"] = d.y
	pf["facing"] = 1 if d.x >= 0 else -1
	pf["cds"]["dribble"] = 0.0
	client._player.intent["ability"] = "dribble"
	var strip := []
	for i in range(14):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 5, sheet)
	if hero != "" and strip.size() > 3:
		(strip[3] as Image).save_png(ProjectSettings.globalize_path(hero))

# The game camera follows the local player, so a self-dash stays centred and the traverse is invisible.
# A FIXED side camera shows the dash crossing — ball following the body, touches, speed-marks, arrival ring
# (this is also how a REMOTE/AI Striker's Dribble reads on your screen).
func _dribble_fixed_cam(sheet: String, hero: String) -> void:
	_stage()
	var pf = _pf()
	var pid = client._player_id
	await _frames(2)
	var start_w: Vector3 = (client._nodes[pid]["holder"] as Node3D).position
	var mid := start_w + Vector3(4.0, 0.0, 0.0)         # +X dash path midpoint (155 sim ≈ 7.75 world)
	var cam := Camera3D.new()
	cam.fov = 52.0
	add_child(cam)
	cam.global_position = mid + Vector3(0.0, 7.0, 8.5)
	cam.look_at(mid + Vector3(0.0, 0.4, 0.0), Vector3.UP)
	cam.current = true
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["dribble"] = 0.0
	client._player.intent["ability"] = "dribble"
	var strip := []
	for i in range(16):
		cam.current = true                               # hold the fixed view against the client's camera update
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 4, sheet)
	if hero != "" and strip.size() > 4:
		(strip[4] as Image).save_png(ProjectSettings.globalize_path(hero))
	cam.queue_free()
	if is_instance_valid(client) and client._cam != null:
		client._cam.current = true

func _dribble() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DR))
	# 0. fixed-camera showcase (dash traverse reads clearly)
	await _dribble_fixed_cam(OUT_DR + "/00_fixed_cam_dash.png", OUT_DR + "/hero_dash.png")
	# 1. full horizontal dash  + 2. diagonal (game camera — follows the player)
	await _dribble_shot(Vector2(1, 0), OUT_DR + "/01_dash_horizontal.png", "")
	await _dribble_shot(Vector2(0.8, 0.7), OUT_DR + "/02_dash_diagonal.png", "")
	# 5. arena-edge shortened dash (near the +X edge, dashing into it → clamped short)
	_stage()
	var pf = _pf()
	pf["x"] = float(GameData.ARENA_W) - 60.0
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["dribble"] = 0.0
	client._player.intent["ability"] = "dribble"
	var edge := []
	for i in range(14):
		await _frames(1)
		edge.append(await _cap())
	_sheet(edge, [], 5, OUT_DR + "/05_arena_edge_short.png")
	# 6. dribble close to an enemy — NO impact/hit effect on the bot
	_stage()
	pf = _pf()
	var bots := _bots()
	bots[0]["x"] = float(pf["x"]) + 120.0
	bots[0]["y"] = float(pf["y"])
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["dribble"] = 0.0
	client._player.intent["ability"] = "dribble"
	var near := []
	for i in range(14):
		await _frames(1)
		near.append(await _cap())
	_sheet(near, [], 5, OUT_DR + "/06_near_enemy_no_impact.png")
	# 8. reduced effects
	client.reduce_fx = true
	await _dribble_shot(Vector2(1, 0), OUT_DR + "/08_reduced_effects.png", "")
	client.reduce_fx = false
	# 9. repeated use — dash out, then back, proving clean pooled reset
	_stage()
	pf = _pf()
	pf["hx"] = 1.0
	pf["hy"] = 0.0
	pf["facing"] = 1
	pf["cds"]["dribble"] = 0.0
	client._player.intent["ability"] = "dribble"
	var rep := []
	for i in range(20):
		await _frames(1)
		if i == 11:
			pf["cds"]["dribble"] = 0.0
			pf["hx"] = -1.0
			pf["facing"] = -1
			client._player.intent["ability"] = "dribble"
		rep.append(await _cap())
	_sheet(rep, [], 5, OUT_DR + "/09_repeated_reset.png")
	print("[vfx_gallery] dribble captures saved to ", OUT_DR)

# Golden Goal capture set (addendum §"Required in-game captures") → golden_goal_in_game/.
# Golden Goal is a CASTED ult (0.4 s), so _fire() starts a real cast → charge shows → projectile spawns.
func _goldengoal() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_GG))
	# 1. full charge → release → travel
	_stage()
	_fire("goldengoal")
	var strip := []
	for i in range(24):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 6, OUT_GG + "/01_charge_release_travel.png")
	# 2. stun-interrupted charge → NO projectile spawns, charge clears. The real 0.4 s cast completes inside
	# a single slow capture frame, so we DRIVE the authoritative cast state directly (the client charge is
	# purely a function of it): hold a mid-cast state → the charge renders; then clear the cast exactly as a
	# stun does (Sim sets casting=null, spawns nothing) → the charge must vanish with no ball.
	_stage()
	var pfc = _pf()
	var gg := _ab("goldengoal")
	var tgt := str(_bots()[0]["id"])
	var interrupt := []
	for i in range(5):                                   # charge building (re-held each frame so it can't complete)
		pfc["casting"] = {"key": "goldengoal", "t": 0.12 + i * 0.05, "total": 0.4, "ab": gg, "targetId": tgt}
		client._state["projectiles"].clear()
		await _frames(1)
		interrupt.append(await _cap())
	for i in range(5):                                   # INTERRUPT: cast cleared as a stun would → no projectile
		pfc["casting"] = null
		pfc["stun"] = 1.0
		client._state["projectiles"].clear()
		await _frames(1)
		interrupt.append(await _cap())
	_sheet(interrupt, [], 5, OUT_GG + "/02_stun_interrupt.png")
	# 4. mid-flight gold ball + trail hero (after the 0.4 s cast)
	_stage()
	_fire("goldengoal")
	for i in range(20):
		await _frames(1)
	(await _cap()).save_png(ProjectSettings.globalize_path(OUT_GG + "/hero_travel.png"))
	# 5. confirmed NON-killing impact (full-HP target survives 255 dmg) — no reward pulse
	await _gg_impact(1.0, OUT_GG + "/05_impact_nonkill.png", OUT_GG + "/hero_impact.png")
	# 6. confirmed KILLING blow → caster-side reward pulse (low-HP target dies to Golden Goal)
	await _gg_impact(0.2, OUT_GG + "/06_kill_reward.png", OUT_GG + "/hero_reward.png")
	# 8. reduced effects (charge + travel + impact)
	client.reduce_fx = true
	_stage()
	_fire("goldengoal")
	var red := []
	for i in range(24):
		await _frames(1)
		red.append(await _cap())
	_sheet(red, [], 6, OUT_GG + "/08_reduced_effects.png")
	client.reduce_fx = false
	print("[vfx_gallery] goldengoal captures saved to ", OUT_GG)

func _gg_impact(hp_frac: float, sheet_path: String, hero_path: String) -> void:
	_stage()
	var bot = _bots()[0]
	bot["hp"] = float(bot["maxHP"]) * hp_frac
	var hp0 := float(bot["hp"])
	_fire("goldengoal")
	var caught := -1
	var imp := []
	for i in range(72):                                  # wait through the 0.4 s cast + flight + impact
		await _frames(1)
		if caught < 0 and float(bot["hp"]) < hp0 - 0.5:
			caught = 0
		if caught >= 0 and caught < 10:
			imp.append(await _cap())
			caught += 1
		elif caught >= 10:
			break
	_sheet(imp, [], 5, sheet_path)
	if hero_path != "" and imp.size() > 2:
		(imp[2] as Image).save_png(ProjectSettings.globalize_path(hero_path))

# Clinical Finish capture set (addendum §"Required in-game captures") → clinical_in_game/.
func _clinical() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_CL))
	# 1+2. release at gameplay distance + the compression cue near the kick (dense early frames)
	_stage()
	_fire("clinical")
	var strip := []
	for i in range(14):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 5, OUT_CL + "/01_release_and_travel.png")
	# 3. firm red-orange travel hero (mid-flight, full-res)
	_stage()
	_fire("clinical")
	await _frames(5)
	(await _cap()).save_png(ProjectSettings.globalize_path(OUT_CL + "/hero_travel.png"))
	# 4. confirmed impact on a target ABOVE 40% HP (precision impact)
	await _clinical_impact(1.0, OUT_CL + "/04_impact_above40.png", OUT_CL + "/hero_impact.png")
	# 5. confirmed impact on a target BELOW 40% HP (low-HP bonus → bigger number, SAME impact)
	await _clinical_impact(0.30, OUT_CL + "/05_impact_below40.png", "")
	# 6. comparison: finesse (warm) vs through ball (amber+cyan) vs clinical (red-orange)
	_stage()
	var bx: float = float(_pf()["x"])
	var by: float = float(_pf()["y"])
	_inject(bx + 55.0, by - 30.0, "finesse")
	_inject(bx + 55.0, by, "throughball")
	_inject(bx + 55.0, by + 30.0, "clinical")
	var cmp := []
	for i in range(3):
		await _frames(2)
		cmp.append(await _cap())
	_sheet(cmp, [], 3, OUT_CL + "/06_three_way_compare.png")
	# 7. mixed / concurrent pool stress
	_stage()
	bx = float(_pf()["x"])
	by = float(_pf()["y"])
	for off in [20.0, 60.0, 100.0]:
		_inject(bx + off, by - 15.0, "clinical")
		_inject(bx + off, by + 15.0, "finesse")
	var mix := []
	for i in range(3):
		await _frames(2)
		mix.append(await _cap())
	_sheet(mix, [], 3, OUT_CL + "/07_mixed_concurrent.png")
	# 8. reduced effects
	client.reduce_fx = true
	_stage()
	_fire("clinical")
	var red := []
	for i in range(16):
		await _frames(1)
		red.append(await _cap())
	_sheet(red, [], 4, OUT_CL + "/08_reduced_effects.png")
	client.reduce_fx = false
	print("[vfx_gallery] clinical captures saved to ", OUT_CL)

func _clinical_impact(hp_frac: float, sheet_path: String, hero_path: String) -> void:
	_stage()
	var bot = _bots()[0]
	bot["hp"] = float(bot["maxHP"]) * hp_frac             # set pre-hit HP band (0.30 → clinical low-HP bonus applies)
	var hp0 := float(bot["hp"])
	_fire("clinical")
	var caught := -1
	var imp := []
	for i in range(52):
		await _frames(1)
		if caught < 0 and float(bot["hp"]) < hp0 - 0.5:
			caught = 0
		if caught >= 0 and caught < 8:
			imp.append(await _cap())
			caught += 1
		elif caught >= 8:
			break
	_sheet(imp, [], 4, sheet_path)
	if hero_path != "" and imp.size() > 1:
		(imp[1] as Image).save_png(ProjectSettings.globalize_path(hero_path))

# Through Ball capture set (addendum §"Required in-game approval captures") → throughball_in_game/.
func _throughball() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_TB))
	# 1. normal camera distance: release → driven travel
	_stage()
	_fire("throughball")
	var strip := []
	for i in range(14):
		await _frames(1)
		strip.append(await _cap())
	_sheet(strip, [], 5, OUT_TB + "/01_release_to_travel.png")
	# 3. blue-white trail hero (mid-flight, full-res)
	_stage()
	_fire("throughball")
	await _frames(6)
	(await _cap()).save_png(ProjectSettings.globalize_path(OUT_TB + "/hero_travel.png"))
	# 2. finesse vs through ball side by side (warm ball+trail vs blue ball+trail)
	_stage()
	var bx: float = float(_pf()["x"])
	var by: float = float(_pf()["y"])
	_inject(bx + 55.0, by - 22.0, "finesse")
	_inject(bx + 55.0, by + 22.0, "throughball")
	var sbs := []
	for i in range(3):
		await _frames(2)
		sbs.append(await _cap())
	_sheet(sbs, [], 3, OUT_TB + "/02_finesse_vs_throughball.png")
	# 4+5. authoritative impact (slow ring + drag ticks) + the cue fading while the real slow persists
	_stage()
	var bot = _bots()[0]
	var hp0 := float(bot["hp"])
	_fire("throughball")
	var caught := -1
	var imp := []
	for i in range(52):
		await _frames(1)
		if caught < 0 and float(bot["hp"]) < hp0 - 0.5:
			caught = 0
		if caught >= 0 and caught < 10:
			imp.append(await _cap())
			caught += 1
		elif caught >= 10:
			break
	_sheet(imp, [], 5, OUT_TB + "/04_impact_slow_cue_fade.png")
	if imp.size() > 1:
		(imp[1] as Image).save_png(ProjectSettings.globalize_path(OUT_TB + "/hero_impact.png"))
	# 6. several simultaneous / mixed soccer projectiles
	_stage()
	bx = float(_pf()["x"])
	by = float(_pf()["y"])
	for off in [20.0, 60.0, 100.0]:
		_inject(bx + off, by - 15.0, "finesse")
		_inject(bx + off, by + 15.0, "throughball")
	var mix := []
	for i in range(3):
		await _frames(2)
		mix.append(await _cap())
	_sheet(mix, [], 3, OUT_TB + "/06_mixed_concurrent.png")
	# 7. reduced effects
	client.reduce_fx = true
	_stage()
	_fire("throughball")
	var red := []
	for i in range(16):
		await _frames(1)
		red.append(await _cap())
	_sheet(red, [], 4, OUT_TB + "/07_reduced_effects.png")
	client.reduce_fx = false
	print("[vfx_gallery] throughball captures saved to ", OUT_TB)

# Size verification: same deterministic travel, one mid-flight frame per candidate ball scale.
func _size_compare() -> void:
	var scales := [0.60, 0.50, 0.42, 0.34]               # 0.60 = current; three smaller candidates
	var imgs := []
	for sc in scales:
		_stage()
		client._state["projectiles"].clear()
		_fire()
		await _frames(1)                                 # pool node created + reset (at the default scale)
		await _frames(6)                                 # consistent mid-flight point
		for n in client._vfx_pools.get("striker/finesse", []):
			n.configure({"scale": sc, "spin_speed": 12.0})   # override to this candidate scale
		await _frames(1)
		var img := await _cap()
		img.save_png(ProjectSettings.globalize_path(OUT + "/size_%02d.png" % int(round(sc * 100.0))))
		imgs.append(img)
		print("[vfx_gallery] saved size_%02d.png (scale %.2f)" % [int(round(sc * 100.0)), sc])
	_sheet(imgs, [], 2, OUT + "/size_compare.png")       # 2×2: 0.60 | 0.50 / 0.42 | 0.34

# Full-resolution single frames — a clean travel hero and an HP-drop-triggered impact hero (ring +
# damage number), so the owner sees true quality instead of downscaled contact-sheet cells.
func _hero() -> void:
	_stage()
	_fire()
	await _frames(6)                                     # ball mid-flight
	(await _cap()).save_png(ProjectSettings.globalize_path(OUT + "/hero_travel.png"))
	print("[vfx_gallery] saved ", OUT, "/hero_travel.png")
	# impact hero: fire, watch the target HP, then grab the frames right after contact (ring lifetime)
	_stage()
	var bot = _bots()[0]
	var hp0 := float(bot["hp"])
	_fire()
	var caught := -1
	for i in range(48):
		await _frames(1)
		if caught < 0 and float(bot["hp"]) < hp0 - 0.5:
			caught = 0
		if caught >= 0 and caught < 6:
			(await _cap()).save_png(ProjectSettings.globalize_path(OUT + "/hero_impact_%d.png" % caught))
			caught += 1
		elif caught >= 6:
			break
	print("[vfx_gallery] saved ", OUT, "/hero_impact_0..5.png (impact ring + damage number)")

# A dedicated close camera on a stationary real soccer-ball VFX node — pure material/spin/panel read.
func _close_up() -> void:
	if is_instance_valid(client):
		client.queue_free()                              # drop the whole sandbox → clean background for the material read
		client = null
	await _frames(2)
	var vfx := SoccerVFX.instantiate()
	add_child(vfx)
	await get_tree().process_frame
	vfx.configure({"scale": 1.0, "spin_speed": 3.5})
	vfx.reset_for_spawn(false)
	vfx.global_position = Vector3(0, 3, 0)
	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.global_position = Vector3(1.4, 3.3, 2.6)
	cam.look_at(Vector3(0, 3, 0), Vector3.UP)
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -42, 0)
	add_child(sun)
	var shots := []
	for i in range(6):
		vfx.set_snapshot_position(Vector3(0, 3, 0), 0.05)   # hold in place; spin still animates
		await _frames(6)
		shots.append(await _cap())
	_sheet(shots, [], 3, OUT + "/06_close_up_spin.png")
	if shots.size() > 2:
		(shots[2] as Image).save_png(ProjectSettings.globalize_path(OUT + "/hero_close_up.png"))
		print("[vfx_gallery] saved ", OUT, "/hero_close_up.png")
