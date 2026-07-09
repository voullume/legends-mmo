extends Node
## CLIENT — Phase 1: a single, local, player-controlled fighter in a practice arena.
##
## Architecture: the shared deterministic engine (shared/Sim.gd) is authoritative and ticks
## the WHOLE world at 30 Hz. The player's fighter is driven through the Sim's controlled
## seam (Player.gd → intent → Sim._player_step); sparring bots run the ported team AI. The
## client only RENDERS sim state (character kit + animations + FX, ported from the prototype
## ~/legends-arena/scripts/Arena.gd) and feeds input. No win/lose — dead fighters respawn.
##
## Controls: WASD move (camera-relative) · 1-5 abilities (1=basic … 5=ult) · LMB basic
##           RMB-drag orbit camera · wheel zoom · C cycle class · R reset arena

const GameData := preload("res://shared/GameData.gd")
const Sim := preload("res://shared/Sim.gd")
const Geom := preload("res://shared/Geom.gd")
const World := preload("res://shared/World.gd")
const PlayerCtl := preload("res://client/Player.gd")

# --- world scale / look ---
const SCALE := 0.05                       # sim units → world units (960×540 → 48×27)
const MESHY_SCALE := 1.9
const MESHY_FLIP := false
const CHAR_Y := 0.0
# In-hand sport prop (the Batter's bat) attached to the Meshy "RightHand" bone, so it follows the swing.
const PROP_SCALE := 1.0                     # bump if the bat looks too big/small in hand
const MESHY_BAT_MUL := 95.0                 # the Meshy RightHand bone has a ~0.02 internal scale — counter it
const MESHY_PROP_ROT := Vector3(0, 0, 0)    # tweak if the bat sits at the wrong angle
const MESHY_PROP_OFS := Vector3(0, 0, 0)
const SIM_DT := 1.0 / 30.0
const BAR_W := 2.2
const BAR_H := 0.26
const UI_Y := 3.6
const PLAYER_UI_Y := 4.6                      # players sit their plate higher than mobs (clear name + level + bar above the head)
const DMG_NUM_Y := 4.4
const HIT_Y := 1.7
const SHAKE_MAX := 1.1                      # camera screen-shake cap (world units of jitter)
const SHAKE_DECAY := 5.0                     # how fast a shake settles
# --- combat-feel (Tier 1) — client-side presentation only; "reduce screen effects" damps/disables ---
const FLASH_DUR := 0.12                     # hit-flash fade (additive overlay on the struck body)
const FLASH_ALPHA := 0.85                   # flash starting intensity
const KICK_AMT := 0.30                      # directional camera kick on a dealt hit, world units (dmg-scaled)
const KICK_MAX := 0.55                      # cap the accumulated kick so multi-target AoE can't get seasick
const KICK_DECAY := 11.0                    # exponential settle rate for the kick
const FOV_KICK_CRIT := 2.2                  # crit punch-zoom, degrees
const FOV_KICK_KILL := 4.0                  # kill punch-zoom, degrees
const FOV_KICK_MAX := 5.0
const FOV_KICK_DECAY := 34.0                # degrees/sec → any punch settles in ≲0.15 s
const HITSTOP_HIT := 0.045                  # render-only hold on a hit you're part of (~3 frames @60)
const HITSTOP_CRIT := 0.075
const HITSTOP_KILL := 0.11
const PRED_CD_WINDOW := 0.7                 # secs a predicted cooldown sweep may run unconfirmed (≳ RTT + a snapshot)
const REDUCED_SHAKE := 0.35                 # shake multiplier when "reduce screen effects" is on
const RECOIL_LEAN := 0.16                   # peak struck-body flinch pitch, radians (~9°) — top tips away from the hit
const RECOIL_OFS := 0.18                    # peak model push away from the hit, world units
const SQUASH_AMT := 0.12                    # peak vertical squash fraction on a struck body (x/z widen ~2/3 of it)
const RECOIL_DECAY := 6.5                   # recoil settle rate, 1/s → a hit's give plays out in ~0.15 s
const RECOIL_CRIT := 1.45                   # crit recoil scale-up
const RECOIL_KILL := 1.9                    # killing-blow recoil scale-up (re-arms the victim's give)
const SHARD_CAP := 24                       # hard cap on debris nodes — an AoE multi-kill recycles, never allocates
const SHARD_LIFE := 0.55                    # seconds a shard flies before fading back to its pool
const SHARD_G := 22.0                       # shard gravity, world units/s² (chunky arcade fall)
const RESPAWN_DELAY := 3.0
const MAP_ID := "stadium"                 # open field; obstacle rendering supports any venue

# --- camera (3rd-person follow + orbit) ---
const FOV := 60.0
const ORBIT_SENS := 0.006
const ZOOM_STEP := 1.12
const DIST_MIN := 10.0
const DIST_MAX := 55.0
const PITCH_MIN := 0.62        # keep it overhead — no dropping to a flat free-cam angle
const PITCH_MAX := 1.45        # up to near top-down

const TEAM_COLOR := [Color(0.26, 0.74, 0.98), Color(0.98, 0.46, 0.52)]
const PLAYABLE := ["striker", "batter", "spiker", "linebacker", "pitcher", "quarterback", "setter", "goalkeeper"]
const BOTS := ["linebacker", "setter"]

# Meshy clip-name map (sport → renderer anim roles). Soccer throws by kicking.
# Per-ability clip overrides (classId → {ability key → clip name}), beyond the by-type default.
const ANIM_OVERRIDE := {"goalkeeper": {"distribution": "throw"}}
const HIT_SPEED := 3.0          # play the 1.67s hit clip ~3x → a quick ~0.55s flinch, not a long lurch
const HIT_FLINCH_CD := 1.2      # min seconds between flinches, so a flurry of hits isn't constant flinching
# Action clips are authored 2.7–4.3s — far longer than abilities actually fire. Play each one to ~a
# fraction of its cooldown (clamped) so frequent basics read snappy and long-cooldown ults read heavier.
const CAST_DUR_FRAC := 0.6
const CAST_DUR_MIN := 0.55      # quick floor for frequent basics
const CAST_DUR_MAX := 1.0       # ceiling so even long-cooldown abilities (power swings/ults) stay punchy, not slow

var _state: Dictionary
var _meshy := {}
var _mob_cache := {}                       # mob model basename → loaded GLB PackedScene (lazy, only spawned ones)
var _rigged := {}                          # rigged-mob id → {base, clips{role:Animation}, render_h, foot_y}
var _prop_cache := {}                       # prop id → {scene, aabb, foot} (cover-barrier GLBs, lazy)
var _nodes := {}                          # fighter id → render node dict
var _spawn_pos := {}                      # fighter id → Vector2 (sim) spawn for respawn
var _respawn := {}                        # fighter id → seconds until revive
var _player: Node
var _player_id := "0-0"
var _player_class_idx := 0

# Phase 3 — account-bound character: class is locked (no cycling) and position persists.
var class_locked := false
var locked_class := ""
var start_pos := Vector2.ZERO
var has_start_pos := false
var supa = null
var char_id := ""
var char_name := ""
var _save_t := 0.0
var _save_note := ""
var _quitting := false

var _world_root: Node3D
var _fx_root: Node3D
var _portal_root: Node3D = null            # portal pad visuals (rebuilt when the world's portals change)
var _portals_sig := ""
var _zone_root: Node3D = null              # hazard-zone ground discs (rebuilt when zones change)
var _zones_sig := ""
var _obstacle_root: Node3D = null          # cover/obstacle barriers (rebuilt when the zone's obstacles change)
var _obstacles_sig := ""
var _decal_root: Node3D = null             # purely-visual decals (drill rings + cones), rebuilt on map change
var _decals_sig := ""
var _ground: MeshInstance3D                # floor planes, resized when the arena (map) size changes
var _field: MeshInstance3D
var _arena_sig := ""
var _proj_pool := []
var _fx_active := []                       # {node, t, life, vel}
var _shake := 0.0                          # current camera screen-shake magnitude (decays each frame)
var _cam_kick := Vector3.ZERO              # directional impulse when YOU land a hit (decays fast)
var _fov_kick := 0.0                       # crit/kill punch-zoom in degrees (decays fast)
var _flashing := {}                        # fighter id → true while its hit-flash overlay is fading
var _recoiling := {}                       # fighter id → true while a struck-body recoil pose is decaying
var _pred_cds := {}                        # ability key → {t, total, window}: predicted cooldown sweeps
var reduce_fx := false                     # accessibility: damp shake, disable kick/FOV-punch/hitstop
var _num_pool := []
var _pop_pool := []
var _shard_pool := []                      # debris boxes (dedicated: shaded dark, not the additive pops)
var _shard_count := 0                      # lifetime allocations, hard-stopped at SHARD_CAP

var _cam: Camera3D
var _focus := Vector3.ZERO
var _yaw := 0.0
var _pitch := 1.12             # high, MMO-style overhead angle by default
var _dist := 26.0
var _dragging := false
var _rmb_moved := false       # distinguishes a right-CLICK (invite) from a right-drag (camera)
var _acc := 0.0
var _bots_frozen := true        # start paused so the player can feel out controls unrushed

var _hud: CanvasLayer
var _coords_on := false         # dev overlay (F3): sim-space (map) coord readout under the cursor
var _coords_lbl: Label = null
# --- in-game decorator (F4): place decal props by clicking, save to data/decals/<map>.json ---
var _deco_on := false
var _deco_lbl: Label = null
var _deco_idx := 0              # index into DECO_PROPS (the prop being placed)
var _deco_h := 3.0             # height for the next placed prop
var _deco_yaw := 0.0           # yaw for the next placed prop
var _deco_status := ""         # last-action line shown in the HUD
var _deco_sel := -1            # index of the GRABBED prop (follows the cursor until dropped), or -1
var _deco_sel_map := ""        # the zone the grabbed prop belongs to (drop the grab on a zone change)
var _deco_undo := []           # stack of [map, snapshot] — undo the last place / delete / move
var _decals_edit := {}         # map -> working Array of decal dicts (overrides JSON/World once you edit)
var _decals_cache := {}        # map -> resolved Array (JSON-on-disk or World fallback); avoids per-frame file reads
var _info: RichTextLabel
var _bar: RichTextLabel
var _hotbar: HBoxContainer                 # MMO-style skill bar (a slot per ability)
var _slots := []                           # [{root, cd, cs}] per ability
var _hotbar_class := ""
var _tooltip: PanelContainer
var _tt_label: RichTextLabel

# --- vitals frame + currency tray + zone banner (UI-overhaul P1) ---
var _hud_left: VBoxContainer               # top-left stack: vitals panel → currency tray
var _vitals: PanelContainer
var _vit_level: Label
var _vit_name: Label
var _vit_class: Label
var _vit_hp: Dictionary                    # Widgets.bar
var _vit_hp_text: Label
var _vit_shield: Dictionary
var _vit_xp: Dictionary
var _vit_xp_row: HBoxContainer
var _vit_xp_text: Label
var _vit_status: Label                     # respawning / save-note / bots line
var _tray: PanelContainer                  # ◈ credits · scrap · tokens (online only)
var _tray_credits: Label
var _tray_scrap: Label
var _tray_tokens: Label
var _zone_banner: PanelContainer
var _zone_label: Label
var _vit_cache := {}                       # last-set texts — skip re-shaping unchanged labels every frame

# --- DPS/HPS meter (§4a, UI-overhaul P1) — pure client, rides the zone-wide event stream ---
const METER_SLOTS := 15                    # per-second ring → a 10–15 s rolling DPS window
const METER_WINDOW := 15.0
const METER_GAP := 5.0                     # ≥5 s of event silence = an encounter edge
const METER_PRUNE := 60.0                  # idle entries dropped (bounds the dict)
const METER_MAX_ROWS := 10
const METER_ROW_W := 292.0
const METER_MODES := ["DPS · rolling", "DPS · encounter", "HPS", "Damage taken"]
var _meter := {}                           # fighter id → accumulator entry (see _meter_entry)
var _meter_panel: PanelContainer = null
var _meter_row_pool := []                  # [{root, fill, stripe, name, num}] — updated in place at 4 Hz
var _meter_title: Label = null
var _meter_mode := 0
var _meter_party_only := false             # sandbox default: whole zone (the bots ARE the encounter);
var _meter_scope_btn: Button = null        # NetClient flips it to party-only (§4a default)
var _meter_dragged := false                # once the player drags it, stop auto-placing on open
var _enc_start := 0.0
var _enc_last := -1.0e9                    # last tracked-event time; an event ≥GAP later opens a new encounter

# --- P4 screen-space juice: low-HP vignette + death overlay + toast stack (shared infra) ---
const LOW_HP_THRESH := 0.30                # vignette fades in below this HP fraction
const DEATH_FADE := 0.35                   # death-overlay fade-in seconds
const TOAST_W := 340.0
const TOAST_GAP := 6.0
const TOAST_MAX := 4                        # visible non-fading toasts before the oldest is pushed out
const TOAST_IN := 0.18
const TOAST_OUT := 0.35
const TOAST_HOLD := 4.5
const TOAST_HOLD_BIG := 6.0
const TOAST_SLIDE := 24.0                   # px slide-in offset (skipped under reduce_fx)
const TOAST_TOP := 64.0                     # clears the zone + drill banners
var _vignette: TextureRect = null
var _death_overlay: ColorRect = null
var _death_sub: Label = null
var _death_t := 0.0                         # death-overlay fade accumulator
var _low_hp_t := 0.0                        # low-HP heartbeat-pulse accumulator
var _toast_layer: Control = null
var _toasts := []                          # newest first: {node, phase, t, life, slide}

func _ready() -> void:
	_load_fx_settings()
	_load_meshy()
	_load_rigged_mobs()
	_build_world()
	_build_hud()
	_enter_mode()

# "reduce screen effects" persists next to the audio settings in user://settings.cfg
func _load_fx_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AudioManager.SETTINGS_PATH) == OK:
		reduce_fx = bool(cfg.get_value("fx", "reduce", false))

func set_reduce_fx(on: bool) -> void:
	reduce_fx = on
	var cfg := ConfigFile.new()
	cfg.load(AudioManager.SETTINGS_PATH)      # keep the audio section
	cfg.set_value("fx", "reduce", on)
	cfg.save(AudioManager.SETTINGS_PATH)

# Phase-1 LOCAL sandbox. NetClient (Phase 2) overrides this to connect to a server instead,
# reusing every rendering helper below.
func _enter_mode() -> void:
	if locked_class != "":
		# Phase 3: enter as the account's character (class fixed, position restored)
		if not GameData.CLASSES.has(locked_class):
			push_warning("[client] unknown class '%s' — falling back to default" % locked_class)
			locked_class = PLAYABLE[0]
		_player_class_idx = max(0, PLAYABLE.find(locked_class))
		_setup_match(locked_class)
		if has_start_pos:
			_place_player_at(start_pos)
		if class_locked:
			get_tree().set_auto_accept_quit(false)   # save on window close
		print("[client] entered as %s the %s (class locked)" % [char_name, locked_class])
	else:
		_setup_match(PLAYABLE[_player_class_idx])
		print("[client] Phase 1 arena ready — WASD move, 1-5 abilities, C cycle class, R reset.")
	# dev-only sandbox flags (pair with Main's --shot for hands-off UI verification)
	var uargs := OS.get_cmdline_user_args()
	if "--brawl" in uargs:
		_bots_frozen = false
		if not _state.is_empty():
			_state["botsFrozen"] = false
	if "--lowhp" in uargs:                    # dev: drop the player to 12% HP to verify the low-HP vignette
		var lp = _find_fighter(_player_id)
		if lp != null:
			lp["hp"] = float(lp["maxHP"]) * 0.12
	if "--meter" in uargs:
		_toggle_meter()
	if "--meter-dump" in uargs:              # headless proof: print the accumulator after 12 s, then quit
		var t := Timer.new()
		t.wait_time = 12.0
		t.one_shot = true
		t.autostart = true
		add_child(t)
		t.timeout.connect(func() -> void:
			for id in _meter:
				var e: Dictionary = _meter[id]
				print("[meter] %s '%s' dmg=%d heal=%d taken=%d enc=%.1fs" % [
					id, e["name"], int(e["dmg"]), int(e["heal"]), int(e["taken"]), _enc_last - _enc_start])
			get_tree().quit())

# ============================================================ assets / characters
func _load_meshy() -> void:
	var configs := {
		"Baseball": {"prefix": "baseball", "ranged": "throw"},
		"Football": {"prefix": "football", "ranged": "throw"},
		"Volleyball": {"prefix": "volleyball", "ranged": "throw"},
		"Soccer": {"prefix": "soccer", "ranged": "kick"},
	}
	for sport in configs:
		var prefix: String = configs[sport]["prefix"]
		var base_path := "res://models/meshy/%s_rigged.glb" % prefix
		if not ResourceLoader.exists(base_path):
			continue
		var entry := {"base": load(base_path), "clips": {},
			"anims": {"idle": "idle", "run": "run", "melee": "attack", "ranged": configs[sport]["ranged"],
				"hit": "hit", "death": "death", "cast": "cast"}}
		for cn in ["idle", "run", "walk", "attack", "hit", "death", "throw", "kick", "cast"]:
			var p := "res://models/meshy/clips/%s_%s.res" % [prefix, cn]
			if ResourceLoader.exists(p):
				var clip: Animation = load(p)
				if cn in ["idle", "run", "walk"]:        # cyclic clips shipped as LOOP_NONE → make them loop
					clip.loop_mode = Animation.LOOP_LINEAR  # smooth cycle (no freeze/pop at the end of each stride)
				else:                                    # action clips bake big root (Hips) drift → pin it in place
					_strip_root_motion(clip, cn != "death")   # keep Y for the death collapse; flatten it everywhere else
				_strip_hips_scale(clip)              # idle bakes a 1.176 Hips scale → strip it so size stays constant
				entry["clips"][cn] = clip
		if entry["clips"].has("idle") and entry["clips"].has("attack"):
			_meshy[sport] = entry
	print("[client] Meshy characters loaded: ", _meshy.keys(), " (", _meshy.size(), "/4 sports)")

func _find_anim(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

# Returns {model, anim, anims, scale} for a fighter's sport (Meshy, or capsule fallback).
# Glitchyard mobs (def.mob + a `model`) take a separate path: a static GLB grounded + scaled to its def
# height, driven client-side by the procedural animator (no skeleton/clips). Anything else, or an unknown
# id, falls through to the sport-rig path / capsule fallback.
func _make_character(f: Dictionary) -> Dictionary:
	var cid: String = str(f["classId"])
	if not GameData.CLASSES.has(cid):                     # defensive: unknown id used to crash the next line
		push_warning("[client] unknown classId '%s' — capsule fallback" % cid)
		return _capsule_kit("#cccccc")
	var def: Dictionary = GameData.CLASSES[cid]
	if def.get("mob", false) and def.get("rig", false):       # rigged mob → real skeletal clips (like players)
		var rk := _make_rigged_character(f, def)
		if not rk.is_empty():
			return rk
		return _capsule_kit(str(def.get("color", "#cccccc")))
	if def.get("isCore", false):                              # power core — real GLB if present, else procedural crystal
		if def.has("model") and ResourceLoader.exists("res://models/meshy/mobs/%s.glb" % str(def.get("model", ""))):
			var ck := _make_mob_character(f, def)             # loads the GLB + keeps the "core" float/spin/pulse (def.anim)
			if not ck.is_empty():
				return ck
		return _make_core_kit(def)
	if def.get("mob", false) and def.has("model"):
		var mk := _make_mob_character(f, def)
		if not mk.is_empty():
			return mk
		# model missing/unloadable → a colored capsule so the zone still runs
		return _capsule_kit(str(def.get("color", "#cccccc")))
	var sport: String = def["sport"]
	if _meshy.has(sport):
		var entry = _meshy[sport]
		var inst = entry["base"].instantiate()
		var ap := _find_anim(inst)
		if ap != null:
			var lib := ap.get_animation_library("")
			if lib == null:
				lib = AnimationLibrary.new()
				ap.add_animation_library("", lib)
			for cn in entry["clips"]:
				if not lib.has_animation(cn):
					lib.add_animation(cn, entry["clips"][cn])
		return {"model": inst, "anim": ap, "anims": entry["anims"], "scale": MESHY_SCALE}
	return _capsule_kit(str(def.get("color", "#cccccc")))

# A colored capsule kit (used when a sport rig or a mob GLB is unavailable) so the arena still runs.
func _capsule_kit(col: String) -> Dictionary:
	var cap := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.8
	cap.mesh = cm
	cap.position.y = 0.9
	cap.material_override = _mat(col)
	return {"model": cap, "anim": null, "anims": {}, "scale": 1.0}

# Lazy-load + cache a mob GLB by basename. Returns the PackedScene, or null if absent.
func _load_mob_model(model_id: String):
	if _mob_cache.has(model_id):
		return _mob_cache[model_id]
	var path := "res://models/meshy/mobs/%s.glb" % model_id
	var scene = load(path) if ResourceLoader.exists(path) else null
	_mob_cache[model_id] = scene
	return scene

# Merge every MeshInstance3D AABB under `node` into `acc` (a {have,aabb} dict), expressed in the frame
# reached by `xform` (the transform from node-local up to the reference frame). Used to ground + size mobs.
func _merge_mesh_aabb(node: Node, xform: Transform3D, acc: Dictionary) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var a: AABB = xform * (node as MeshInstance3D).get_aabb()
		acc["aabb"] = a if not acc["have"] else (acc["aabb"] as AABB).merge(a)
		acc["have"] = true
	for c in node.get_children():
		var cx := xform
		if c is Node3D:
			cx = xform * (c as Node3D).transform
		_merge_mesh_aabb(c, cx, acc)

# Build a mob render kit from a static GLB: pivot → animNode (procedurally animated) → glb (imported
# transform untouched). The glb is grounded (feet at y=0) and scaled so its rendered height == def.h.
# Returns {} if the GLB is missing (caller falls back to a capsule).
func _make_mob_character(f: Dictionary, def: Dictionary) -> Dictionary:
	var skins: Array = def.get("skins", [])
	var model_id: String = str(def.get("model", ""))
	if skins.size() > 0:                                    # alt cosmetic skin, stable per fighter id (all clients agree)
		model_id = str(skins[abs(str(f["id"]).hash()) % skins.size()])
	var scene = _load_mob_model(model_id)
	if scene == null:
		push_warning("[client] mob model '%s' missing — capsule fallback" % model_id)
		return {}
	var pivot := Node3D.new()
	var anim_node := Node3D.new()
	pivot.add_child(anim_node)
	var glb = scene.instantiate()
	anim_node.add_child(glb)
	var acc := {"have": false, "aabb": AABB()}
	_merge_mesh_aabb(glb, glb.transform, acc)              # AABB in anim_node frame (includes glb's imported xform)
	var aabb: AABB = acc["aabb"]
	var size_y: float = maxf(aabb.size.y, 0.001)
	var msc: float = float(def.get("h", 1.8)) / size_y     # scale-to-height (msc applied to pivot by _spawn)
	var ground_y: float = -aabb.position.y                 # lift so the model's lowest point sits at y=0
	anim_node.position.y = ground_y
	glb.rotation.y += deg_to_rad(float(def.get("face", 0.0)))   # per-model native-front correction (Y-rot: no effect on height/ground)
	return {"model": pivot, "anim": null, "anims": {}, "scale": msc,
		"mob": str(def.get("anim", "")), "animTarget": anim_node, "baseY": ground_y, "sizeY": size_y}

# Power core — a procedural floating crystal (emissive), no GLB. Players destroy it to weaken the boss ult.
func _make_core_kit(def: Dictionary) -> Dictionary:
	var h: float = float(def.get("h", 2.0))
	var pivot := Node3D.new()
	var anim_node := Node3D.new()
	pivot.add_child(anim_node)
	var crystal := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(h * 0.55, h * 0.9, h * 0.55)
	crystal.mesh = pm
	var col := Color(0.22, 0.78, 1.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.4
	crystal.material_override = mat
	crystal.position.y = h * 0.55                       # float above the pad
	anim_node.add_child(crystal)
	# a small base disc so it reads as an objective
	var base := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = h * 0.42; cm.bottom_radius = h * 0.42; cm.height = 0.08
	base.mesh = cm
	base.material_override = _mat("#2a6a88")
	anim_node.add_child(base)
	return {"model": pivot, "anim": null, "anims": {}, "scale": 1.0,
		"mob": "core", "animTarget": anim_node, "baseY": 0.0, "sizeY": h}

# Rigged mobs (the foam dummies): Meshy biped exports with real skeletal clips. render_h = the rendered
# mesh height at model-scale 1 (≈ skeleton bone-extent × ~1.07), foot_y = the foot-bone Y at scale 1 —
# both measured offline (tools/smoke_rigged.gd) so scale-to-height + grounding need no runtime posing.
const RIGGED_MOBS := {
	"foam_dummy":  {"render_h": 1.31, "foot_y": 0.075},
	"foam_dummy2": {"render_h": 1.45, "foot_y": 0.0},   # this model's sole sits at the mesh origin (no drop)
	"drill_sergeant": {"render_h": 1.71, "foot_y": 0.03},   # Devil Drill Sergeant (also has a cast/shout clip)
}
const RIGGED_ROLES := ["idle", "walk", "run", "attack", "hit", "death", "cast"]

func _load_rigged_mobs() -> void:
	for id in RIGGED_MOBS:
		var base_path := "res://models/meshy/mobs/rigged/%s.glb" % id
		if not ResourceLoader.exists(base_path):
			continue
		var clips := {}
		for role in RIGGED_ROLES:
			var cp := "res://models/meshy/mobs/rigged/clips/%s_%s.res" % [id, role]
			if ResourceLoader.exists(cp):
				var clip: Animation = load(cp)
				_strip_hips_scale(clip)        # defensive: Meshy idle clips can bake a Hips scale (balloon)
				clips[role] = clip
		if not clips.has("idle"):              # parity with the player path: a clip-starved rig → capsule fallback
			push_warning("[client] rigged mob '%s' missing idle clip — skipping (capsule fallback)" % id)
			continue
		_rigged[id] = {"base": load(base_path), "clips": clips,
			"render_h": float(RIGGED_MOBS[id]["render_h"]), "foot_y": float(RIGGED_MOBS[id]["foot_y"])}
	print("[client] rigged mobs loaded: ", _rigged.keys())

# Build a kit from a rigged base + merged .res clips, scaled to def.h and grounded. Drives through the same
# skeletal _drive_anim path the players use (no procedural animator). Returns {} if assets are missing.
func _make_rigged_character(f: Dictionary, def: Dictionary) -> Dictionary:
	var skins: Array = def.get("skins", [])
	var id: String = str(def.get("model", ""))
	if skins.size() > 0:
		id = str(skins[abs(str(f["id"]).hash()) % skins.size()])
	if not _rigged.has(id):
		return {}
	var entry: Dictionary = _rigged[id]
	var inst = entry["base"].instantiate()
	var ap := _find_anim(inst)
	if ap != null:
		var lib := ap.get_animation_library("")
		if lib == null:
			lib = AnimationLibrary.new()
			ap.add_animation_library("", lib)
		for role in entry["clips"]:
			if not lib.has_animation(role):
				lib.add_animation(role, entry["clips"][role])
	var msc: float = float(def.get("h", 3.3)) / maxf(float(entry["render_h"]), 0.001)
	# role → clip name (== role here); ranged is unused; cast only if the rig exported one (the drill shouts)
	var clips: Dictionary = entry["clips"]
	var anims := {"idle": "idle", "run": "run", "walk": "walk", "melee": "attack",
		"ranged": "", "hit": "hit", "death": "death", "cast": ("cast" if clips.has("cast") else "")}
	return {"model": inst, "anim": ap, "anims": anims, "scale": msc,
		"yoff": -float(entry["foot_y"]) * msc}        # drop so the foot bone sits at the floor

# ============================================================ world / camera
func _mat(col) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = (Color(col) if col is String else col)
	return m

# A held sport prop for the class, or null. The Batter carries a bat (a tapered cylinder); _spawn pins
# it to the RightHand bone so it tracks the swing. (Balls are intentionally omitted — a ball stuck in
# the hand reads oddly during a throw, where the projectile is its own FX.)
func _class_prop(class_id: String) -> Node3D:
	if class_id != "batter":
		return null
	var root := Node3D.new()
	root.scale = Vector3(PROP_SCALE, PROP_SCALE, PROP_SCALE)
	var bat := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.055
	cm.bottom_radius = 0.02
	cm.height = 0.82
	bat.mesh = cm
	bat.material_override = _mat(Color(0.66, 0.45, 0.26))
	bat.position = Vector3(0, 0.40, 0)
	root.add_child(bat)
	return root

func _quad(w: float, h: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	var mt := StandardMaterial3D.new()
	mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mt.albedo_color = col
	mi.material_override = mt
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _aw() -> float:
	return float(_state.get("arenaW", GameData.ARENA_W))

func _ah() -> float:
	return float(_state.get("arenaH", GameData.ARENA_H))

func _world(f: Dictionary) -> Vector3:
	return Vector3((f["x"] - _aw() / 2.0) * SCALE, 0.0, (f["y"] - _ah() / 2.0) * SCALE)

# Resize the floor when the arena (map) size changes — i.e. when you cross into the other world.
func _resize_arena() -> void:
	var sig := "%dx%d" % [int(_aw()), int(_ah())]
	if sig == _arena_sig:
		return
	_arena_sig = sig
	if _ground != null and _ground.mesh is PlaneMesh:
		(_ground.mesh as PlaneMesh).size = Vector2(_aw() * SCALE + 24.0, _ah() * SCALE + 24.0)
	if _field != null and _field.mesh is PlaneMesh:
		(_field.mesh as PlaneMesh).size = Vector2(_aw() * SCALE, _ah() * SCALE)

# Dev overlay (toggle F3): print the sim-space (map) coordinate under the cursor so you can hand-author
# World.gd DECALS/OBSTACLES/MOBS positions by pointing instead of guessing. Purely client-side — no
# gameplay effect, not sent anywhere. The readout is the SAME coordinate space you type into World.gd.
# pin a label to the TOP-RIGHT corner (right-aligned, grows leftward), clear of the top-left player HUD.
func _pin_topright(lbl: Label, top: float) -> void:
	lbl.anchor_left = 1.0
	lbl.anchor_right = 1.0
	lbl.offset_left = -760.0
	lbl.offset_right = -16.0
	lbl.offset_top = top
	lbl.offset_bottom = top + 90.0
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

func _toggle_coords() -> void:
	_coords_on = not _coords_on
	if _coords_lbl == null and _hud != null:
		_coords_lbl = Label.new()
		_coords_lbl.add_theme_font_size_override("font_size", 15)
		_coords_lbl.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
		_coords_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_coords_lbl.add_theme_constant_override("outline_size", 4)
		_pin_topright(_coords_lbl, 12.0)
		_coords_lbl.z_index = 4096
		_coords_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud.add_child(_coords_lbl)
	if _coords_lbl != null:
		_coords_lbl.visible = _coords_on

func _cursor_sim() -> Vector2:                     # sim-space (map) coord under the mouse; (-1,-1) if the ray misses
	if _cam == null:
		return Vector2(-1, -1)
	var mp := get_viewport().get_mouse_position()
	var o := _cam.project_ray_origin(mp)
	var dir := _cam.project_ray_normal(mp)
	if absf(dir.y) < 1e-5:
		return Vector2(-1, -1)
	var t := -o.y / dir.y                           # intersect the y=0 ground plane
	if t < 0.0:
		return Vector2(-1, -1)
	var hit := o + dir * t
	return Vector2(hit.x / SCALE + _aw() / 2.0, hit.z / SCALE + _ah() / 2.0)   # inverse of _world()

func _update_coords() -> void:
	if not _coords_on or _coords_lbl == null:
		return
	var p := _cursor_sim()
	if p.x < 0.0:
		return
	var mapname: String = str(_state.get("map", "?")) if _state != null else "?"
	_coords_lbl.text = "map %s    x %d    y %d    (bounds %d x %d)" % [mapname, int(round(p.x)), int(round(p.y)), int(_aw()), int(_ah())]

# ============================================================ IN-GAME DECORATOR (F4)
# Place decal props by clicking the ground instead of hand-editing shared/World.gd. Saves to
# res://data/decals/<map>.json (loaded at runtime — so a bad edit can never break the game's scripts).
# Purely cosmetic + client-side. Author from source (./play.sh dev); deploy the json to reach players.
const DECO_PROPS := [
	"cone", "tree_oak", "tree_pineRoundC", "tree_default", "tree_thin", "tree_palmDetailedTall",
	"rock_largeA", "rock_largeC", "rock_largeE", "rock_tallC", "stone_largeB",
	"plant_bush", "plant_bushLarge", "grass_large", "flower_redA", "flower_yellowB", "log_stack",
	"fence_simple", "fence_planks", "fence_corner",
	"building-a", "building-c", "building-e", "building-h", "building-k", "building-n", "building-q", "building-t",
	"chimney-small", "chimney-medium", "chimney-large", "detail-tank",
	"bag", "barrier", "rack", "stadium",
	"gear_forge", "quest_board", "sideline_stand", "power_core",   # admin-only Meshy landmarks (not in BUILD_CATALOG)
]

# decal source for a map, priority: live editor working copy → data/decals/<map>.json → World.DECALS const.
func _decals_for(map: String) -> Array:
	if _decals_edit.has(map):
		return _decals_edit[map]
	if _decals_cache.has(map):
		return _decals_cache[map]
	var out: Array = World.decals_for(map)
	var jpath := "res://data/decals/%s.json" % map
	if FileAccess.file_exists(jpath):
		var f := FileAccess.open(jpath, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Array:
				out = parsed
			else:
				push_warning("[decals] %s isn't a JSON array — using the World.gd fallback" % jpath)
	_decals_cache[map] = out
	return out

func _edit_list(map: String) -> Array:             # the mutable working copy (seeded from whatever's there now)
	if not _decals_edit.has(map):
		_decals_edit[map] = _decals_for(map).duplicate(true)
	return _decals_edit[map]

func _toggle_deco() -> void:
	_deco_on = not _deco_on
	if _deco_lbl == null and _hud != null:
		_deco_lbl = Label.new()
		_deco_lbl.add_theme_font_size_override("font_size", 14)
		_deco_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.55))
		_deco_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_deco_lbl.add_theme_constant_override("outline_size", 4)
		_pin_topright(_deco_lbl, 44.0)
		_deco_lbl.z_index = 4096
		_deco_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud.add_child(_deco_lbl)
	if _deco_lbl != null:
		_deco_lbl.visible = _deco_on
	if _deco_on and not _coords_on:
		_toggle_coords()                            # the coord readout pairs naturally with placing
	_deco_status = "decorate mode ON" if _deco_on else ""
	_update_deco_lbl()

func _update_deco_lbl() -> void:
	if _deco_lbl == null:
		return
	var status: String = ("\n  » %s" % _deco_status) if _deco_status != "" else ""
	if _deco_sel >= 0:
		var gmap: String = str(_state.get("map", "")) if _state != null else ""
		var glst := _edit_list(gmap)
		if _deco_sel < glst.size():
			var d: Dictionary = glst[_deco_sel]
			_deco_lbl.text = "GRAB %s    x %d  y %d    lift %.1f   height %.1f   yaw %.2f\n  move mouse to reposition · , . rotate · - = height · PgUp/PgDn lift · click or G to drop%s" % [
				str(d.get("model", d.get("kind", "?"))), int(float(d.get("x", 0))), int(float(d.get("y", 0))),
				float(d.get("oy", 0.0)), float(d.get("h", 0.0)), float(d.get("yaw", 0.0)), status]
			return
		_deco_sel = -1
	var id: String = DECO_PROPS[_deco_idx]
	_deco_lbl.text = "DECORATE    [ ] prop: %s     , . rotate     - = height %.1f\n  L-click place · G grab/move · X delete · Ctrl+Z undo · Ctrl+S save · F4 exit%s" % [id, _deco_h, status]

# highest-priority input hook: only active while decorating (else early-out), so zero effect on normal play.
func _input(e: InputEvent) -> void:
	if not _deco_on:
		if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F4:
			# F4 is context-sensitive: in your OWN Locker Room it toggles the server-driven build editor (P3b);
			# everywhere else it's the admin/dev decorator (map authoring → local JSON). The base has no server
			# locker, so _locker_build_available() is false here and F4 keeps its dev-decorator meaning; NetClient
			# overrides the two hooks to route F4 (and its own editor input, via _extra_input) into the locker editor.
			if _locker_build_available():
				_locker_build_toggle()
			elif _world_build_allowed():
				_toggle_deco()                          # the world/map decorator — GATED to admins on the live server
			get_viewport().set_input_as_handled()
			return
		if _extra_input(e):                             # subclass input hook (the Locker Room build editor when active)
			get_viewport().set_input_as_handled()
		return
	var foc := get_viewport().gui_get_focus_owner()
	if foc is LineEdit or foc is TextEdit:
		return                                      # a text field is focused (e.g. chat) — don't steal keys
	if _deco_input(e):
		get_viewport().set_input_as_handled()

# --- overridable hooks for the player-facing Locker Room build editor (P3b). The base (local sandbox /
# map-authoring) has no server locker, so these are inert; NetClient overrides them to drive the editor. ---
func _locker_build_available() -> bool:
	return false
func _locker_build_toggle() -> void:
	pass
func _extra_input(_e: InputEvent) -> bool:
	return false
# may this client use the WORLD/map decorator (F4 outside your Locker Room)? The base is the local single-player
# sandbox (map authoring is the whole point) → yes. NetClient overrides it to admin-only on the live server.
func _world_build_allowed() -> bool:
	return true

func _deco_input(e: InputEvent) -> bool:
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		if _deco_sel >= 0:
			_deco_sel = -1                          # drop the grabbed prop right here
			_deco_status = "dropped"
			_update_deco_lbl()
		else:
			_deco_place()
		return true
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_F4:
				_toggle_deco()
				return true
			KEY_G:                                  # grab the nearest prop (or drop the held one)
				if _deco_sel >= 0:
					_deco_sel = -1
					_deco_status = "dropped"
					_update_deco_lbl()
				else:
					_deco_grab_nearest()
				return true
			KEY_Z:
				if e.ctrl_pressed:
					_deco_undo_last()
					return true
			KEY_BRACKETLEFT:
				_deco_idx = (_deco_idx - 1 + DECO_PROPS.size()) % DECO_PROPS.size()
				_update_deco_lbl()
				return true
			KEY_BRACKETRIGHT:
				_deco_idx = (_deco_idx + 1) % DECO_PROPS.size()
				_update_deco_lbl()
				return true
			KEY_COMMA:
				_deco_tweak("yaw", -0.2618)         # ~15° — the grabbed prop if held, else the next placed one
				return true
			KEY_PERIOD:
				_deco_tweak("yaw", 0.2618)
				return true
			KEY_MINUS:
				_deco_tweak("h", -0.3)
				return true
			KEY_EQUAL:
				_deco_tweak("h", 0.3)
				return true
			KEY_PAGEUP:
				_deco_tweak("oy", 0.25)             # lift up (to stack on top of something)
				return true
			KEY_PAGEDOWN:
				_deco_tweak("oy", -0.25)
				return true
			KEY_X:
				_deco_delete_nearest()
				return true
			KEY_S:
				if e.ctrl_pressed:
					_deco_save()
					return true
	return false

# per-frame: while a prop is grabbed, it tracks the cursor on the ground (drop with click or G).
func _update_deco() -> void:
	if not _deco_on or _deco_sel < 0:
		return
	var map: String = str(_state.get("map", "")) if _state != null else ""
	if map != _deco_sel_map:                         # changed zones while holding one → drop it
		_deco_sel = -1
		_update_deco_lbl()
		return
	var lst := _edit_list(map)
	if _deco_sel >= lst.size():
		_deco_sel = -1
		return
	var p := _cursor_sim()
	if p.x < 0.0:
		return
	var nx := snappedf(p.x, 1.0)
	var ny := snappedf(p.y, 1.0)
	if float(lst[_deco_sel].get("x", 0.0)) != nx or float(lst[_deco_sel].get("y", 0.0)) != ny:
		lst[_deco_sel]["x"] = nx
		lst[_deco_sel]["y"] = ny
		_decals_sig = ""                            # moved → re-render
		_update_deco_lbl()

# adjust yaw / height / lift of the GRABBED prop if one is held; otherwise the next-placed defaults.
func _deco_tweak(field: String, delta: float) -> void:
	if _deco_sel >= 0:
		var map: String = str(_state.get("map", "")) if _state != null else ""
		var lst := _edit_list(map)
		if _deco_sel < lst.size():
			var v := float(lst[_deco_sel].get(field, 0.0)) + delta
			if field == "h":
				v = clampf(v, 0.3, 20.0)
			elif field == "oy":
				v = clampf(v, -10.0, 40.0)
			lst[_deco_sel][field] = snappedf(v, 0.01)
			_decals_sig = ""
	elif field == "yaw":
		_deco_yaw += delta
	elif field == "h":
		_deco_h = clampf(_deco_h + delta, 0.3, 20.0)
	_update_deco_lbl()

func _deco_grab_nearest() -> void:
	var p := _cursor_sim()
	if p.x < 0.0:
		return
	var map: String = str(_state.get("map", "")) if _state != null else ""
	var lst := _edit_list(map)
	var best := -1
	var bestd := 90.0 * 90.0                         # grab within ~90 sim units of the cursor
	for i in lst.size():
		var dx: float = float(lst[i].get("x", 0.0)) - p.x
		var dy: float = float(lst[i].get("y", 0.0)) - p.y
		var d := dx * dx + dy * dy
		if d < bestd:
			bestd = d
			best = i
	if best >= 0:
		_deco_push_undo(map)                         # snapshot the pre-move state so undo reverts it
		_deco_sel = best
		_deco_sel_map = map
		_deco_status = "grabbed %s — move the mouse, click to drop" % str(lst[best].get("model", lst[best].get("kind", "?")))
	else:
		_deco_status = "nothing to grab near the cursor"
	_update_deco_lbl()

func _deco_push_undo(map: String) -> void:
	_deco_undo.append([map, _edit_list(map).duplicate(true)])
	if _deco_undo.size() > 64:
		_deco_undo.pop_front()

func _deco_undo_last() -> void:
	_deco_sel = -1                                   # cancel any grab in progress
	if _deco_undo.is_empty():
		_deco_status = "nothing to undo"
		_update_deco_lbl()
		return
	var rec: Array = _deco_undo.pop_back()
	_decals_edit[str(rec[0])] = rec[1]
	_decals_sig = ""
	_deco_status = "undo"
	_update_deco_lbl()

func _deco_place() -> void:
	var p := _cursor_sim()
	if p.x < 0.0:
		return
	var map: String = str(_state.get("map", "")) if _state != null else ""
	if map == "":
		return
	var id: String = DECO_PROPS[_deco_idx]
	var entry: Dictionary
	if id == "cone":
		entry = {"kind": "cone", "x": snappedf(p.x, 1.0), "y": snappedf(p.y, 1.0)}
	else:
		entry = {"kind": "prop", "model": id, "x": snappedf(p.x, 1.0), "y": snappedf(p.y, 1.0), "h": snappedf(_deco_h, 0.1), "yaw": snappedf(_deco_yaw, 0.01)}
	_deco_push_undo(map)                            # snapshot before the change (Ctrl+Z reverts this place)
	_edit_list(map).append(entry)
	_decals_sig = ""                                # force _render_decals to rebuild next frame
	_deco_status = "placed %s at %d,%d" % [id, int(p.x), int(p.y)]
	_update_deco_lbl()

func _deco_delete_nearest() -> void:
	var p := _cursor_sim()
	if p.x < 0.0:
		return
	var map: String = str(_state.get("map", "")) if _state != null else ""
	var lst := _edit_list(map)
	var best := -1
	var bestd := 70.0 * 70.0                        # only delete within ~70 sim units of the cursor
	for i in lst.size():
		var dx: float = float(lst[i].get("x", 0.0)) - p.x
		var dy: float = float(lst[i].get("y", 0.0)) - p.y
		var d := dx * dx + dy * dy
		if d < bestd:
			bestd = d
			best = i
	if best >= 0:
		var gone = lst[best]
		_deco_push_undo(map)                        # snapshot before the change (Ctrl+Z restores it)
		lst.remove_at(best)
		_decals_sig = ""
		_deco_status = "deleted %s" % str(gone.get("model", gone.get("kind", "?")))
	else:
		_deco_status = "nothing to delete near the cursor"
	_update_deco_lbl()

func _deco_save() -> void:
	var map: String = str(_state.get("map", "")) if _state != null else ""
	if map == "":
		return
	var lst := _edit_list(map)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://data/decals"))
	var jpath := "res://data/decals/%s.json" % map
	var f := FileAccess.open(jpath, FileAccess.WRITE)
	if f == null:
		_deco_status = "SAVE FAILED (err %d) — run from source (./play.sh dev), not an exported build" % FileAccess.get_open_error()
		_update_deco_lbl()
		return
	f.store_string(JSON.stringify(lst, "\t"))
	f.close()
	_decals_cache[map] = lst.duplicate(true)
	_deco_status = "saved %d decals → data/decals/%s.json" % [lst.size(), map]
	_update_deco_lbl()

func _build_world() -> void:
	_world_root = Node3D.new()
	add_child(_world_root)
	_fx_root = Node3D.new()
	add_child(_fx_root)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58, -42, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.07, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.52, 0.64)
	env.ambient_light_energy = 0.75
	env.fog_enabled = true
	env.fog_density = 0.004
	env.fog_light_color = Color(0.06, 0.08, 0.12)
	we.environment = env
	add_child(we)

	# ground + field
	var ground := MeshInstance3D.new()
	var gp := PlaneMesh.new()
	gp.size = Vector2(GameData.ARENA_W * SCALE + 24.0, GameData.ARENA_H * SCALE + 24.0)
	ground.mesh = gp
	ground.material_override = _mat(Color(0.10, 0.13, 0.10))
	add_child(ground)
	_ground = ground
	var field := MeshInstance3D.new()
	var fp := PlaneMesh.new()
	fp.size = Vector2(GameData.ARENA_W * SCALE, GameData.ARENA_H * SCALE)
	field.mesh = fp
	field.position.y = 0.01
	field.material_override = _mat(Color(0.16, 0.30, 0.18))
	add_child(field)
	_field = field

	# obstacles (rigs) for the chosen map — cylinders
	for o in GameData.MAPS[MAP_ID]["obstacles"]:
		var rig := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = o["r"] * SCALE
		cyl.bottom_radius = o["r"] * SCALE
		cyl.height = 2.2
		rig.mesh = cyl
		rig.position = Vector3((o["x"] - GameData.ARENA_W / 2.0) * SCALE, 1.1, (o["y"] - GameData.ARENA_H / 2.0) * SCALE)
		rig.material_override = _mat(Color(0.30, 0.32, 0.38))
		add_child(rig)

	_cam = Camera3D.new()
	_cam.fov = FOV
	add_child(_cam)
	_update_cam()

func _update_cam() -> void:
	var dir := Vector3(cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw))
	_cam.position = _focus + dir * _dist
	if _shake > 0.001:                       # screen shake: jitter the camera, still aimed at the focus
		_cam.position += Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * (_shake * 2.0)
	_cam.position += _cam_kick               # directional dealt-hit kick (ZERO when idle)
	_cam.look_at(_focus, Vector3.UP)
	_cam.fov = FOV - _fov_kick               # crit/kill punch-zoom (0 when idle)

func _add_shake(amt: float) -> void:
	if reduce_fx:
		amt *= REDUCED_SHAKE
	_shake = minf(SHAKE_MAX, _shake + amt)

# nudge the camera INTO a hit you landed — the missing "you hit it" kinetics. Capped so AoE stacks safely.
func _add_cam_kick(dir: Vector3, amt: float) -> void:
	if reduce_fx or dir.length_squared() < 0.000001:
		return
	_cam_kick = (_cam_kick + dir.normalized() * amt).limit_length(KICK_MAX)

func _add_fov_kick(deg: float) -> void:
	if reduce_fx:
		return
	_fov_kick = minf(_fov_kick + deg, FOV_KICK_MAX)

# render-only hitstop: hold a node's position lerp + anim advance for a beat; the server keeps ticking,
# so the catch-up snap when the hold ends IS the impact bite. Never Engine.time_scale / pause — that
# would stall NetClient's 60 Hz input/send loop and desync from the server.
func _add_hitstop(id, dur: float) -> void:
	if reduce_fx:
		return
	var n = _nodes.get(id)
	if n == null:
		return
	n["hold"] = maxf(float(n.get("hold", 0.0)), dur)
	if n["anim"] != null:
		(n["anim"] as AnimationPlayer).speed_scale = 0.0

# arm the struck-body give (Tier 2): lean/push away from the hit + a squash pulse, posed + decayed +
# restored in _update_fx. Skeletal fighters only — mob kits' anim_node is rewritten every frame by
# _drive_mob_anim and already recoils via its hit channel. dir = world-space src→tgt push (ZERO = squash
# only, e.g. the source is out of interest range). A re-hit re-arms; strength keeps the strongest active.
func _add_recoil(id, dir: Vector3, k: float) -> void:
	var n = _nodes.get(id)
	if n == null or n.has("mobanim"):
		return
	if float(n.get("recoil_t", 0.0)) > 0.0:
		k = maxf(k, float(n.get("recoil_k", 1.0)))
	dir.y = 0.0
	n["recoil_t"] = 1.0
	n["recoil_k"] = k
	n["recoil_dir"] = dir.normalized() if dir.length_squared() > 0.000001 else Vector3.ZERO
	_recoiling[id] = true

# ============================================================ match setup
func _setup_match(player_class: String) -> void:
	_teardown()
	_state = Sim.create_match([player_class], BOTS.duplicate(), 20260620, MAP_ID)
	_state["botsFrozen"] = _bots_frozen
	for f in _state["fighters"]:
		_spawn_pos[f["id"]] = Vector2(f["x"], f["y"])
		_spawn(f)
	# wire the player controller into the controlled seam (shared intent dict reference)
	_player = PlayerCtl.new()
	_player.class_id = player_class
	add_child(_player)
	_state["controlled"] = {_player_id: _player.intent}
	_focus = _world(_state["fighters"][0])

func _teardown() -> void:
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
		_player = null
	for id in _nodes:
		var n = _nodes[id]
		if is_instance_valid(n["holder"]):
			n["holder"].queue_free()
	_nodes.clear()
	_spawn_pos.clear()
	_respawn.clear()
	for p in _proj_pool:
		if is_instance_valid(p):
			p.queue_free()
	_proj_pool.clear()
	for fx in _fx_active:
		if is_instance_valid(fx["node"]):
			fx["node"].visible = false
			if fx["kind"] == "num":
				_num_pool.append(fx["node"])
			elif fx["kind"] == "shard":        # shard boxes must NOT enter the additive pop pool — a migrated
				_shard_pool.append(fx["node"])   # box renders pops dark AND permanently leaks the capped budget
			else:
				_pop_pool.append(fx["node"])   # re-pool in-flight FX so a mid-anim reset doesn't strand nodes
	_fx_active.clear()
	_acc = 0.0
	_meter.clear()                     # sandbox R/C reset: no leaked meter rows (same discipline as the pools)
	_enc_last = -1.0e9
	if _meter_panel != null:
		_render_meter()
	_clear_toasts()                    # P4: flush in-flight toasts + latch off the vignette/death overlay
	if _vignette != null:
		_vignette.visible = false
	if _death_overlay != null:
		_death_overlay.visible = false
	_death_t = 0.0
	_low_hp_t = 0.0

func _spawn(f: Dictionary) -> void:
	var holder := Node3D.new()
	_world_root.add_child(holder)
	holder.position = _world(f)

	var ring := MeshInstance3D.new()
	var rcyl := CylinderMesh.new()
	rcyl.top_radius = 1.25
	rcyl.bottom_radius = 1.25
	rcyl.height = 0.05
	ring.mesh = rcyl
	ring.position.y = 0.05
	var ring_col: Color = TEAM_COLOR[f["team"]]
	var lpf = _find_fighter(_player_id)
	if lpf != null and _hostile_pair(lpf, f):
		ring_col = Color(1.0, 0.4, 0.4)              # a hostile (non-party) player in a PvP zone reads red
	var rmat := _mat(ring_col)
	rmat.emission_enabled = true
	rmat.emission = ring_col
	rmat.emission_energy_multiplier = 0.5
	ring.material_override = rmat
	holder.add_child(ring)

	var kit := _make_character(f)
	var model = kit["model"]
	var msc: float = kit["scale"]
	model.scale = Vector3(msc, msc, msc)
	model.position.y = CHAR_Y + float(kit.get("yoff", 0.0))   # rigged mobs carry a grounding offset
	holder.add_child(model)
	var ap = kit["anim"]
	if ap != null:
		ap.playback_default_blend_time = 0.12
		_safe_play(ap, kit["anims"].get("idle", "idle"))

	var prop := _class_prop(str(f["classId"]))   # held sport prop (the Batter's bat) on the hand bone
	if prop != null:
		var skel := _find_skeleton(model)
		if skel != null:
			var ba := BoneAttachment3D.new()
			skel.add_child(ba)
			ba.bone_name = "RightHand"
			prop.scale *= MESHY_BAT_MUL          # counter the hand bone's tiny internal scale
			prop.rotation_degrees = MESHY_PROP_ROT
			prop.position = MESHY_PROP_OFS
			ba.add_child(prop)

	var ui := Node3D.new()
	var udef: Dictionary = GameData.CLASSES.get(str(f["classId"]), {})
	# lift the nameplate/scoreboard clear above tall mobs (e.g. the 4.6-tall boss) instead of overlapping them;
	# players sit higher (PLAYER_UI_Y) so their name + level + bar clear the character's head
	ui.position.y = maxf(UI_Y, float(udef.get("h", 0.0)) + 0.8) if bool(udef.get("mob", false)) else PLAYER_UI_Y
	holder.add_child(ui)
	ui.add_child(_quad(BAR_W + 0.08, BAR_H + 0.08, Color(0, 0, 0, 0.6)))
	var fill := _quad(BAR_W, BAR_H, Color(0.3, 0.85, 0.4))
	fill.position.z = 0.01
	ui.add_child(fill)
	var label := Label3D.new()                # level / tier nameplate (mobs, and players online)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = WorldUI.PLATE_PIXEL
	label.font_size = WorldUI.PLATE_FONT
	label.outline_size = WorldUI.PLATE_OUTLINE
	label.outline_modulate = WorldUI.OUTLINE_COLOR
	label.position.y = BAR_H + 0.32
	ui.add_child(label)

	# a second, prominent line ABOVE the level line: the player's character name (hidden for mobs)
	var nameLabel := Label3D.new()
	nameLabel.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	nameLabel.no_depth_test = true
	nameLabel.fixed_size = true
	nameLabel.pixel_size = WorldUI.PLATE_PIXEL
	nameLabel.font_size = WorldUI.PLATE_NAME
	nameLabel.outline_size = WorldUI.PLATE_OUTLINE
	nameLabel.outline_modulate = WorldUI.OUTLINE_COLOR
	nameLabel.position.y = BAR_H + 0.92
	nameLabel.visible = false
	ui.add_child(nameLabel)

	var aura = null                               # P3: a core-shielded boss gets a toggleable protective aura
	if float(udef.get("coreShield", 0.0)) > 0.0:
		aura = MeshInstance3D.new()
		var sph := SphereMesh.new()
		var ar := float(udef.get("h", 4.0)) * 0.6
		sph.radius = ar
		sph.height = ar * 2.0
		aura.mesh = sph
		var amat := StandardMaterial3D.new()
		amat.albedo_color = Color(0.3, 0.75, 1.0, 0.16)
		amat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		amat.emission_enabled = true
		amat.emission = Color(0.35, 0.8, 1.0)
		amat.emission_energy_multiplier = 1.3
		amat.cull_mode = BaseMaterial3D.CULL_DISABLED
		aura.material_override = amat
		aura.position.y = ar * 0.9
		aura.visible = false
		aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(aura)
	_nodes[f["id"]] = {
		"holder": holder, "model": model, "anim": ap, "anims": kit["anims"], "mscale": msc,
		"ui": ui, "fill": fill, "label": label, "name": nameLabel, "aura": aura, "last": holder.position, "vel": Vector2.ZERO,
		# pcds primed from the live cds: cooldowns already ticking when this fighter entered view are
		# NOT fresh casts — an empty dict would phantom-fire every one of them as a cast tell.
		"pcds": (f.get("cds", {}) as Dictionary).duplicate(),
		"busy": "", "atk_clip": "", "atk_speed": 1.0, "died": false, "hit_cd": 0.0, "pflash": 0.0,
	}
	if kit.has("mob"):     # static-GLB mob → procedural-animator state (skeletal clip path is unused, ap == null)
		_nodes[f["id"]]["mobanim"] = {
			"profile": str(kit["mob"]), "target": kit.get("animTarget"),
			"baseY": float(kit.get("baseY", 0.0)), "sizeY": float(kit.get("sizeY", 1.0)),
			"t": 0.0, "atk": 0.0, "atkType": "", "hit": 0.0, "death": 0.0,
			"pcds": (f.get("cds", {}) as Dictionary).duplicate(),   # primed — same spawn-phantom guard
		}

# ============================================================ main loop
func _process(delta: float) -> void:
	if _state.is_empty():
		return
	# 1) input → intent (before the tick, zero-lag)
	if _player != null:
		_player.poll(_yaw)

	# 2) fixed-step authoritative sim. Practice arena: never let a winner latch.
	_acc += delta
	var steps := 0
	while _acc >= SIM_DT and steps < 5:
		_state["winner"] = null
		Sim.sim_tick(_state, SIM_DT)
		_acc -= SIM_DT
		steps += 1
		_handle_events()
		_tick_respawns(SIM_DT)
	if steps == 5:
		_acc = 0.0

	_render_world(delta)

	# Phase 3: persist position to the account's character every 10s
	if supa != null and char_id != "" and not _quitting:
		_save_t += delta
		if _save_t >= 10.0:
			_save_t = 0.0
			_save_progress()

# Render the current _state — shared by the LOCAL sandbox and the networked client (which
# fills _state from server snapshots instead of ticking the sim locally).
func _render_world(delta: float) -> void:
	_sync_projectiles()
	_update_fx(delta)
	var pf = _find_fighter(_player_id)
	if pf != null:
		var tf := _world(pf)
		tf.y = 1.4
		_focus = _focus.lerp(tf, clampf(delta * 5.0, 0.0, 1.0))
	_update_cam()

	for f in _state["fighters"]:
		var n = _nodes.get(f["id"])
		if n == null:
			continue
		_detect_cast(n, f)
		n["hit_cd"] = maxf(0.0, n["hit_cd"] - delta)
		if float(f["flash"]) > 0.0 and float(n.get("flash_prev", 0.0)) <= 0.0:   # fresh hit → flash the struck body
			_start_flash(n)
			_flashing[f["id"]] = true
		n["flash_prev"] = f["flash"]
		# render-only hitstop: hold this node's lerp + anim for a beat; the snap-forward on release is the
		# bite. pflash is deliberately NOT consumed during a hold, so the flinch edge survives to post-hold.
		var hold: float = float(n.get("hold", 0.0))
		if hold > 0.0:
			hold -= delta
			n["hold"] = hold
			if hold > 0.0:
				if f["alive"]:
					_update_ui(n, f)
				continue
			if n["anim"] != null:
				(n["anim"] as AnimationPlayer).speed_scale = 1.0
		if not f["alive"]:
			_drive_anim(n, f, false)
			n["pflash"] = f["flash"]
			continue
		var holder: Node3D = n["holder"]
		var target := _world(f)
		var tvel := Vector2(target.x - n["last"].x, target.z - n["last"].z)
		n["last"] = target
		n["vel"] = n["vel"].lerp(tvel, clampf(delta * 7.0, 0.0, 1.0))
		holder.position = holder.position.lerp(target, clampf(delta * 14.0, 0.0, 1.0))
		var moving: bool = n["vel"].length() > 0.0016
		# The run clip used to linger while the body glided to a stop (server-side momentum). Cut it sooner:
		# a higher bar for the run animation, and for the LOCAL player gate it on live input so it stops the
		# instant WASD releases (no glide-running) — facing still uses the smoothed velocity below.
		var anim_moving: bool = n["vel"].length() > 0.010
		if f["id"] == _player_id and _player != null:
			# run only while actively holding a direction AND actually displacing — so it stops the instant
			# keys release (no glide-run) yet doesn't run-in-place when held against a wall or rooted/stunned
			var pressing: bool = absf(float(_player.intent.get("mx", 0.0))) > 0.05 or absf(float(_player.intent.get("my", 0.0))) > 0.05
			anim_moving = pressing and n["vel"].length() > 0.004
		# face heading while moving, else the nearest enemy
		var flip: float = PI if MESHY_FLIP else 0.0
		var model: Node3D = n["model"]   # scale is constant (set at spawn) — idle stands tall, run crouches, blended
		var tgt_yaw: float = model.rotation.y
		if moving:
			tgt_yaw = atan2(n["vel"].x, n["vel"].y) + flip
		else:
			var ed := _enemy_dir(f)
			if ed != Vector2.ZERO:
				tgt_yaw = atan2(ed.x, ed.y) + flip
		model.rotation.y = lerp_angle(model.rotation.y, tgt_yaw, clampf(delta * 9.0, 0.0, 1.0))
		_drive_anim(n, f, anim_moving)
		_update_ui(n, f)
		n["pflash"] = f["flash"]

	_resize_arena()
	_render_portals()
	_render_zones()
	_render_obstacles()
	_render_decals()
	_update_coords()               # dev: F3 sim-space coord readout under the cursor (map authoring)
	_update_deco()                 # dev: while a prop is grabbed (G), it follows the cursor
	_update_hud()
	_drive_screen_juice()          # P4: low-HP vignette + death overlay + toast reflow (single call site)

# Draw the zone's purely-visual decoration (training drill rings + traffic cones) for camp identity. Read
# from World.DECALS for the current map (client-side, not sent over the wire); rebuilt only on a map change.
func _render_decals() -> void:
	var decals: Array = _state["decals"] if _state.has("decals") else _decals_for(str(_state.get("map", "")))
	var sig := JSON.stringify(decals)
	if sig == _decals_sig:
		return
	_decals_sig = sig
	if _decal_root != null:
		_decal_root.queue_free()
		_decal_root = null
	if decals.is_empty() or _world_root == null:
		return
	_decal_root = Node3D.new()
	_world_root.add_child(_decal_root)
	for d in decals:
		var pos := Vector3((float(d["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(d["y"]) - _ah() / 2.0) * SCALE)
		if str(d["kind"]) == "ring":
			var ring := MeshInstance3D.new()
			var tm := TorusMesh.new()
			var rr: float = float(d["r"]) * SCALE
			tm.outer_radius = rr
			tm.inner_radius = rr - 0.18                  # a thin painted line
			ring.mesh = tm
			var rmat := _mat(Color(0.95, 0.82, 0.25))    # painted yellow
			rmat.emission_enabled = true
			rmat.emission = Color(0.95, 0.82, 0.25)
			rmat.emission_energy_multiplier = 0.3
			ring.material_override = rmat
			ring.position = pos + Vector3(0.0, 0.04, 0.0)
			_decal_root.add_child(ring)
		elif str(d["kind"]) == "cone":
			var cone := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.0
			cm.bottom_radius = 0.32
			cm.height = 0.8
			cone.mesh = cm
			cone.material_override = _mat(Color(1.0, 0.45, 0.1))   # traffic orange
			cone.position = pos + Vector3(0.0, 0.4 + float(d.get("oy", 0.0)), 0.0)
			_decal_root.add_child(cone)
		elif str(d["kind"]) == "prop":                       # set-dressing GLB (e.g. the heavy bag) — no collision
			var pe := _prop_entry(str(d.get("model", "bag")))
			if pe["scene"] != null:
				var pi = pe["scene"].instantiate()
				var psc: float = float(d.get("h", 3.0)) / float(pe["h"])
				pi.scale = Vector3(psc, psc, psc)
				pi.position = pos + Vector3(0.0, -float(pe["min_y"]) * psc + float(d.get("oy", 0.0)), 0.0)   # oy = vertical lift (stacking)
				pi.rotation.y = float(d.get("yaw", 0.0))
				_decal_root.add_child(pi)

# Draw the zone's cover obstacles (sent in the snapshot) as themed padded training barriers — navy pads
# with a yellow safety stripe. They double as the gameplay cover (collision/LOS/projectile-block live in
# the sim) and the zone's visual identity. Rebuilt only when the obstacle set changes (per zone), like portals.
const OBSTACLE_PAD := 14.0                            # the sim blocks fighters at obstacle r + this (AI.separation) — fill the prop to here so there's no gap

# Lazily load a prop GLB + its AABB (footprint + height + ground offset), cached.
# GLB search folders for a prop/decal id, first hit wins: the Meshy cover props, then the free Kenney
# CC0 kits (models/kits/nature + /city). Lets DECALS/OBSTACLES reference any kit prop by bare basename
# (e.g. "tree_oak", "rock_largeA", "building-a") with no per-asset wiring or Meshy credits.
const PROP_DIRS := ["res://models/meshy/props/", "res://models/kits/nature/", "res://models/kits/city/"]

func _prop_entry(id: String) -> Dictionary:
	if _prop_cache.has(id):
		return _prop_cache[id]
	var path := ""
	for d in PROP_DIRS:                          # first folder that actually has <id>.glb wins
		var cand: String = d + id + ".glb"
		if ResourceLoader.exists(cand):
			path = cand
			break
	if path == "":
		push_warning("[prop] no GLB found for id '%s' under %s" % [id, str(PROP_DIRS)])
	var e := {"scene": null, "min_y": 0.0, "foot": 1.0, "h": 1.0}
	if path != "" and ResourceLoader.exists(path):
		e["scene"] = load(path)
		var inst = e["scene"].instantiate()
		var acc := {"have": false, "aabb": AABB()}
		_merge_mesh_aabb(inst, inst.transform, acc)
		inst.free()
		var a: AABB = acc["aabb"]
		e["min_y"] = a.position.y
		e["foot"] = maxf(maxf(a.size.x, a.size.z), 0.001)
		e["h"] = maxf(a.size.y, 0.001)
	_prop_cache[id] = e
	return e

func _render_obstacles() -> void:
	# the cover-panel entries ({x,y,prop,len,yaw}) come from World by map (client-side, like decals), or the
	# debug override in the --practice sandbox. The prop is scaled to `len` (uniform → depth/height follow)
	# and oriented along `yaw` to line up with the collision-circle row the server generated from the same data.
	var obs: Array = _state["obstacles"] if _state.has("obstacles") else World.obstacles_for(str(_state.get("map", "")))
	var sig := JSON.stringify(obs)
	if sig == _obstacles_sig:
		return
	_obstacles_sig = sig
	if _obstacle_root != null:
		_obstacle_root.queue_free()
		_obstacle_root = null
	if obs.is_empty() or _world_root == null:
		return
	_obstacle_root = Node3D.new()
	_world_root.add_child(_obstacle_root)
	for o in obs:
		var pos := Vector3((float(o["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(o["y"]) - _ah() / 2.0) * SCALE)
		var e := _prop_entry(str(o.get("prop", "barrier")))
		if e["scene"] == null:
			continue
		var inst = e["scene"].instantiate()
		var sc: float = float(o.get("len", 80.0)) * SCALE / float(e["foot"])   # uniform: footprint long axis → len, full natural height
		inst.scale = Vector3(sc, sc, sc)
		inst.position = pos + Vector3(0.0, -float(e["min_y"]) * sc, 0.0)   # ground (feet at y=0)
		inst.rotation.y = -float(o.get("yaw", 0.0))        # align the prop's long axis with the panel direction
		_obstacle_root.add_child(inst)

# Draw hazard zones (damaging/slow ground areas, sent in the snapshot) as translucent emissive discs so
# players can see + avoid them. Rebuilt only when the set changes (cheap), like _render_portals. Red =
# damaging, amber = slow-only.
func _render_zones() -> void:
	var zones: Array = _state.get("zones", [])
	var sig := JSON.stringify(zones)
	if sig == _zones_sig:
		return
	_zones_sig = sig
	if _zone_root != null:
		_zone_root.queue_free()
		_zone_root = null
	if zones.is_empty() or _world_root == null:
		return
	_zone_root = Node3D.new()
	_world_root.add_child(_zone_root)
	for z in zones:
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		var rr: float = float(z["radius"]) * SCALE
		cyl.top_radius = rr
		cyl.bottom_radius = rr
		cyl.height = 0.06
		disc.mesh = cyl
		var col: Color = Color(1.0, 0.3, 0.25) if float(z.get("dmg", 0.0)) > 0.0 else Color(1.0, 0.7, 0.2)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(col.r, col.g, col.b, 0.28)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = 1.1
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		disc.material_override = mat
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		disc.position = Vector3((float(z["x"]) - _aw() / 2.0) * SCALE, 0.07, (float(z["y"]) - _ah() / 2.0) * SCALE)
		_zone_root.add_child(disc)

# Draw the current world's portal pads (sent in the snapshot). Rebuilt only when they change
# (i.e. when you cross into the other world), so it's cheap.
func _render_portals() -> void:
	var portals: Array = _state.get("portals", [])
	var sig := JSON.stringify(portals)
	if sig == _portals_sig:
		return
	_portals_sig = sig
	if _portal_root != null:
		_portal_root.queue_free()
		_portal_root = null
	if portals.is_empty() or _world_root == null:
		return
	_portal_root = Node3D.new()
	_world_root.add_child(_portal_root)
	for p in portals:
		var pos := Vector3((float(p["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(p["y"]) - _ah() / 2.0) * SCALE)
		var pillar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = World.PORTAL_RADIUS * SCALE
		cyl.bottom_radius = World.PORTAL_RADIUS * SCALE
		cyl.height = 3.0
		pillar.mesh = cyl
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.35, 0.8, 1.0, 0.32)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = Color(0.4, 0.85, 1.0)
		mat.emission_energy_multiplier = 1.6
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		pillar.material_override = mat
		pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pillar.position = pos + Vector3(0.0, 1.5, 0.0)
		_portal_root.add_child(pillar)
		var lbl := Label3D.new()
		lbl.text = str(p.get("label", "Portal"))
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.fixed_size = true
		lbl.pixel_size = WorldUI.PAD_PIXEL
		lbl.font_size = WorldUI.PAD_FONT
		lbl.outline_size = WorldUI.PAD_OUTLINE
		lbl.outline_modulate = WorldUI.OUTLINE_COLOR
		lbl.modulate = Color(0.65, 0.92, 1.0)
		lbl.position = pos + Vector3(0.0, 3.7, 0.0)
		_portal_root.add_child(lbl)

func _handle_events() -> void:
	var gains := {}                    # "type|src|tgt" → summed amt. One floater per batch: a Setter
	for ev in _state["events"]:        # echo (two same-tick heals) or a multi-hit stack would otherwise
		var t = ev.get("type", "")     # superpose two lockstep numbers at the same spot — illegible
		_meter_accum(str(t), ev)       # §4a meter: tap the RAW events (pre-coalescing, pre-clear)
		if t == "dmg":
			var tgt := str(ev["tgt"])
			var crit := bool(ev["crit"])
			var taken := tgt == _player_id                 # I got hit
			var dealt := str(ev.get("src", "")) == _player_id   # I landed the hit
			if bool(ev.get("proc", false)):
				# passive proc/DOT damage (item burns, hazard ticks) — a soft accumulating number only.
				# None of the impact stack: no sound/pop/shake/kick/hitstop, the attacker keeps swinging.
				_spawn_num(tgt, int(ev["amt"]), false, taken, dealt, "burn")
				continue
			var tf = _find_fighter(tgt)
			var sf = _find_fighter(str(ev.get("src", "")))      # attacker (null once out of interest)
			_spawn_num(tgt, int(ev["amt"]), crit, taken, dealt)
			# hit burst in the ATTACKER's class signature color; crits stay gold so they read at a glance
			_spawn_pop(tgt, crit, _class_vfx_color(str(sf["classId"])).lightened(0.25) if sf != null else Color(1, 0.95, 0.7))
			if crit and tf != null:
				_spawn_shards(tf, 3, _class_vfx_color(str(tf["classId"])))
			# damage-scaled audio: a bigger chunk of the target's HP sits lower + louder; slight random
			# detune so repeats don't fatigue. My own landed hit takes the dedicated flat punch voice.
			var tfrac: float = (float(ev["amt"]) / maxf(1.0, float(tf["maxHP"]))) if tf != null else 0.0
			var sname := "crit" if crit else "hit"
			if dealt:
				AudioManager.play_punch(sname, (1.06 - tfrac * 0.22) * randf_range(0.94, 1.06), -2.0 + minf(tfrac, 0.5) * 8.0)
			elif tf != null:
				AudioManager.play_sfx(sname, _world(tf), randf_range(0.92, 1.08), 0.0 if taken else -5.0)
			var pf = _find_fighter(_player_id)
			if taken:                                       # shake when I take damage (more for a big/crit hit)
				var frac: float = (float(ev["amt"]) / maxf(1.0, float(pf["maxHP"]))) if pf != null else 0.0
				_add_shake(clampf(0.15 + frac * 2.4 + (0.12 if crit else 0.0), 0.0, SHAKE_MAX))
			if dealt and tf != null and pf != null:         # kick the camera INTO the hit you landed
				_add_cam_kick(_world(tf) - _world(pf), KICK_AMT * clampf(0.35 + tfrac * 2.0 + (0.4 if crit else 0.0), 0.0, 1.0))
				if crit:
					_add_fov_kick(FOV_KICK_CRIT)
			if dealt or taken:                              # render-only hitstop, scoped to impacts I'm part of
				var hs := HITSTOP_CRIT if crit else HITSTOP_HIT
				_add_hitstop(tgt, hs)
				_add_hitstop(str(ev.get("src", "")), hs)
			# Tier-2 struck-body give: push away from the hit, damage/crit-scaled (a kill re-arms harder)
			var rdir := Vector3.ZERO
			if sf != null and tf != null:
				rdir = _world(tf) - _world(sf)
			_add_recoil(tgt, rdir, clampf(0.55 + tfrac * 1.8, 0.55, 1.0) * (RECOIL_CRIT if crit else 1.0))
		elif t == "heal" or t == "shield":
			var gk := "%s|%s|%s" % [str(t), str(ev.get("src", "")), str(ev["tgt"])]
			gains[gk] = int(gains.get(gk, 0)) + int(ev["amt"])
		elif t == "kill":
			var victim := str(ev["victim"])
			var vf = _find_fighter(victim)
			_spawn_death(victim)
			if vf != null:
				AudioManager.play_sfx("death", _world(vf), randf_range(0.96, 1.04))
			var kf = _find_fighter(str(ev.get("killer", "")))
			var kdir := Vector3.ZERO
			if kf != null and vf != null:
				kdir = _world(vf) - _world(kf)
			_add_recoil(victim, kdir, RECOIL_KILL)          # the death blow hits hardest
			if vf != null and (str(ev.get("killer", "")) == _player_id or victim == _player_id):
				_spawn_shards(vf, randi_range(6, 8), _class_vfx_color(str(vf["classId"])))
			if str(ev.get("killer", "")) == _player_id:
				_add_shake(0.35)                            # a satisfying thump on your kill
				_add_fov_kick(FOV_KICK_KILL)
				_add_hitstop(victim, HITSTOP_KILL)          # the heaviest beat: freeze both parties a moment
				_add_hitstop(_player_id, HITSTOP_KILL)
			elif victim == _player_id:
				_add_shake(SHAKE_MAX)                       # you died — full shake
	for gk in gains:
		var gp: PackedStringArray = (gk as String).split("|")
		# gain floaters (green heal / blue absorb) — pure info layer, never the impact stack
		_spawn_num(gp[2], int(gains[gk]), false, gp[2] == _player_id, gp[1] == _player_id, gp[0])
	_state["events"].clear()

func _tick_respawns(dt: float) -> void:
	for f in _state["fighters"]:
		if not f["alive"] and not _respawn.has(f["id"]):
			_respawn[f["id"]] = RESPAWN_DELAY
	var done := []
	for id in _respawn:
		_respawn[id] -= dt
		if _respawn[id] <= 0.0:
			done.append(id)
	for id in done:
		_respawn.erase(id)
		_revive(_find_fighter(id))

# Reset a dead fighter to a fresh combat state at its spawn (training-arena respawn).
func _revive(f) -> void:
	if f == null:
		return
	f["hp"] = f["maxHP"]
	f["alive"] = true
	f["shield"] = 0.0
	f["shieldT"] = 0.0
	f["casting"] = null
	f["stun"] = 0.0
	f["slowT"] = 0.0
	f["slowAmt"] = 0.0
	f["evade"] = 0.0
	f["untarget"] = 0.0
	f["flash"] = 0.0
	f["dots"] = []
	f["_dotAcc"] = {}
	f["_dotEvT"] = 1.0
	f["buffs"] = {"nextdmg": 0.0, "crit": 0.0, "critT": 0.0, "atkspd": 1.0, "atkspdT": 0.0,
		"dr": 0.0, "drT": 0.0, "ms": 1.0, "msT": 0.0, "bypass": 0.0, "reflect": 0.0}
	f["momentum"] = 0.0
	f["momentumT"] = 0.0
	f["barrier"] = 0.0
	f["barrierT"] = 0.0
	f["barrierStored"] = 0.0
	f["_barrierAb"] = null
	f["hatTarget"] = null
	f["hatCount"] = 0
	f["hatChainT"] = 0.0
	f["noDmgT"] = 0.0
	f["atkCommitT"] = 0.0
	f["chaseT"] = 0.0
	for k in f["cds"]:
		f["cds"][k] = 0.0
	# restore the remaining create_fighter fields so a respawn == a fresh spawn (port parity)
	f["supportCasts"] = 0
	f["deathT"] = 0.0
	f["_pocketDR"] = 0.0
	f["lastCastKey"] = ""
	f["dmgDealt"] = 0.0
	f["dmgTaken"] = 0.0
	f["healing"] = 0.0
	f["mitigated"] = 0.0
	f["kills"] = 0
	f["hx"] = float(1 if f["team"] == 0 else -1)
	f["hy"] = 0.0
	f["facing"] = 1 if f["team"] == 0 else -1
	f["strafeDir"] = 1 if (f["team"] + f["slot"]) % 2 == 0 else -1
	f["moveMode"] = "approach"
	f["flipT"] = 0.0
	# drop any input queued while dead so it doesn't auto-fire on the first revived tick
	if _player != null and f["id"] == _player_id:
		_player.intent["ability"] = ""
	var sp: Vector2 = _spawn_pos[f["id"]]
	f["x"] = sp.x
	f["y"] = sp.y
	var n = _nodes.get(f["id"])
	if n != null:
		n["died"] = false
		n["busy"] = ""
		n["ui"].visible = true
		n["holder"].position = _world(f)
		n["last"] = n["holder"].position
		n["vel"] = Vector2.ZERO
		if n["anim"] != null:
			_safe_play(n["anim"], n["anims"].get("idle", "idle"))

# ============================================================ animation
func _safe_play(ap: AnimationPlayer, clip: String, speed := 1.0) -> void:
	if ap != null and ap.has_animation(clip):
		ap.play(clip, -1, speed)

# Meshy action clips bake huge root (Hips) translation — the hit clip drifts ~128u, sliding the whole
# mesh off its ground ring. The server owns position, so action animation must play IN PLACE: pin the
# Hips X/Z (and Y, except for the death collapse) to the clip's first frame. Idempotent; no-op on the
# already-clean idle/run/walk. (Path is "Armature/Skeleton3D:Hips" across all four rigs.)
static func _strip_root_motion(clip: Animation, clamp_y: bool) -> void:
	for i in clip.get_track_count():
		if clip.track_get_type(i) != Animation.TYPE_POSITION_3D:
			continue
		if not str(clip.track_get_path(i)).ends_with(":Hips"):
			continue
		var kc := clip.track_get_key_count(i)
		if kc == 0:
			return
		var base: Vector3 = clip.track_get_key_value(i, 0)
		for k in kc:
			var v: Vector3 = clip.track_get_key_value(i, k)
			v.x = base.x
			v.z = base.z
			if clamp_y:
				v.y = base.y
			clip.track_set_key_value(i, k, v)
		return

# The Meshy idle clip bakes a Hips SCALE of ~1.176 (the character balloons 17% when idle, then snaps
# back the instant it runs/acts — reads as a shrink). No other clip animates scale, so remove any Hips
# scale track → the bone uses its rest scale and the character stays one constant size.
static func _strip_hips_scale(clip: Animation) -> void:
	for i in range(clip.get_track_count() - 1, -1, -1):
		if clip.track_get_type(i) == Animation.TYPE_SCALE_3D and str(clip.track_get_path(i)).ends_with(":Hips"):
			clip.remove_track(i)

func _ability_type(class_id: String, key) -> String:
	if key == null or key == "":
		return ""
	if not GameData.CLASSES.has(class_id):       # defensive: a stale client vs a newer server (new mob type) must not crash on cast
		return ""
	for ab in GameData.CLASSES[class_id]["abilities"]:
		if ab["key"] == key:
			return ab["type"]
	return ""

# ability → the render clip for this rig (shared by _detect_cast and the predicted-press path)
func _clip_for_ability(class_id: String, key, anims: Dictionary) -> String:
	if ANIM_OVERRIDE.has(class_id) and ANIM_OVERRIDE[class_id].has(key):
		return str(ANIM_OVERRIDE[class_id][key])
	var t := _ability_type(class_id, key)
	if t == "projectile" or t == "barrage":
		return str(anims.get("ranged", ""))
	elif t == "melee" or t == "meleeAoe" or t == "dashAttack" or t == "leapAttack":
		return str(anims.get("melee", ""))
	elif t == "selfbuff" or t == "allybuff" or t == "allyheal" or t == "teamheal" or t == "zone" or t == "barrier" or t == "summon":
		return str(anims.get("cast", ""))
	return ""

func _ability_def(class_id: String, key) -> Dictionary:
	if GameData.CLASSES.has(class_id):
		for ab in GameData.CLASSES[class_id]["abilities"]:
			if ab["key"] == key:
				return ab
	return {}

# The cast-sound slot for an ability: ults keep the big cast_ult, support casts stay gentle, and
# everything else takes the class's signature sport sound (cast_<classId>) when that file exists —
# falling back to the generic role sound so mobs / new classes never regress to silence.
func _cast_sfx_name(class_id: String, key) -> String:
	var ab := _ability_def(class_id, key)
	if ab.get("ult", false):
		return "cast_ult"
	var role := "cast_ability"
	match str(ab.get("type", "")):
		"melee", "meleeAoe", "dashAttack", "leapAttack": role = "cast_melee"
		"projectile", "barrage": role = "cast_ranged"
		"allybuff", "allyheal", "teamheal": return "cast_support"
	var sig := "cast_" + class_id
	return sig if AudioManager.has_sfx(sig) else role

# Detect a fresh cast by a cooldown rising, then queue the right one-shot clip.
func _detect_cast(n: Dictionary, f: Dictionary) -> void:
	if float(n.get("hold", 0.0)) > 0.0:
		return    # hitstop: defer edge processing — the swing/sound fires the frame the hold releases
	var pred: Dictionary = n.get("pred_cast", {})    # ability key → remaining confirm window (local player only)
	if not pred.is_empty():
		for pk in pred.keys():
			pred[pk] = float(pred[pk]) - get_process_delta_time()
			if float(pred[pk]) <= 0.0:
				pred.erase(pk)
	var atk := ""
	var spd := 1.0
	var risen := []                       # every cooldown that rose this frame (several can pile up
	for k in f["cds"]:                    # in one frame after a hitstop hold deferred detection)
		if f["cds"][k] > float(n["pcds"].get(k, 0.0)) + 0.05:
			risen.append(k)
	# handle ONE edge per frame (a node can only start one clip anyway); the rest keep their stale
	# pcds entry below so they re-detect next frame instead of being silently swallowed.
	if not risen.is_empty():
		var k = risen[0]
		if pred.has(k):
			pred.erase(k)     # this cast was fully told (sound + swing) on the keypress — just consume
		else:
			# audible anticipation: a visible fighter's cast plays its (class-signature) sound
			# positionally. Others' BASICS stay silent — their landed hits already sound, and a
			# camp of mobs on ~1.2s basics would drone the 12-voice pool dry.
			var own: bool = f["id"] == _player_id
			if own or not bool(_ability_def(str(f["classId"]), k).get("basic", false)):
				AudioManager.play_sfx(_cast_sfx_name(str(f["classId"]), k), _world(f), randf_range(0.95, 1.05), 0.0 if own else -6.0)
				_spawn_flourish(f, str(f["classId"]))   # class-colored cast ring, same restraint as the sound
			atk = _clip_for_ability(str(f["classId"]), k, n["anims"])
			if atk != "":
				spd = _cast_speed(n["anim"], atk, float(f["cds"][k]))   # snap to the ability's cadence
	var newp: Dictionary = f["cds"].duplicate()
	for i in range(1, risen.size()):
		newp[risen[i]] = n["pcds"].get(risen[i], 0.0)     # still pending — fires on the next frame
	n["pcds"] = newp
	n["atk_clip"] = atk
	n["atk_speed"] = spd

# Client-side "this press should be accepted" gate — everything the client can know locally (off
# cooldown, alive, not stunned / mid-cast; stun/casting only exist in local-sim state, so networked
# snapshots simply skip those checks). The server still validates for real; this only decides whether
# to show the predicted tell.
func _can_press(key: String) -> bool:
	var pf = _find_fighter(_player_id)
	if pf == null or not bool(pf.get("alive", true)):
		return false
	if float((pf.get("cds", {}) as Dictionary).get(key, 0.0)) > 0.0:
		return false
	if float(pf.get("stun", 0.0)) > 0.0 or pf.get("casting") != null:
		return false
	return true
	# NOTE: deliberately no _pred_cds gate here — a re-press while a prediction is in flight may be the
	# press the server actually ACCEPTS (mash-while-closing-range), and it must re-tell + re-arm the
	# consume record. Mash spam is tamed by the per-key sound throttle + the no-restart swing guard.

# Predicted press feedback — kill the input-lag feel at its source: the instant a valid press is sent,
# play the swing on the local render node, depress the hotbar slot, and start a predicted cooldown
# sweep. All cosmetic + self-correcting: the server resolves the real cast, _detect_cast consumes the
# confirming cooldown edge (no double swing), and _update_hotbar snaps the sweep back if no cooldown
# ever shows up (out-of-range / stun the client didn't model). Nothing irreversible fires here.
func _predict_cast(key: String) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	var cid := str(pf["classId"])
	if not GameData.CLASSES.has(cid):
		return
	var ab = null
	var slot := -1
	var abilities: Array = GameData.CLASSES[cid]["abilities"]
	for i in abilities.size():
		if abilities[i]["key"] == key:
			ab = abilities[i]
			slot = i
			break
	if ab == null:
		return
	var window: float = PRED_CD_WINDOW + float(ab.get("cast", 0.0))
	var n = _nodes.get(_player_id)
	if n != null:
		if n["anim"] != null:                             # (a) the swing, this exact frame (under a
			var clip := _clip_for_ability(cid, key, n["anims"])   # hitstop hold it starts frozen and runs
			var ap: AnimationPlayer = n["anim"]                   # from the release snap)
			# a mash re-press inside the confirm window doesn't restart a swing that's already showing
			if clip != "" and not (n["busy"] == clip and ap.is_playing() and ap.current_animation == clip):
				n["busy"] = clip
				_safe_play(ap, clip, _cast_speed(ap, clip, float(ab.get("cd", 0.0))))
		var pending: Dictionary = n.get("pred_cast", {})
		if not pending.has(key):       # fresh prediction (not a mash re-press) → the class-colored cast ring
			_spawn_flourish(pf, cid)   # fires on the press frame; _detect_cast's consume skips the re-tell
		pending[key] = window          # per-key consume record: the confirm edge won't re-tell this cast
		n["pred_cast"] = pending
	if slot >= 0 and slot < _slots.size():                # (b) instant hotbar depress
		_slots[slot]["press"] = 1.0
	var total: float = float(ab.get("cd", 0.0))
	if total > 0.0:                                       # (c) predicted cooldown sweep
		_pred_cds[key] = {"t": 0.0, "total": total, "window": window}

# Speed so an action clip plays in ~CAST_DUR_FRAC of the ability's cooldown (clamped). Only ever speeds
# up (>=1x); cap at 6x to avoid a blur. cd = the cooldown just set by the cast (its rising-edge value).
func _cast_speed(ap: AnimationPlayer, clip: String, cd: float) -> float:
	if ap == null or not ap.has_animation(clip):
		return 1.0
	var clen: float = ap.get_animation(clip).length
	if clen <= 0.0:
		return 1.0
	var target := clampf(cd * CAST_DUR_FRAC, CAST_DUR_MIN, CAST_DUR_MAX)
	return clampf(clen / target, 1.0, 6.0)

func _drive_anim(n: Dictionary, f: Dictionary, moving: bool) -> void:
	if n.has("mobanim"):                  # static-GLB mobs: procedural transform animation, no AnimationPlayer
		_drive_mob_anim(n, f)
		return
	var ap: AnimationPlayer = n["anim"]
	if ap == null:
		return
	var am: Dictionary = n["anims"]
	if not f["alive"]:
		if not n["died"]:
			n["died"] = true
			n["ui"].visible = false
			_safe_play(ap, am.get("death", "death"))
		return
	# never interrupt a one-shot (attack/cast/hit) still playing
	if n["busy"] != "" and ap.is_playing() and ap.current_animation == n["busy"]:
		return
	n["busy"] = ""
	if n["atk_clip"] != "":
		n["busy"] = n["atk_clip"]
		_safe_play(ap, n["atk_clip"], n.get("atk_speed", 1.0))   # snappy, scaled to the ability's cadence
	elif f["flash"] > 0.0 and n["pflash"] <= 0.0 and n["hit_cd"] <= 0.0:
		n["busy"] = am.get("hit", "hit")
		n["hit_cd"] = HIT_FLINCH_CD
		_safe_play(ap, am.get("hit", "hit"), HIT_SPEED)   # snappy in-place flinch (root motion stripped at load)
	else:
		var clip: String = am.get("run", "run") if moving else am.get("idle", "idle")
		if ap.current_animation != clip or not ap.is_playing():
			_safe_play(ap, clip)

# Procedural client-side animator for static-GLB mobs. Drives the inner anim_node's Transform3D
# (the outer pivot owns facing-yaw + base scale; the glb keeps its imported transform) from the same
# inferred state the skeletal driver uses: movement intensity (n.vel), a rising-cooldown cast edge, the
# hit flash, and alive/dead. Purely cosmetic → no determinism impact. Per-profile gestures keep each
# enemy distinct (cone skitters, the dummy leans into swings, the brute winds up, the turret spins/recoils).
func _drive_mob_anim(n: Dictionary, f: Dictionary) -> void:
	var ma: Dictionary = n["mobanim"]
	var tgt = ma["target"]
	if not is_instance_valid(tgt):
		return
	var dt := get_process_delta_time()
	var sy: float = ma["sizeY"]
	var by: float = ma["baseY"]
	# death collapse — sink + topple + shrink. n["died"] gates the one-shot UI hide (and the netclient
	# respawn-reset which restores visibility + snaps to spawn).
	if not f["alive"]:
		if not n["died"]:
			n["died"] = true
			n["ui"].visible = false
		ma["death"] = minf(1.0, ma["death"] + dt * 2.2)
		var dp: float = ma["death"]
		tgt.position = Vector3(0.0, by - dp * sy * 0.42, 0.0)
		tgt.rotation = Vector3(dp * 1.25, 0.0, dp * 0.45)
		var ds: float = 1.0 - dp * 0.32
		tgt.scale = Vector3(ds, ds, ds)
		return
	if ma["death"] > 0.0:                          # revived → clear the collapse pose
		ma["death"] = 0.0
	ma["t"] += dt
	# fresh-cast detection: a cooldown that rose this frame (mirrors _detect_cast's rising edge)
	for k in f["cds"]:
		if f["cds"][k] > float(ma["pcds"].get(k, 0.0)) + 0.05:
			ma["atk"] = 1.0                # fresh cast → trigger the action gesture
			ma["atkType"] = _ability_type(str(f["classId"]), k)   # pick a gesture matching the ability
			break
	ma["pcds"] = f["cds"].duplicate()
	if f["flash"] > 0.0 and n["pflash"] <= 0.0:   # took a hit this frame → recoil
		ma["hit"] = 1.0
	ma["atk"] = maxf(0.0, ma["atk"] - dt * 3.2)
	ma["hit"] = maxf(0.0, ma["hit"] - dt * 4.0)

	var prof: String = ma["profile"]
	var a: float = ma["atk"]
	var at: String = str(ma.get("atkType", ""))   # which ability fired → an ability-accurate gesture
	var q: float = ma["hit"]
	var movef: float = clampf(n["vel"].length() / 0.12, 0.0, 1.0)
	var t: float = ma["t"]
	# bob = vertical breathe; gestures are picked to match the ABILITY that fired (at): a melee punch leans
	# forward, a turret shot recoils backward, a slam squashes, a guard/brace hunkers. Limbs can't articulate
	# (static GLB, no skeleton) so whole-body motion carries it.
	var hz := 2.0
	var amp := 0.04
	var pitch := 0.0
	var yaw := 0.0
	var roll := 0.0
	var lunge := 0.0                              # local +Z offset (forward +, recoil/back -)
	var sq := 1.0                                # uniform squash factor (1 = none)
	var hover := 0.0                             # constant vertical lift (0 = grounded); the power core floats
	match prof:
		"cone":                                     # legless cone: skitter + trip-jab hop
			hz = 6.0; amp = 0.06 + movef * 0.07
			roll = sin(t * 4.0 * TAU) * 0.07 + sin(t * 9.0 * TAU) * 0.12 * movef   # idle teeter + skitter
			sq = 1.0 - a * 0.22                          # squash on jab / Trip Dash
			lunge = a * 0.12 * sy                        # hop forward into the hit
		"brute":                                    # legless leather bag: SLIDES on the floor, no sway/wobble
			hz = 1.1; amp = 0.012 + movef * 0.012       # near-flat; the bag glides, it doesn't bounce
			if at == "meleeAoe":
				sq = 1.0 - a * 0.18                     # Rubber Slam → squash down
			elif at == "selfbuff":
				sq = 1.0 - a * 0.12                     # Brace Up → hunker / widen
			else:
				pitch = a * 0.3                         # slight forward tilt as it lurches/charges
				lunge = a * 0.20 * sy                   # strong forward slide (Impact Charge / Bag Bash)
		"turret":                                   # stationary cannon+shield torso: scan, recoil, shield-tilt
			hz = 2.2; amp = 0.018
			yaw = sin(t * 0.5 * TAU) * 0.30             # idle scan (no locomotion — it's stationary)
			if at == "selfbuff":
				roll = a * 0.28                         # Calibration/Reflect → tilt behind the shield
				pitch = -a * 0.12
			else:
				lunge = -a * 0.11 * sy                  # cannon recoil: kick backward on a shot
				pitch = -a * 0.10
		"sergeant":                                 # humanoid drill instructor (static GLB): bark + command lean
			hz = 2.0; amp = 0.04 + movef * 0.03
			roll = sin(t * 1.6 * TAU) * 0.04            # subtle idle sway
			pitch = 0.06 + a * 0.5                      # constant command lean + bark/clipboard jab forward on action
			lunge = a * 0.09 * sy
		"boss":                                     # the Head Coach — heavy + deliberate, more agitated each phase
			var ph: int = int(f.get("phase", 0))
			var uc: float = float(f.get("ultCast", 0.0))
			hz = 1.4 + ph * 0.25; amp = 0.05 + movef * 0.03 + ph * 0.008
			roll = sin(t * 1.3 * TAU) * (0.04 + ph * 0.015)   # idle sway, edgier late-fight
			pitch = 0.05 + a * 0.45                     # command lean + lunge on a clipboard/sled action
			lunge = a * 0.12 * sy
			if at == "meleeAoe": sq = 1.0 - a * 0.20    # Pancake/Shockwave slam squash
			if uc > 0.0:                                # Full Camp Reset wind-up: rear back, rise, and heave
				pitch = -0.32
				amp = 0.11
				sq = 1.0 + 0.10 * sin(t * 12.0)
		"core":                                     # power core — hover in place + gentle pulse (NO spin)
			hz = 1.6; amp = 0.05
			hover = sy * 0.45                       # float ~0.45×height off the ground (model is grounded by default)
			sq = 1.0 + sin(t * 3.0) * 0.04
		_:
			hz = 2.0; amp = 0.04
			pitch = a * 0.4
	pitch += movef * 0.16                                # lean into travel (skip for the stationary turret — movef≈0)
	pitch -= q * 0.5                                    # hit flinch back
	roll += q * sin(t * 30.0) * 0.06                    # brief shake on hit
	sq *= 1.0 - q * 0.12
	tgt.position = Vector3(0.0, by + hover + sin(t * hz * TAU) * amp * sy, lunge)
	tgt.rotation = Vector3(pitch, yaw, roll)
	tgt.scale = Vector3(sq, 1.0 + (1.0 - sq) * 0.6, sq)

func _update_ui(n: Dictionary, f: Dictionary) -> void:
	var ui: Node3D = n["ui"]
	ui.look_at(2.0 * ui.global_position - _cam.global_position, Vector3.UP)
	var frac: float = clampf(f["hp"] / f["maxHP"], 0.0, 1.0)
	var fill: MeshInstance3D = n["fill"]
	fill.scale.x = max(frac, 0.001)
	fill.position.x = -BAR_W / 2.0 * (1.0 - frac)
	(fill.material_override as StandardMaterial3D).albedo_color = WorldUI.hp_color(frac)   # 3-stop ramp
	var label: Label3D = n["label"]
	var nameLabel: Label3D = n["name"]
	nameLabel.visible = false                 # default: mobs have no name line; label carries their tier/level
	label.font_size = WorldUI.PLATE_FONT      # default mob/plate size; players shrink it below
	if f.get("dummy", false):
		label.text = "Training Dummy"
		label.modulate = WorldUI.DUMMY
	elif f.get("isCore", false):
		label.text = "◈ POWER CORE"
		label.modulate = WorldUI.CORE
	elif f.has("mobTier"):
		var tier: String = str(f["mobTier"])
		var lvl := int(f.get("mobLevel", 1))
		if tier == "boss":
			# the boss "scoreboard": current quarter/phase + an explicit Full Camp Reset countdown warning
			var ph := int(f.get("phase", 0))
			var uc := float(f.get("ultCast", 0.0))
			if uc > 0.0:
				label.text = "⚠  FULL CAMP RESET  %d  ⚠\nBREAK LINE OF SIGHT!" % int(ceil(uc))
				label.modulate = Color(1.0, 0.2, 0.2)
			elif f.get("shielded", false):
				# P3: core-shield cue — the boss is taking heavy DR while a power core lives (was invisible)
				var pn2 := ["EVALUATION", "CONDITIONING", "CONTACT", "RUN IT AGAIN"]
				label.text = "Lv %d  ☠ HEAD COACH\nQ%d · %s\n🛡 SHIELDED — DESTROY THE CORES" % [lvl, ph + 1, pn2[clampi(ph, 0, 3)]]
				label.modulate = Color(0.4, 0.82, 1.0)
			else:
				var pn := ["EVALUATION", "CONDITIONING", "CONTACT", "RUN IT AGAIN"]
				var pcol := [Color(1.0, 0.6, 0.42), Color(1.0, 0.48, 0.32), Color(1.0, 0.34, 0.26), Color(1.0, 0.22, 0.22)]
				label.text = "Lv %d  ☠ HEAD COACH\nQ%d · %s" % [lvl, ph + 1, pn[clampi(ph, 0, 3)]]
				label.modulate = pcol[clampi(ph, 0, 3)]
		elif tier == "elite":
			label.text = "Lv %d  ★ ELITE" % lvl
			label.modulate = WorldUI.MOB_ELITE
		else:
			label.text = "Lv %d" % lvl
			label.modulate = WorldUI.MOB_LEVEL
	elif f.has("level"):
		var lpf = _find_fighter(_player_id)
		var hostile: bool = lpf != null and _hostile_pair(lpf, f)
		# hostile players stay red (a threat cue); friendly plates read in their class color for identity
		var plate_col: Color = WorldUI.HOSTILE if hostile else WorldUI.friendly_plate(_class_vfx_color(str(f["classId"])))
		var nm := str(f.get("name", ""))
		if nm != "":                              # character name on top (prominent), resident marker rides it
			nameLabel.text = nm + ("  ◆" if f.get("resident", false) else "")
			nameLabel.modulate = plate_col
			nameLabel.visible = true
		label.font_size = WorldUI.PLATE_LEVEL     # level line is deliberately small, tucked under the name
		label.text = ("⚔ Lv %d" % int(f["level"])) if hostile else ("Lv %d" % int(f["level"]))
		label.modulate = plate_col
	elif label.text != "":
		label.text = ""
	# P3: Wobble stacks (0..4 = Sim.WOBBLE_MAX) as pips → the stumble no longer "just happens" without warning.
	var wob := float(f.get("wobble", 0.0))
	if wob > 0.0 and label.text != "":
		var lit := clampi(int(ceil(wob)), 0, 4)
		var pips := ""
		for i in 4:
			pips += "◆" if i < lit else "◇"
		label.text += "\n⟳ %s" % pips
		if lit >= 3:                              # near the stumble threshold → flash the whole plate amber-red
			label.modulate = Color(1.0, 0.55, 0.2)
	if n.get("aura") != null:                     # P3: show the boss's core-shield aura while a core lives
		n["aura"].visible = bool(f.get("shielded", false))
	var dye := str(f.get("dye", ""))              # P4: cosmetic dye — re-tint the model only when it changes
	if dye != str(n.get("dye_applied", "")):
		n["dye_applied"] = dye
		if not _flashing.has(f["id"]):            # mid-flash: don't stomp the overlay — the flash's
			_apply_dye(n.get("model"), dye)       # fade-end restore applies the new dye instead

# P4: tint a character model with a cosmetic dye via a flat translucent material OVERLAY (keeps the base
# texture, reversible with "" → null). Recurses the model's MeshInstance3D surfaces.
func _apply_dye(model, hexcolor: String) -> void:
	if model == null:
		return
	var overlay: Material = null
	if hexcolor != "":
		var m := StandardMaterial3D.new()
		var c := Color(hexcolor)
		c.a = 0.45                                # partial wash — dyed but the model still reads
		m.albedo_color = c
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		overlay = m
	_set_overlay_recursive(model, overlay)

# Hit-flash: a brief unshaded additive overlay on the struck body — the universal "it connected" pop.
# GOTCHA: material_overlay is the SAME channel the dye cosmetic uses, so the fade-out in _update_fx
# restores the fighter's dye (n["dye_applied"]) instead of just clearing. One material per node, reused.
func _start_flash(n: Dictionary) -> void:
	var model = n.get("model")
	if model == null or not is_instance_valid(model):
		return
	if n.get("flash_mat") == null:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.albedo_color = Color(1.0, 0.87, 0.72, FLASH_ALPHA)   # hot white-amber impact tint
		n["flash_mat"] = m
	(n["flash_mat"] as StandardMaterial3D).albedo_color.a = FLASH_ALPHA
	n["flash_t"] = FLASH_DUR
	_set_overlay_recursive(model, n["flash_mat"])

func _set_overlay_recursive(node: Node, overlay: Material) -> void:
	if node is BoneAttachment3D:
		return                                    # don't dye the held class prop (the Batter's bat, etc.)
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_overlay = overlay
	for ch in node.get_children():
		_set_overlay_recursive(ch, overlay)

# ============================================================ FX
# amt floater. `taken`/`dealt` = the local player is the target / the source. `style` picks the read:
# "dmg" impacts (red taken / white-gold dealt, dim for bystanders), "burn" passive proc ticks (ember,
# smolder-drift), "heal"/"shield" gains (green / absorb-blue, smaller than damage, gentle drift;
# self-heals and heals between others read quieter than heals I cast or receive).
func _spawn_num(tgt_id, amt: int, crit: bool, taken := false, dealt := false, style := "dmg") -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var l: Label3D
	if _num_pool.is_empty():
		l = Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.fixed_size = true
		l.pixel_size = 0.0011
		l.font_size = 96
		l.outline_size = 22
		l.outline_modulate = Color(0, 0, 0, 0.9)
		_fx_root.add_child(l)
	else:
		l = _num_pool.pop_back()
	l.visible = true
	var gain := style == "heal" or style == "shield"
	l.text = ("+%d" % amt) if gain else (("%d!" % amt) if crit else str(amt))
	var s := 1.0
	if style == "burn":                                 # passive proc/DOT tick = ember orange, understated
		l.modulate = Color(1.0, 0.55, 0.25) if taken else Color(1.0, 0.74, 0.38)
		s = 0.8 * (1.15 if taken else (1.0 if dealt else 0.7))
	elif gain:
		var c := Color(0.44, 0.88, 0.54) if style == "heal" else Color(0.5, 0.72, 1.0)
		var quiet := taken == dealt                     # my self-heal, or a heal between two others
		l.modulate = c.darkened(0.25) if quiet else c
		s = 0.62 if quiet else 0.82                     # always smaller than damage
	elif taken:
		l.modulate = Color(1.0, 0.36, 0.3)              # damage I take = red
		s = (1.85 if crit else 1.0) * 1.15
	elif dealt:
		l.modulate = Color(1.0, 0.85, 0.35) if crit else Color(1.0, 1.0, 0.95)
		s = 1.85 if crit else 1.0
	else:
		l.modulate = Color(0.78, 0.8, 0.86)             # someone else's hit = dim
		s = (1.85 if crit else 1.0) * 0.7
	l.scale = Vector3.ONE * s
	var pos := _world(f)
	pos.y = DMG_NUM_Y
	if gain:                             # gains ride their own lane: start higher with a sideways jitter,
		pos.y += 0.55                    # or a same-frame damage number (same spot, faster rise, bigger
		pos.x += randf_range(-0.35, 0.35)   # glyphs) sits on top of the quiet +N for its whole life
		pos.z += randf_range(-0.35, 0.35)
	l.position = pos
	# burn ticks + gains drift slowly (a smolder, not a pop); crits ride higher and live longer
	var slow := style == "burn" or gain
	_fx_active.append({"node": l, "t": 0.0, "life": (0.9 if slow else (1.0 if crit else 0.82)),
		"vel": (1.8 if slow else (3.2 if crit else 2.6)), "kind": "num"})

# one pooled additive-unshaded sphere (shared pop/death/flourish pool) — color set per spawn
func _pop_node() -> MeshInstance3D:
	if not _pop_pool.is_empty():
		return _pop_pool.pop_back()
	var p := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.45
	sm.height = 0.9
	sm.radial_segments = 8
	sm.rings = 5
	p.mesh = sm
	var mt := StandardMaterial3D.new()
	mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mt.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	p.material_override = mt
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_root.add_child(p)
	return p

# a class's signature VFX tint (GameData hex — all 8 classes + mobs carry one); warm default when
# unknown (old server / owner out of interest)
func _class_vfx_color(cid: String) -> Color:
	return Color.from_string(str(GameData.CLASSES.get(cid, {}).get("color", "")), Color(1, 0.85, 0.4))

func _spawn_pop(tgt_id, crit := false, col := Color(1, 0.95, 0.7)) -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var p := _pop_node()
	# Tier-2 identity: the burst carries the attacker's class color; crit gold overrides for legibility
	(p.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.85, 0.35) if crit else col
	p.visible = true
	var pos := _world(f)
	pos.y = HIT_Y
	p.position = pos
	p.scale = Vector3.ONE * (0.8 if crit else 0.5)
	_fx_active.append({"node": p, "t": 0.0, "life": (0.32 if crit else 0.22), "vel": 0.0, "kind": "pop", "big": crit})

# small class-colored cast flourish: a flat ring expanding at the caster's feet, from the pop pool.
# Restraint mirrors cast AUDIO exactly: the local player always, others only on non-basics (a camp of
# mobs on ~1.2s basics would carpet the ground in rings, same reason their basics stay silent).
func _spawn_flourish(f: Dictionary, cid: String) -> void:
	var p := _pop_node()
	(p.material_override as StandardMaterial3D).albedo_color = _class_vfx_color(cid)
	p.visible = true
	var pos := _world(f)
	pos.y = 0.12
	p.position = pos
	p.scale = Vector3(0.4, 0.06, 0.4)
	_fx_active.append({"node": p, "t": 0.0, "life": 0.3, "vel": 0.0, "kind": "flourish"})

# Tier-2 debris: tiny dark box shards tossed up-fanned from a struck body (3 on a crit, 6–8 on a kill
# you're part of), tinted faintly with the victim's class color. Dedicated hard-capped pool: once all
# SHARD_CAP nodes exist, a burst steals the OLDEST live shard mid-flight (_fx_active is append-ordered)
# — an AoE multi-kill recycles, it never allocates. reduce_fx skips debris entirely.
func _spawn_shards(f, count: int, col: Color) -> void:
	if reduce_fx or f == null:
		return
	var base := _world(f)
	base.y = 1.0
	for i in count:
		var p: MeshInstance3D
		if not _shard_pool.is_empty():
			p = _shard_pool.pop_back()
		elif _shard_count < SHARD_CAP:
			_shard_count += 1
			p = MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.14, 0.14, 0.14)
			p.mesh = bm
			var mt := StandardMaterial3D.new()
			mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			p.material_override = mt
			p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_fx_root.add_child(p)
		else:
			var idx := -1
			for j in _fx_active.size():
				if _fx_active[j]["kind"] == "shard":
					idx = j
					break
			if idx == -1:
				return                                   # cap hit with nothing live to steal (can't happen)
			p = _fx_active[idx]["node"]
			_fx_active.remove_at(idx)
		(p.material_override as StandardMaterial3D).albedo_color = Color(0.16, 0.14, 0.13).lerp(col, 0.35)
		p.visible = true
		p.position = base + Vector3(randf_range(-0.25, 0.25), randf_range(-0.2, 0.3), randf_range(-0.25, 0.25))
		p.rotation = Vector3(randf() * TAU, randf() * TAU, randf() * TAU)
		p.scale = Vector3.ONE * randf_range(0.7, 1.3)
		var ang := randf() * TAU
		var sp := randf_range(1.2, 2.6)
		_fx_active.append({"node": p, "t": 0.0, "life": SHARD_LIFE, "vel": 0.0, "kind": "shard",
			"v3": Vector3(cos(ang) * sp, randf_range(4.0, 7.0), sin(ang) * sp),
			"spin": Vector3(randf_range(-9.0, 9.0), randf_range(-9.0, 9.0), randf_range(-9.0, 9.0))})

# a bigger, redder burst when a fighter dies (driven by the kill event)
func _spawn_death(tgt_id) -> void:
	var f = _find_fighter(tgt_id)
	if f == null:
		return
	var p := _pop_node()
	(p.material_override as StandardMaterial3D).albedo_color = Color(1.0, 0.5, 0.35)
	p.visible = true
	var pos := _world(f)
	pos.y = HIT_Y
	p.position = pos
	p.scale = Vector3.ONE * 0.6
	_fx_active.append({"node": p, "t": 0.0, "life": 0.5, "vel": 0.0, "kind": "death"})

func _update_fx(delta: float) -> void:
	_shake = maxf(0.0, _shake - delta * SHAKE_DECAY)
	_cam_kick = _cam_kick.lerp(Vector3.ZERO, clampf(delta * KICK_DECAY, 0.0, 1.0))
	_fov_kick = maxf(0.0, _fov_kick - delta * FOV_KICK_DECAY)
	# fade active hit-flashes; hand the material_overlay channel back to the dye when done
	if not _flashing.is_empty():
		for id in _flashing.keys():
			var n = _nodes.get(id)
			if n == null or n.get("flash_mat") == null or not is_instance_valid(n.get("model")):
				_flashing.erase(id)
				continue
			n["flash_t"] = float(n.get("flash_t", 0.0)) - delta
			if float(n["flash_t"]) <= 0.0:
				_apply_dye(n["model"], str(n.get("dye_applied", "")))   # restore the dye (or clear)
				_flashing.erase(id)
			else:
				(n["flash_mat"] as StandardMaterial3D).albedo_color.a = FLASH_ALPHA * float(n["flash_t"]) / FLASH_DUR
	# Tier-2 struck-body give: pose + decay + EXACT restore, all here — this runs for held and dead
	# nodes too, so a killing-blow pose still plays out and a transform can never stick mid-recoil.
	# Ownership: model.position.x/z, model.rotation.x and model.scale are touched by nothing else
	# post-spawn (holder.position = sim lerp, model.rotation.y = facing); mob kits never enter _recoiling.
	if not _recoiling.is_empty():
		for id in _recoiling.keys():
			var n = _nodes.get(id)
			if n == null or not is_instance_valid(n.get("model")):
				_recoiling.erase(id)
				continue
			var model: Node3D = n["model"]
			var msc: float = n["mscale"]
			var rt: float = float(n.get("recoil_t", 0.0)) - delta * RECOIL_DECAY
			n["recoil_t"] = rt
			if rt <= 0.0:
				n["recoil_t"] = 0.0
				model.position.x = 0.0                       # restore exactly: offset→0, pitch→0, scale→mscale
				model.position.z = 0.0
				model.rotation.x = 0.0
				model.scale = Vector3(msc, msc, msc)
				_recoiling.erase(id)
				continue
			var e: float = rt * rt                           # snappy attack, eased settle
			var k: float = float(n.get("recoil_k", 1.0)) * e
			var motion: float = 0.5 if reduce_fx else 1.0    # reduce_fx halves the motion, keeps the subtle squash
			var dir: Vector3 = n.get("recoil_dir", Vector3.ZERO)
			model.position.x = dir.x * RECOIL_OFS * k * motion
			model.position.z = dir.z * RECOIL_OFS * k * motion
			# pitch about local X only: the top tips along the push (away from the attacker) — the lean
			# fades toward zero for pure side-on hits; the positional push carries those
			var fwd := Vector3(sin(model.rotation.y), 0.0, cos(model.rotation.y))
			model.rotation.x = fwd.dot(dir) * RECOIL_LEAN * k * motion
			var sq: float = SQUASH_AMT * k
			model.scale = Vector3(msc * (1.0 + sq * 0.66), msc * (1.0 - sq), msc * (1.0 + sq * 0.66))
	var keep := []
	for fx in _fx_active:
		fx["t"] += delta
		var k: float = fx["t"] / fx["life"]
		var node = fx["node"]
		if k >= 1.0:
			node.visible = false
			if fx["kind"] == "num":
				_num_pool.append(node)
			elif fx["kind"] == "shard":
				_shard_pool.append(node)
			else:
				_pop_pool.append(node)
			continue
		if fx["kind"] == "num":
			node.position.y += fx["vel"] * delta
			(node as Label3D).modulate.a = 1.0 - k
		elif fx["kind"] == "shard":
			var v3: Vector3 = fx["v3"]
			v3.y -= SHARD_G * delta
			fx["v3"] = v3
			node.position += v3 * delta
			node.rotation += (fx["spin"] as Vector3) * delta
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k * k   # hold, then quick fade
		elif fx["kind"] == "death":
			node.scale = Vector3.ONE * (0.6 + k * 6.0)       # big expanding burst
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k
		elif fx["kind"] == "flourish":
			var fscale: float = 0.4 + k * 2.6                # stays flat — an expanding painted cast ring
			node.scale = Vector3(fscale, 0.06, fscale)
			(node.material_override as StandardMaterial3D).albedo_color.a = (1.0 - k) * 0.8
		else:
			var s: float = (0.5 + k * 2.4) * (1.7 if fx.get("big", false) else 1.0)
			node.scale = Vector3.ONE * s
			(node.material_override as StandardMaterial3D).albedo_color.a = 1.0 - k
		keep.append(fx)
	_fx_active = keep

func _sync_projectiles() -> void:
	var shown := 0
	for p in _state["projectiles"]:
		if p.get("delay", 0.0) > 0.0:
			continue
		var pm: MeshInstance3D
		if shown < _proj_pool.size():
			pm = _proj_pool[shown]
		else:
			pm = MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 0.32
			sm.height = 0.64
			pm.mesh = sm
			var mt := StandardMaterial3D.new()
			mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mt.emission_enabled = true
			mt.albedo_color = Color(1, 0.92, 0.6)
			mt.emission = Color(1, 0.85, 0.4)
			pm.material_override = mt
			pm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_fx_root.add_child(pm)
			_proj_pool.append(pm)
		pm.visible = true
		# Tier-2 class tint: networked snapshots carry the owner's classId as "cls" (absent on an old
		# server → classic yellow); the local sandbox's full sim dicts carry "owner" — resolve either.
		var cid := str(p.get("cls", ""))
		if cid == "" and p.has("owner"):
			var owner_f = _find_fighter(p["owner"])
			if owner_f != null:
				cid = str(owner_f["classId"])
		if str(pm.get_meta("cls", "")) != cid:              # material write only on a change (pool nodes shuffle)
			pm.set_meta("cls", cid)
			var mt2 := pm.material_override as StandardMaterial3D
			if cid == "":
				mt2.albedo_color = Color(1, 0.92, 0.6)
				mt2.emission = Color(1, 0.85, 0.4)
			else:
				var col := _class_vfx_color(cid)
				mt2.albedo_color = col.lightened(0.35)      # hot core, class-colored glow
				mt2.emission = col
		pm.position = Vector3((p["x"] - _aw() / 2.0) * SCALE, 1.4, (p["y"] - _ah() / 2.0) * SCALE)
		shown += 1
	for i in range(shown, _proj_pool.size()):
		_proj_pool[i].visible = false

# ============================================================ helpers
func _find_fighter(id) -> Variant:
	if not _state.has("fighters"):    # defensive: callable before the first snapshot (e.g. opening the locker mid-connect)
		return null
	for f in _state["fighters"]:
		if f["id"] == id:
			return f
	return null

# is fighter b hostile to fighter a? Mirrors the server's Combat.is_hostile (cross-team always; in a
# PvP zone two players are hostile unless they share a non-empty party key, both carried in snapshots).
func _hostile_pair(a: Dictionary, b: Dictionary) -> bool:
	if str(a["id"]) == str(b["id"]):
		return false
	if int(a.get("team", 0)) != int(b.get("team", 0)):
		return true
	if not bool(_state.get("pvp", false)) or int(a.get("team", 0)) != 0:
		return false
	var pa := str(a.get("party", ""))
	return pa == "" or pa != str(b.get("party", ""))   # hostile unless same non-empty party

func _enemy_dir(f: Dictionary) -> Vector2:
	var best = null
	var bd := INF
	for e in _state["fighters"]:
		if _hostile_pair(f, e) and e["alive"]:
			var d := Geom.dist(f, e)
			if d < bd:
				bd = d
				best = e
	if best == null:
		return Vector2.ZERO
	return Vector2(best["x"] - f["x"], best["y"] - f["y"])

# ============================================================ Phase 3 persistence
func _place_player_at(pos: Vector2) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	pf["x"] = pos.x
	pf["y"] = pos.y
	_spawn_pos[_player_id] = pos
	var n = _nodes.get(_player_id)
	if n != null:
		n["holder"].position = _world(pf)
		n["last"] = n["holder"].position
	_focus = _world(pf)

func _save_progress() -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or not pf["alive"] or supa == null or char_id == "":
		return                          # don't persist a corpse's death-spot
	var r = await supa.save_character(char_id, {"last_x": pf["x"], "last_y": pf["y"], "last_map": MAP_ID})
	if r.get("ok"):
		_save_note = "progress saved"
	elif r.get("expired"):
		_save_note = "session expired — relog to save"
	else:
		_save_note = "save failed"

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and supa != null and char_id != "" and not _quitting:
		_quitting = true
		await _save_progress()
		get_tree().quit()

# ============================================================ input (camera + meta)
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_dist = clampf(_dist / ZOOM_STEP, DIST_MIN, DIST_MAX)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_dist = clampf(_dist * ZOOM_STEP, DIST_MIN, DIST_MAX)
	elif e is InputEventMouseMotion and _dragging:
		_yaw -= e.relative.x * ORBIT_SENS
		_pitch = clampf(_pitch + e.relative.y * ORBIT_SENS, PITCH_MIN, PITCH_MAX)  # drag up = look down (MMO-natural)
	elif e is InputEventKey and e.pressed and not e.echo:
		if e.physical_keycode == KEY_P:
			_bots_frozen = not _bots_frozen
			if _state != null:
				_state["botsFrozen"] = _bots_frozen
		elif e.physical_keycode == KEY_C:
			if class_locked:
				return                              # one class per account — no cycling
			_player_class_idx = (_player_class_idx + 1) % PLAYABLE.size()
			_setup_match(PLAYABLE[_player_class_idx])
		elif e.physical_keycode == KEY_R:
			_setup_match(PLAYABLE[_player_class_idx])
			if has_start_pos:
				_place_player_at(start_pos)
		elif e.physical_keycode == KEY_N:
			_toggle_meter()                         # the §4a DPS/HPS meter (sandbox: bots brawl → it fills)
		elif e.physical_keycode == KEY_F3:
			_toggle_coords()                        # dev: sim-space coord readout under the cursor

# ============================================================ HUD
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)
	# UI-overhaul P0: ONE Theme restyles every Control. A CanvasLayer isn't a Control (no `theme`
	# property), so the root Window carries it — it propagates to everything under _hud + popups.
	get_window().theme = UITheme.get_theme()
	_info = RichTextLabel.new()
	_info.bbcode_enabled = true
	_info.fit_content = true
	_info.scroll_active = false
	_info.position = Vector2(16, 12)
	_info.custom_minimum_size = Vector2(520, 0)
	_hud.add_child(_info)
	_bar = RichTextLabel.new()                    # P1: repurposed as the dim keybind-hints line
	_bar.bbcode_enabled = true
	_bar.fit_content = true
	_bar.scroll_active = false
	_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_bar.position = Vector2(16, -26)
	_bar.custom_minimum_size = Vector2(1100, 0)
	_bar.add_theme_font_size_override("normal_font_size", Palette.SIZE_CAPTION)
	_bar.add_theme_font_size_override("bold_font_size", Palette.SIZE_CAPTION)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_bar)
	# skill bar (hotbar) + hover tooltip
	_hotbar = HBoxContainer.new()
	_hotbar.add_theme_constant_override("separation", 6)
	_hud.add_child(_hotbar)
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.z_index = 4096                       # always draw on top of panels (it's a sibling under _hud)
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never eat clicks meant for the UI under it
	var ttsb := StyleBoxFlat.new()                # near-opaque dark bg so item details read clearly over the scene
	ttsb.bg_color = Color(0.05, 0.06, 0.09, 0.98)
	ttsb.set_border_width_all(1)
	ttsb.border_color = Color(0.38, 0.43, 0.52, 0.95)
	ttsb.set_corner_radius_all(4)
	ttsb.set_content_margin_all(9)
	_tooltip.add_theme_stylebox_override("panel", ttsb)
	_tt_label = RichTextLabel.new()
	_tt_label.bbcode_enabled = true
	_tt_label.fit_content = true
	_tt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE  # display-only; don't block the UI beneath
	_tt_label.custom_minimum_size = Vector2(250, 0)
	_tooltip.add_child(_tt_label)
	_hud.add_child(_tooltip)
	_build_vitals()
	_build_meter()
	_build_screen_juice()

# P4: the shared screen-space juice layer — a low-HP vignette (z=-20, under the HUD), a death/benched
# overlay (z=140), and a top-right toast stack (z=200). All MOUSE_FILTER_IGNORE so they never eat input.
# Online-only juice (level-up flash, zone card) is built separately in NetClient._build_juice_online.
func _build_screen_juice() -> void:
	var grad := Gradient.new()                # radial red edge glow — asset-free, no shader
	grad.offsets = PackedFloat32Array([0.0, 0.58, 1.0])
	grad.colors = PackedColorArray([Color(0.85, 0.08, 0.08, 0.0), Color(0.85, 0.08, 0.08, 0.0), Color(0.86, 0.05, 0.05, 0.92)])
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(1.0, 0.5)
	gtex.width = 256
	gtex.height = 256
	_vignette = TextureRect.new()
	_vignette.texture = gtex
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.z_index = -20
	_vignette.modulate.a = 0.0
	_vignette.visible = false
	_hud.add_child(_vignette)
	_death_overlay = ColorRect.new()
	_death_overlay.color = Color(0.03, 0.02, 0.04, 0.62)
	_death_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.z_index = 140
	_death_overlay.visible = false
	_hud.add_child(_death_overlay)
	var dcc := CenterContainer.new()
	dcc.set_anchors_preset(Control.PRESET_FULL_RECT)
	dcc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.add_child(dcc)
	var dvb := VBoxContainer.new()
	dvb.alignment = BoxContainer.ALIGNMENT_CENTER
	dvb.add_theme_constant_override("separation", 6)
	dcc.add_child(dvb)
	var dl := Label.new()
	dl.text = "DEFEATED"
	dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dl.add_theme_font_size_override("font_size", 52)
	dl.add_theme_color_override("font_color", Palette.DANGER)
	dl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	dl.add_theme_constant_override("outline_size", 10)
	dvb.add_child(dl)
	_death_sub = Label.new()
	_death_sub.text = "Respawning…"
	_death_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_sub.add_theme_font_size_override("font_size", 20)
	_death_sub.add_theme_color_override("font_color", Palette.TEXT)
	dvb.add_child(_death_sub)
	_toast_layer = Control.new()
	_toast_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_toast_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_layer.z_index = 200
	_hud.add_child(_toast_layer)

# per-frame juice: low-HP vignette + death fade + toast reflow. ONE call site (from _render_world after
# _update_hud) so accumulators never double-advance. Hidden when the session is suppressed (disconnect).
func _drive_screen_juice() -> void:
	var dt := get_process_delta_time()
	_update_toasts(dt)                 # keep advancing so cards expire + free even while hidden
	var suppressed: bool = _juice_suppressed()
	if _toast_layer != null:           # hide the stack (but let it drain) under the disconnect/pre-snapshot overlay
		_toast_layer.visible = not suppressed
	if _vignette == null:
		return
	var pf = _find_fighter(_player_id)
	if suppressed or pf == null or _player == null:
		_vignette.visible = false
		_death_overlay.visible = false
		_death_t = 0.0
		return
	var alive: bool = bool(pf.get("alive", true))
	var frac: float = clampf(float(pf["hp"]) / maxf(1.0, float(pf["maxHP"])), 0.0, 1.0)
	if alive and frac < LOW_HP_THRESH:
		var inten: float = 1.0 - frac / LOW_HP_THRESH        # 0 at threshold → 1 near death
		var a: float = 0.22 + inten * 0.5
		if not reduce_fx:
			_low_hp_t += dt
			a *= 0.78 + 0.22 * sin(_low_hp_t * 6.0)          # heartbeat pulse
		_vignette.visible = true
		_vignette.modulate.a = a
	else:
		_vignette.visible = false
	if not alive:
		_death_t = minf(DEATH_FADE, _death_t + dt)
		_death_overlay.visible = true
		_death_overlay.modulate.a = 1.0 if reduce_fx else (_death_t / DEATH_FADE)
	else:
		_death_t = 0.0
		_death_overlay.visible = false

# subclasses suppress juice when the session isn't live (NetClient: a connection error/pre-snapshot)
func _juice_suppressed() -> bool:
	return false

# P4: push a transient top-right toast. bbcode text + accent stripe; big = level-up prominence.
# reduce_fx keeps the toast (fade only, no slide). Shared infra — NetClient fires the events.
func _toast(bbcode: String, accent: Color, big := false) -> void:
	if _toast_layer == null:
		return
	var card := PanelContainer.new()
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.BG_PANEL, 0.95)
	sb.set_border_width_all(1)
	sb.set_border_width(SIDE_LEFT, 4)                    # accent stripe on the left edge
	sb.border_color = Color(accent, 0.9)
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(9)
	card.add_theme_stylebox_override("panel", sb)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.custom_minimum_size = Vector2(TOAST_W, 0)
	rt.add_theme_font_size_override("normal_font_size", Palette.SIZE_SECTION if big else Palette.SIZE_BODY)
	rt.add_theme_font_size_override("bold_font_size", Palette.SIZE_TITLE if big else Palette.SIZE_SECTION)
	rt.text = bbcode
	card.add_child(rt)
	card.modulate.a = 0.0
	_toast_layer.add_child(card)
	_toasts.push_front({"node": card, "phase": "in", "t": 0.0,
		"life": (TOAST_HOLD_BIG if big else TOAST_HOLD), "slide": not reduce_fx})
	var live := 0
	for e in _toasts:
		if str(e["phase"]) != "out":
			live += 1
	var i := _toasts.size() - 1
	while live > TOAST_MAX and i >= 0:                    # push the oldest live card into early fade-out
		if str(_toasts[i]["phase"]) != "out":
			_toasts[i]["phase"] = "out"
			_toasts[i]["t"] = 0.0
			live -= 1
		i -= 1

func _update_toasts(dt: float) -> void:
	if _toasts.is_empty():
		return
	var vpw: float = _hud.get_viewport().get_visible_rect().size.x   # recomputed → auto-recenters on resize
	var y := TOAST_TOP
	var dead := []
	for e in _toasts:
		var card: Control = e["node"]
		if not is_instance_valid(card):
			dead.append(e)
			continue
		e["t"] = float(e["t"]) + dt
		var a := 1.0
		var offx := 0.0
		match str(e["phase"]):
			"in":
				var k := clampf(float(e["t"]) / TOAST_IN, 0.0, 1.0)
				a = k
				if e["slide"]:
					offx = (1.0 - k) * TOAST_SLIDE
				if k >= 1.0:
					e["phase"] = "hold"
					e["t"] = 0.0
			"hold":
				if float(e["t"]) >= float(e["life"]):
					e["phase"] = "out"
					e["t"] = 0.0
			"out":
				var k2 := clampf(float(e["t"]) / TOAST_OUT, 0.0, 1.0)
				a = 1.0 - k2
				if e["slide"]:
					offx = k2 * TOAST_SLIDE
				if k2 >= 1.0:
					dead.append(e)
					continue
		card.modulate.a = a
		var tx: float = vpw - card.size.x - 14.0 + offx    # top-right anchored (slides in from the right)
		var ny: float = y if (reduce_fx or card.position.y <= 0.0) else lerpf(card.position.y, y, clampf(dt * 12.0, 0.0, 1.0))
		card.position = Vector2(tx, ny)
		y += card.size.y + TOAST_GAP
	for e in dead:
		if is_instance_valid(e["node"]):
			e["node"].queue_free()
		_toasts.erase(e)

func _clear_toasts() -> void:
	for e in _toasts:
		if is_instance_valid(e["node"]):
			e["node"].queue_free()
	_toasts.clear()

# --- vitals frame + tray + zone banner (P1): the dense _info text line becomes a real HUD ---
func _build_vitals() -> void:
	_hud_left = VBoxContainer.new()
	_hud_left.position = Vector2(12, 10)
	_hud_left.add_theme_constant_override("separation", 6)
	_hud_left.visible = false                     # shown once a player fighter exists
	_hud.add_child(_hud_left)
	_vitals = PanelContainer.new()
	var sb := StyleBoxFlat.new()                  # always-on HUD chrome: a touch more translucent than pop-ups
	sb.bg_color = Color(Palette.BG_PANEL, 0.82)
	sb.set_border_width_all(1)
	sb.border_color = Palette.BORDER
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	_vitals.add_theme_stylebox_override("panel", sb)
	_hud_left.add_child(_vitals)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	_vitals.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	vb.add_child(head)
	_vit_level = Label.new()
	_vit_level.add_theme_font_size_override("font_size", 18)
	_vit_level.add_theme_color_override("font_color", Palette.ACCENT)
	head.add_child(_vit_level)
	_vit_name = Label.new()
	_vit_name.add_theme_font_size_override("font_size", 18)
	_vit_name.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	head.add_child(_vit_name)
	_vit_class = Label.new()
	_vit_class.size_flags_vertical = Control.SIZE_SHRINK_END
	_vit_class.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	head.add_child(_vit_class)
	_vit_hp = Widgets.bar(260, 20, Palette.HP)
	_vit_hp_text = Label.new()                    # HP numbers centered ON the bar
	_vit_hp_text.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vit_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vit_hp_text.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	_vit_hp_text.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	_vit_hp_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_vit_hp_text.add_theme_constant_override("outline_size", 5)
	(_vit_hp["root"] as Control).add_child(_vit_hp_text)
	vb.add_child(_vit_hp["root"])
	_vit_shield = Widgets.bar(260, 5, Palette.SHIELD)   # absorb strip under the HP bar
	(_vit_shield["root"] as Control).visible = false
	vb.add_child(_vit_shield["root"])
	_vit_xp_row = HBoxContainer.new()
	_vit_xp_row.add_theme_constant_override("separation", 8)
	vb.add_child(_vit_xp_row)
	_vit_xp = Widgets.bar(180, 8, Palette.XP)
	(_vit_xp["root"] as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_vit_xp_row.add_child(_vit_xp["root"])
	_vit_xp_text = Label.new()
	_vit_xp_text.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_vit_xp_text.add_theme_color_override("font_color", Palette.TEXT_DIM)
	_vit_xp_row.add_child(_vit_xp_text)
	_vit_status = Label.new()
	_vit_status.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_vit_status.add_theme_color_override("font_color", Palette.TEXT_DIM)
	vb.add_child(_vit_status)
	# currency tray (values live online; the sandbox hides it)
	_tray = PanelContainer.new()
	var tsb: StyleBoxFlat = sb.duplicate()
	tsb.content_margin_top = 4.0
	tsb.content_margin_bottom = 5.0
	_tray.add_theme_stylebox_override("panel", tsb)
	_tray.visible = false
	_hud_left.add_child(_tray)
	var th := HBoxContainer.new()
	th.add_theme_constant_override("separation", 14)
	_tray.add_child(th)
	_tray_credits = _tray_label(th, Palette.CREDITS)
	_tray_scrap = _tray_label(th, Palette.SCRAP)
	_tray_tokens = _tray_label(th, Palette.TOKENS)
	# zone banner — a top-center chip (name + PvP state)
	var zc := CenterContainer.new()
	zc.set_anchors_preset(Control.PRESET_TOP_WIDE)
	zc.offset_top = 8.0
	zc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(zc)
	_zone_banner = PanelContainer.new()
	var zsb: StyleBoxFlat = sb.duplicate()
	zsb.content_margin_left = 16.0
	zsb.content_margin_right = 16.0
	zsb.content_margin_top = 3.0
	zsb.content_margin_bottom = 4.0
	zsb.set_corner_radius_all(11)
	_zone_banner.add_theme_stylebox_override("panel", zsb)
	_zone_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zone_banner.visible = false
	zc.add_child(_zone_banner)
	_zone_label = Label.new()
	_zone_label.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	_zone_label.add_theme_color_override("font_color", Palette.ACCENT2)
	_zone_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zone_banner.add_child(_zone_label)

func _tray_label(parent: HBoxContainer, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", Palette.SIZE_BODY)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l

# set a label's text only when it changed — vitals update every frame, re-shaping is not free
func _vit_set(key: String, label: Label, text: String) -> void:
	if _vit_cache.get(key) != text:
		_vit_cache[key] = text
		label.text = text

# the shared vitals update (sandbox + online) — mode-specific lines are set by each _update_hud
func _update_vitals(pf: Dictionary, title: String, c: Dictionary) -> void:
	_hud_left.visible = true
	var mhp: float = maxf(1.0, float(pf["maxHP"]))
	var frac: float = clampf(float(pf["hp"]) / mhp, 0.0, 1.0)
	Widgets.set_bar(_vit_hp, frac)
	(_vit_hp["fill"] as ColorRect).color = WorldUI.hp_color(frac)   # shared 3-stop ramp (matches world bars)
	_vit_set("hp", _vit_hp_text, "%d / %d" % [int(round(pf["hp"])), int(mhp)])
	var sh: float = float(pf.get("shield", 0.0))
	(_vit_shield["root"] as Control).visible = sh > 0.0
	if sh > 0.0:
		Widgets.set_bar(_vit_shield, clampf(sh / mhp, 0.0, 1.0))
	_vit_set("name", _vit_name, title)
	if str(_vit_cache.get("cls", "")) != str(pf["classId"]):
		_vit_cache["cls"] = str(pf["classId"])
		_vit_class.add_theme_color_override("font_color",
			Color.from_string(str(c.get("color", "")), Palette.TEXT_DIM).lightened(0.15))
	_vit_set("class", _vit_class, "%s · %s" % [str(c.get("sport", "")), str(c.get("role", ""))])
	if pf.has("level"):
		_vit_set("lvl", _vit_level, "Lv %d" % int(pf["level"]))
		_vit_level.visible = true
	else:
		_vit_level.visible = false
	if pf.has("xp"):
		_vit_xp_row.visible = true
		var xp := int(pf.get("xp", 0))
		var xpn: int = maxi(1, int(pf.get("xpNext", 100)))
		Widgets.set_bar(_vit_xp, float(xp) / float(xpn))
		_vit_set("xp", _vit_xp_text, "XP %d / %d" % [xp, xpn])
	else:
		_vit_xp_row.visible = false

# ============================================================ DPS/HPS meter (§4a, UI-overhaul P1)
# Pure client: accumulates the RAW dmg/heal/shield events inside _handle_events (before the
# events array is cleared — NOT the render-side gains coalescing). Proc/DOT damage arrives as
# ordinary dmg events tagged "proc" and counts (procs are real damage; the tag only gates the
# impact stack). Known blind spots (by Tier-2 design, documented in the footer): melee lifesteal,
# the vampiric proc and zone regens write hp directly and are event-silent → HPS under-counts them.
func _build_meter() -> void:
	_meter_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.BG_PANEL, 0.82)   # semi-transparent — lives fine alongside combat
	sb.set_border_width_all(1)
	sb.border_color = Palette.BORDER
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)
	_meter_panel.add_theme_stylebox_override("panel", sb)
	_meter_panel.visible = false
	_hud.add_child(_meter_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	_meter_panel.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	head.mouse_filter = Control.MOUSE_FILTER_STOP           # the drag handle
	vb.add_child(head)
	_meter_title = Label.new()
	_meter_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_meter_title.custom_minimum_size = Vector2(150, 0)
	_meter_title.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	_meter_title.add_theme_color_override("font_color", Palette.ACCENT)
	head.add_child(_meter_title)
	var mode_btn := _meter_btn("mode", func() -> void:
		_meter_mode = (_meter_mode + 1) % METER_MODES.size()
		_render_meter())
	head.add_child(mode_btn)
	_meter_scope_btn = _meter_btn("", func() -> void:
		_meter_party_only = not _meter_party_only
		_render_meter())
	head.add_child(_meter_scope_btn)
	head.add_child(_meter_btn("reset", func() -> void:
		_meter.clear()
		_enc_last = -1.0e9
		_render_meter()))
	head.add_child(_meter_btn("✕", func() -> void: _toggle_meter()))
	var drag := {"on": false}                               # drag the header to move the panel
	head.gui_input.connect(func(ev) -> void:
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
			drag["on"] = ev.pressed
		elif ev is InputEventMouseMotion and drag["on"]:
			_meter_panel.position += (ev as InputEventMouseMotion).relative
			_meter_dragged = true)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	vb.add_child(rows)
	for i in METER_MAX_ROWS:                                # a fixed row pool, updated in place at 4 Hz —
		var row := Control.new()                            # zero node churn on re-render
		row.custom_minimum_size = Vector2(METER_ROW_W, 19)
		row.visible = false
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var fill := ColorRect.new()                         # the class-colored value bar BEHIND the text
		fill.position = Vector2(0, 0)
		fill.size = Vector2(0, 19)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(fill)
		var stripe := ColorRect.new()                       # solid class-color chip at the row edge
		stripe.position = Vector2(0, 0)
		stripe.size = Vector2(3, 19)
		stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(stripe)
		var nm := Label.new()
		nm.position = Vector2(8, 0)
		nm.size = Vector2(METER_ROW_W - 100.0, 19)
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nm.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(nm)
		var num := Label.new()
		num.position = Vector2(METER_ROW_W - 92.0, 0)
		num.size = Vector2(92, 19)
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		num.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
		num.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(num)
		rows.add_child(row)
		_meter_row_pool.append({"root": row, "fill": fill, "stripe": stripe, "name": nm, "num": num})
	var foot := Label.new()                                 # honesty beats mystery (§4a blind spots)
	foot.text = "melee lifesteal + passive regens aren't counted"
	foot.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION - 1)
	foot.add_theme_color_override("font_color", Palette.TEXT_FAINT)
	vb.add_child(foot)
	var timer := Timer.new()                                # ~4 Hz re-render — never per frame
	timer.wait_time = 0.25
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_render_meter)

func _meter_btn(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION - 1)
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0, 0, 0, 0.3)
	bsb.set_corner_radius_all(4)
	bsb.set_content_margin_all(2)
	bsb.content_margin_left = 6.0
	bsb.content_margin_right = 6.0
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(st, bsb if st == "normal" else bsb.duplicate())
	(b.get_theme_stylebox("hover") as StyleBoxFlat).bg_color = Color(0.3, 0.36, 0.46, 0.5)
	b.pressed.connect(on_press)
	return b

func _toggle_meter() -> void:
	if _meter_panel == null:
		return
	_meter_panel.visible = not _meter_panel.visible
	if _meter_panel.visible:
		_render_meter()                           # fill rows/title FIRST so the placement sees the real width
		if not _meter_dragged:
			_meter_panel.reset_size()
			var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
			_meter_panel.position = Vector2(vp.x - _meter_panel.size.x - 12.0, 340.0)

func _meter_now() -> float:
	return Time.get_ticks_msec() / 1000.0

# one accumulator entry per fighter id; name/class resolved lazily via _find_fighter and CACHED so
# rows survive the fighter leaving interest range. Pruned after METER_PRUNE idle.
func _meter_entry(id: String, now: float) -> Dictionary:
	var e = _meter.get(id)
	if e == null:
		var buckets := []
		buckets.resize(METER_SLOTS)
		buckets.fill(0.0)
		var bsec := []
		bsec.resize(METER_SLOTS)
		bsec.fill(-1)
		e = {"dmg": 0.0, "heal": 0.0, "taken": 0.0, "last_t": now, "buckets": buckets, "bsec": bsec,
			"name": "", "color": Palette.TEXT_DIM, "mob": false}
		_meter[id] = e
	e["last_t"] = now
	if str(e["name"]) == "":
		_meter_resolve(e, id)
	return e

func _meter_resolve(e: Dictionary, id: String) -> void:
	var f = _find_fighter(id)
	if f == null:
		return
	var def: Dictionary = GameData.CLASSES.get(str(f["classId"]), {})
	e["name"] = str(f.get("name", def.get("name", "?")))
	e["color"] = Color.from_string(str(def.get("color", "")), Palette.TEXT_DIM)
	e["mob"] = bool(def.get("mob", false))

# called for EVERY event inside _handle_events, before _state["events"].clear()
func _meter_accum(t: String, ev: Dictionary) -> void:
	if t != "dmg" and t != "heal" and t != "shield":
		return
	var now := _meter_now()
	if now - _enc_last >= METER_GAP:              # encounter edge: first event after silence → fresh sums
		_enc_start = now
		for id in _meter:
			var e0: Dictionary = _meter[id]
			e0["dmg"] = 0.0
			e0["heal"] = 0.0
			e0["taken"] = 0.0
			# clear the rolling ring too: METER_WINDOW (15s) > METER_GAP (5s), so the prior encounter's
			# last ~10s of buckets would otherwise still be summed by _meter_rolling while the denominator
			# has collapsed to _enc_start=now — a 2–4× phantom DPS spike for the first seconds of the new fight
			(e0["buckets"] as Array).fill(0.0)
			(e0["bsec"] as Array).fill(-1)
	_enc_last = now
	var amt := float(ev.get("amt", 0))
	if amt <= 0.0:
		return
	var src := str(ev.get("src", ""))
	if t == "dmg":
		if src != "":
			var e := _meter_entry(src, now)
			e["dmg"] = float(e["dmg"]) + amt
			var sec := int(now)                   # per-second ring slot for the rolling window
			var slot := sec % METER_SLOTS
			if int((e["bsec"] as Array)[slot]) != sec:
				e["bsec"][slot] = sec
				e["buckets"][slot] = 0.0
			e["buckets"][slot] = float(e["buckets"][slot]) + amt
		var tgt := str(ev.get("tgt", ""))
		if tgt != "":                             # tgt-side sum of the same events = the "taken" mode
			var et := _meter_entry(tgt, now)
			et["taken"] = float(et["taken"]) + amt
	elif src != "":                               # heal/shield amt is the post-cap APPLIED amount
		var eh := _meter_entry(src, now)
		eh["heal"] = float(eh["heal"]) + amt

func _meter_rolling(e: Dictionary, now: float) -> float:
	var lo := int(now - METER_WINDOW)
	var sum := 0.0
	for i in METER_SLOTS:
		if int((e["bsec"] as Array)[i]) > lo:
			sum += float((e["buckets"] as Array)[i])
	return sum / clampf(now - _enc_start, 3.0, METER_WINDOW)

# party membership for the scope filter + row highlight. NetClient overrides with the live roster.
func _meter_is_party(id: String) -> bool:
	return id == _player_id

func _fmt_meter_num(v: float) -> String:
	if v >= 100000.0:
		return "%.0fk" % (v / 1000.0)
	if v >= 10000.0:
		return "%.1fk" % (v / 1000.0)
	return "%d" % int(round(v))

# the 4 Hz re-render (and the prune, which must run even while hidden to bound the dict)
func _render_meter() -> void:
	var now := _meter_now()
	for id in _meter.keys():
		if now - float(_meter[id]["last_t"]) > METER_PRUNE:
			_meter.erase(id)
	if _meter.is_empty():                          # everything aged out → clear the encounter so the title
		_enc_last = -1.0e9                         # doesn't linger as "Xs · ended" over an empty panel
		_enc_start = 0.0
	if _meter_panel == null or not _meter_panel.visible:
		return
	var dur: float = clampf(_enc_last - _enc_start, 1.0, 1.0e9)
	var rows := []
	for id in _meter:
		var e: Dictionary = _meter[id]
		if str(e["name"]) == "":
			_meter_resolve(e, str(id))            # retry: the fighter may have entered interest since
			if str(e["name"]) == "":
				continue
		if bool(e["mob"]):
			continue                              # players + AI residents only — a mob camp would drown the list
		if _meter_party_only and not _meter_is_party(str(id)):
			continue
		var v := 0.0
		match _meter_mode:
			0: v = _meter_rolling(e, now)
			1: v = float(e["dmg"]) / dur
			2: v = float(e["heal"]) / dur
			3: v = float(e["taken"])
		if v >= 0.5:
			rows.append({"id": str(id), "e": e, "v": v})
	rows.sort_custom(func(a, b): return float(a["v"]) > float(b["v"]))
	var top: float = maxf(1.0, float(rows[0]["v"]) if not rows.is_empty() else 1.0)
	for i in METER_MAX_ROWS:
		var w: Dictionary = _meter_row_pool[i]
		if i >= rows.size():
			(w["root"] as Control).visible = false
			continue
		var r: Dictionary = rows[i]
		var e2: Dictionary = r["e"]
		var col: Color = e2["color"]
		(w["root"] as Control).visible = true
		(w["fill"] as ColorRect).color = Color(col, 0.30)
		(w["fill"] as ColorRect).size.x = METER_ROW_W * clampf(float(r["v"]) / top, 0.0, 1.0)
		(w["stripe"] as ColorRect).color = col
		var nm := w["name"] as Label
		nm.text = "%d. %s" % [i + 1, str(e2["name"])]
		if r["id"] == _player_id:                 # self gold, party bright, others standard
			nm.add_theme_color_override("font_color", Palette.ACCENT)
		elif _meter_is_party(str(r["id"])):
			nm.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
		else:
			nm.add_theme_color_override("font_color", Palette.TEXT)
		(w["num"] as Label).text = _fmt_meter_num(float(r["v"]))
	if _enc_last < 0.0:                              # nothing tracked yet — no fake "0s encounter"
		_meter_title.text = "⚔ %s" % METER_MODES[_meter_mode]
	else:                                            # keep the LAST encounter viewable after it ends
		var over: bool = now - _enc_last >= METER_GAP
		_meter_title.text = "⚔ %s   %ds%s" % [METER_MODES[_meter_mode], int(dur), " · ended" if over else ""]
	_meter_scope_btn.text = "party" if _meter_party_only else "zone"

# (re)build a slot per ability when the class is known/changes
func _build_hotbar(class_id: String) -> void:
	for s in _slots:
		s["root"].queue_free()
	_slots.clear()
	_pred_cds.clear()                            # stale predictions from the previous class must not leak
	_hotbar_class = class_id
	var abilities: Array = GameData.CLASSES[class_id]["abilities"]
	for i in abilities.size():
		var ab = abilities[i]
		var slot := Control.new()
		slot.custom_minimum_size = Vector2(60, 60)
		slot.pivot_offset = Vector2(30, 30)      # press-depress scales around the slot center
		var bg := Panel.new()                    # P1 polish: rounded, bordered slot (gold ring on the ult)
		bg.size = Vector2(60, 60)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bsb := StyleBoxFlat.new()
		bsb.bg_color = _slot_color(ab)
		bsb.set_border_width_all(1)
		bsb.border_color = Color(Palette.ACCENT, 0.8) if ab.get("ult", false) else Palette.BORDER
		bsb.set_corner_radius_all(7)
		bg.add_theme_stylebox_override("panel", bsb)
		slot.add_child(bg)
		var cd := ColorRect.new()                # cooldown wipe (dark, height = cd fraction)
		cd.color = Color(0, 0, 0, 0.62)
		cd.position = Vector2(1, 1)
		cd.size = Vector2(58, 0)
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cd)
		var cap := PanelContainer.new()          # keycap chip, top-left
		cap.position = Vector2(3, 3)
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var csb := StyleBoxFlat.new()
		csb.bg_color = Color(0, 0, 0, 0.55)
		csb.set_corner_radius_all(3)
		csb.content_margin_left = 4.0
		csb.content_margin_right = 4.0
		cap.add_theme_stylebox_override("panel", csb)
		var kl := Label.new()                    # keybind
		kl.text = str(i + 1)
		kl.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
		kl.add_theme_color_override("font_color", Palette.ACCENT2)
		cap.add_child(kl)
		slot.add_child(cap)
		var nl := Label.new()                    # ability name (small, wrapped)
		nl.text = str(ab["name"])
		nl.position = Vector2(3, 30)
		nl.size = Vector2(54, 28)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.add_theme_font_size_override("font_size", 10)
		nl.add_theme_color_override("font_color", Palette.TEXT)
		slot.add_child(nl)
		var cs := Label.new()                    # cooldown seconds (center)
		cs.position = Vector2(0, 18)
		cs.size = Vector2(60, 24)
		cs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cs.add_theme_font_size_override("font_size", 20)
		cs.add_theme_color_override("font_color", Palette.ACCENT)
		cs.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		cs.add_theme_constant_override("outline_size", 5)
		slot.add_child(cs)
		slot.mouse_entered.connect(_on_slot_hover.bind(i))
		slot.mouse_exited.connect(_on_slot_unhover)
		_hotbar.add_child(slot)
		_slots.append({"root": slot, "cd": cd, "cs": cs, "sb": bsb, "press": 0.0})

func _slot_color(ab: Dictionary) -> Color:
	if ab.get("ult", false): return Color(0.36, 0.30, 0.10)       # ultimate = gold-ish
	if ab.get("basic", false): return Color(0.14, 0.26, 0.16)     # basic = green-ish
	if ab["type"] in ["allybuff", "allyheal", "teamheal"]: return Color(0.13, 0.22, 0.30)  # support = blue
	return Color(0.16, 0.18, 0.24)                                # normal

func _update_hotbar(pf: Dictionary) -> void:
	if pf.get("classId", "") != _hotbar_class:
		_build_hotbar(str(pf["classId"]))
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_hotbar.position = Vector2((vp.x - _hotbar.size.x) / 2.0, vp.y - 86.0)
	var abilities: Array = GameData.CLASSES[str(pf["classId"])]["abilities"]
	var dt := get_process_delta_time()
	for i in _slots.size():
		var ab = abilities[i]
		var total: float = float(ab.get("cd", 0.0))
		var rem: float = float(pf.get("cds", {}).get(ab["key"], 0.0))
		# predicted cooldown sweep: starts on the keypress, replaced by the server's value the moment it
		# confirms; if the server never starts the cooldown (rejected cast), it quietly snaps back to ready.
		var pred = _pred_cds.get(ab["key"])
		if pred != null:
			if rem > 0.05:
				_pred_cds.erase(ab["key"])              # confirmed — the real cooldown takes over
			else:
				pred["t"] = float(pred["t"]) + dt
				if float(pred["t"]) >= float(pred["window"]):
					_pred_cds.erase(ab["key"])          # mispredict — snap back
					var pn = _nodes.get(_player_id)     # drop the consume record too, so a later real
					if pn != null:                      # cast of this key isn't silently swallowed
						(pn.get("pred_cast", {}) as Dictionary).erase(ab["key"])
				else:
					total = float(pred["total"])
					rem = maxf(total - float(pred["t"]), 0.05)
		var frac: float = clampf(rem / total, 0.0, 1.0) if total > 0.0 else 0.0
		_slots[i]["cd"].size = Vector2(58.0, frac * 58.0)
		_slots[i]["cs"].text = ("%d" % int(ceil(rem))) if rem > 0.05 else ""
		var press: float = float(_slots[i].get("press", 0.0))
		if press > 0.0:                                 # tactile press: depress + brighten, settling fast
			press = maxf(0.0, press - dt * 6.0)
			_slots[i]["press"] = press
			_slots[i]["root"].scale = Vector2.ONE * (1.0 - 0.10 * press)
			(_slots[i]["sb"] as StyleBoxFlat).bg_color = _slot_color(ab).lightened(press * 0.55)

func _on_slot_hover(i: int) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or i >= GameData.CLASSES[str(pf["classId"])]["abilities"].size():
		return
	_tt_label.text = _ability_tooltip(GameData.CLASSES[str(pf["classId"])]["abilities"][i], pf)
	_tooltip.visible = true
	_tooltip.reset_size()
	var sp: Vector2 = _slots[i]["root"].global_position
	_tooltip.position = Vector2(sp.x - 95.0, sp.y - _tooltip.size.y - 8.0)

func _on_slot_unhover() -> void:
	_tooltip.visible = false

# the skill's real numbers, computed from the player's current stats + gear
func _ability_tooltip(ab: Dictionary, pf: Dictionary) -> String:
	var L := ["[b]%s[/b]  [color=#7f93a8]%s[/color]" % [ab["name"], str(ab["type"])]]
	var dm: float = float(pf.get("dmgMult", 1.0))
	var mhp: float = float(pf.get("maxHP", 1000.0))
	if ab.has("dmg"):
		L.append("Damage: [color=#ff9a6b]%d[/color]" % int(round(float(ab["dmg"]) * dm)))
		var cr: float = float(pf.get("crit", 0.0))
		if cr > 0.0:
			L.append("Crit: %d%% for %.1f×" % [int(round(cr * 100.0)), float(pf.get("critMult", 1.5))])
	if ab.has("healPct"):
		L.append("Heal: [color=#9fe8a0]%d[/color]" % int(round(float(ab["healPct"]) * mhp)))
	if ab.has("shieldPct"):
		L.append("Shield: [color=#9fd0ff]%d[/color]" % int(round(float(ab["shieldPct"]) * mhp)))
	if ab.has("range"):
		L.append("[color=#9fb4c8]Range: %d[/color]" % int(ab["range"]))
	if ab.has("dist"):
		L.append("[color=#9fb4c8]Dash: %d[/color]" % int(ab["dist"]))
	if ab.has("stun"):
		L.append("[color=#d7c27a]Stun: %.1fs[/color]" % float(ab["stun"]))
	if ab.has("slow"):
		L.append("[color=#d7c27a]Slow: %d%% for %.1fs[/color]" % [int(float(ab["slow"]["amt"]) * 100.0), float(ab["slow"]["dur"])])
	if ab.has("dur"):
		L.append("[color=#9fb4c8]Duration: %.1fs[/color]" % float(ab["dur"]))
	L.append("[color=#7f93a8]Cooldown: %.1fs[/color]" % float(ab.get("cd", 0.0)))
	return "\n".join(L)

func _update_hud() -> void:
	var pf = _find_fighter(_player_id)
	if pf == null or _player == null:
		return
	var c: Dictionary = GameData.CLASSES[pf["classId"]]
	var title: String = ("%s the %s" % [char_name, c["name"]]) if char_name != "" else c["name"]
	_update_vitals(pf, title, c)
	var status := ""
	if not pf["alive"]:
		status = "respawning…   "
	status += "BOTS PAUSED — P engages" if _bots_frozen else "BOTS ACTIVE — P pauses"
	if _save_note != "":
		status += "   ·   " + _save_note
	_vit_set("status", _vit_status, status)
	_vit_status.add_theme_color_override("font_color",
		Palette.DANGER_SOFT if not pf["alive"] else (Palette.ACCENT2 if _bots_frozen else Palette.TEXT_DIM))
	_zone_banner.visible = true
	_vit_set("zone", _zone_label, "PRACTICE ARENA")
	var controls := "WASD move · 1-8 abilities · LMB basic · [b]Tab[/b] target · RMB-drag camera · wheel zoom · [b]N[/b] meter · [b]P[/b] pause bots · [b]R[/b] reset"
	if not class_locked:
		controls += " · [b]C[/b] class"
	if str(_vit_cache.get("hints", "")) != controls:      # the keybind line lives bottom-left now (_bar)
		_vit_cache["hints"] = controls
		_bar.text = "[color=#7f93a8]%s[/color]" % controls
	_info.text = ""
	_update_hotbar(pf)                           # the visual skill bar replaces the old text row
