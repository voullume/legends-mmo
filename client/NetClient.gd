extends "res://client/Client.gd"
## NETWORKED CLIENT (Phase 2). Extends the Phase-1 renderer and reuses every rendering helper;
## the only difference is WHERE the world comes from: instead of ticking the sim locally, it
## fills _state from server snapshots and sends its input to the server's controlled seam.
##
## Two transports, identical rendering:
##   ONLINE — a remote client: intents/snapshots via the Net RPC bridge.
##   HOST   — the player who is also hosting: talks to the in-process Server directly.

const REAUTH_INTERVAL := 1500.0   # re-issue a fresh access token every 25 min (< ~1h TTL)
const DESPAWN_GRACE := 3.0        # keep an out-of-interest node hidden this long before freeing
const RARITY_COLORS := {"common": "#cfd6df", "uncommon": "#7fe08a", "rare": "#5aa0ff", "epic": "#c77dff"}
const Quests := preload("res://shared/Quests.gd")

var net: Node = null         # RPC bridge
var server = null            # in-process server (unused in the shared zone)
# `supa` (the live Supabase session, refreshed locally) is inherited from Client.
var access_token := ""       # initial token sent on connect to identify our account
var autowalk := false        # debug: send a constant move intent (headless netcode test)
var _connected := false
var _aseq := 0               # monotonic ability sequence id (server de-dupes)
var _reauth_t := 0.0
var _absent := {}            # fighter id → seconds out of interest range (despawn hysteresis)
var _net_msg := ""           # connection/disconnection banner for the HUD
var _chatting := false       # typing in the chat box (suppresses movement/abilities)
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _chat_lines := []
var _chat_idle := 0.0        # seconds since the last chat/loot line — the log fades out after CHAT_FADE_AFTER
const CHAT_FADE_AFTER := 20.0
var _focus_id := ""          # tab-target: the chosen enemy (sticky — only Tab/Esc/death changes it)
var _focus_marker: Node3D = null
var _is_admin := false       # set by the server (recv_admin) only for the admin account
var _admin_panel: Control = null
var _friend_id := ""         # friendly focus: heal/buff target (click a party frame / Ctrl+Tab)
var _friend_marker: Node3D = null
var _party := []             # party roster from the snapshot (live HP)
var _party_panel: VBoxContainer = null
var _party_frames := []      # [{root, fid, fill, name}]
var _leave_btn: Button = null
var _invite_popup: Panel = null      # "Invite <name>?" after clicking a player
var _invite_prompt: Panel = null     # an incoming invite (accept/decline)
var _invite_from_fid := ""
var _inv_panel: Control
var _inv_label: RichTextLabel
var _chat_grace := 0          # frames after closing chat where input stays suppressed
var _inv_loading := false     # an inventory GET is in flight
var _inv_pending := false     # a refresh was requested while loading
var _shop_panel: Control = null
var _shop_buy_lbl: RichTextLabel = null
var _shop_sell_lbl: RichTextLabel = null
var _shop_info := {}          # catalog + roll/sell prices (from recv_shop_info)
var _shop_root: Node3D = null # the 3D shop pad visual
var _shop_sig := ""
var _shop_hint: Label = null  # "Press B to shop" proximity prompt
var _near_shop := false
var _shop_sell_cache := {}    # item_id -> {name, rarity, price} for the sell confirmation
var _sell_confirm: Panel = null
var _quests := {}             # quest_id -> {progress, completed} — server-pushed, server-authoritative
var _quest_panel: Control = null
var _quest_label: RichTextLabel = null
var _quest_tracker: VBoxContainer = null    # always-on HUD list of active quests
var _quest_tracker_title: Label = null
var _qgiver_panel: Control = null           # the home-base quest-giver dialog (accept / turn in)
var _qgiver_label: RichTextLabel = null
var _qgiver_root: Node3D = null             # the 3D quest-giver marker in the home base
var _qgiver_sig := ""
var _qgiver_hint: Label = null              # "Press E to talk" proximity prompt
var _near_qgiver := false
var _settings_panel: Control = null         # audio/options panel
var _last_level := 0                         # for the level-up sound
var _last_map := ""                          # for zone-change sound + music crossfade

# Replaces the LOCAL sandbox setup: no local match — wait for the server to assign a fighter.
func _enter_mode() -> void:
	Engine.max_fps = 60
	_player = PlayerCtl.new()
	add_child(_player)
	_player_id = ""              # set by assign_fighter()
	_build_chat()
	_build_inventory()
	_build_shop()
	_build_questlog()
	_build_qgiver_dialog()
	_build_settings()
	print("[netclient] ready — awaiting server fighter assignment")

func _build_chat() -> void:
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_active = false
	_chat_log.fit_content = true
	_chat_log.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_log.position = Vector2(16, -300)
	_chat_log.custom_minimum_size = Vector2(620, 230)
	_hud.add_child(_chat_log)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "say something…  (Enter sends · Esc cancels)"
	_chat_input.max_length = 120
	_chat_input.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_input.position = Vector2(16, -46)
	_chat_input.custom_minimum_size = Vector2(620, 34)
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submit)
	_chat_input.focus_exited.connect(_close_chat)
	_hud.add_child(_chat_input)

func _open_chat() -> void:
	_chatting = true
	_chat_input.visible = true
	_chat_input.grab_focus()

func _close_chat(_arg := "") -> void:
	if not _chatting:
		return
	_chatting = false
	_chat_grace = 2                          # a click that dismissed chat must not also fire an ability
	if _player != null:
		_player.intent["ability"] = ""
	_chat_input.text = ""
	_chat_input.visible = false
	_chat_input.release_focus()

func _on_chat_submit(text: String) -> void:
	var msg := text.strip_edges()
	if msg != "" and net != null and _connected:
		net.send_chat.rpc_id(1, msg)
	_close_chat()

# the chat/loot log fades out after CHAT_FADE_AFTER seconds of no new line (and while not typing)
func _update_chat_fade(delta: float) -> void:
	if _chat_log == null:
		return
	if _chatting:
		_chat_idle = 0.0
	else:
		_chat_idle += delta
	var target := 0.0 if _chat_idle > CHAT_FADE_AFTER else 1.0
	_chat_log.modulate.a = lerpf(_chat_log.modulate.a, target, clampf(delta * 2.5, 0.0, 1.0))

func recv_chat(sender: String, text: String) -> void:
	print("[chat] %s: %s" % [sender, text])
	# escape user-supplied brackets so they can't inject BBCode into the log
	_chat_lines.append("[color=#9fd0ff][b]%s[/b][/color]  %s" % [_esc(sender), _esc(text)])
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0                              # new line → pop the log back up
	_chat_log.modulate.a = 1.0

func _esc(s: String) -> String:
	return s.replace("[", "[lb]")

func _build_inventory() -> void:
	_inv_panel = CenterContainer.new()
	_inv_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_inv_panel.visible = false
	_hud.add_child(_inv_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(480, 0)
	_inv_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Inventory   (I to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	_inv_label = RichTextLabel.new()
	_inv_label.bbcode_enabled = true
	_inv_label.scroll_active = true
	_inv_label.custom_minimum_size = Vector2(440, 380)
	_inv_label.meta_clicked.connect(_on_item_clicked)
	vb.add_child(_inv_label)

func _toggle_inventory() -> void:
	_inv_panel.visible = not _inv_panel.visible
	if _inv_panel.visible:
		if _quest_panel != null:                     # only one full-screen modal at a time
			_quest_panel.visible = false
		_load_inventory()

func _load_inventory() -> void:
	if supa == null:
		return
	if _inv_loading:                         # coalesce concurrent loads → always show the latest result
		_inv_pending = true
		return
	_inv_loading = true
	_inv_label.text = "[color=#7f93a8]loading…[/color]"
	var r = await supa.get_inventory()
	_inv_loading = false
	if _inv_pending:
		_inv_pending = false
		_load_inventory()
		return
	if not r.get("ok"):
		_inv_label.text = "[color=#ff8a8a]couldn't load inventory[/color]"
		return
	var items: Array = r.get("items", [])
	if items.is_empty():
		_inv_label.text = "[color=#7f93a8]empty — kill mobs to find loot[/color]"
		return
	var lines := ["[color=#7f93a8]%d items · click to equip / unequip[/color]\n" % items.size()]
	for it in items:
		var col: String = RARITY_COLORS.get(str(it.get("rarity", "common")), "#cfd6df")
		var eq: bool = bool(it.get("equipped", false))
		var mark: String = "[color=#ffd24d]★ [/color]" if eq else "[color=#5a6472]○ [/color]"
		var bonus := ""
		if int(it.get("bonus_amt", 0)) != 0:
			bonus = "   [color=#9fe8a0]+%d %s[/color]" % [int(it["bonus_amt"]), str(it.get("bonus_stat", ""))]
		var meta: String = "%s|%s" % [str(it.get("id", "")), str(it.get("slot", ""))]
		lines.append("%s[url=%s][color=%s]%s[/color][/url]  [color=#7f93a8](%s · %s)[/color]%s" % [mark, meta, col, _esc(str(it.get("name", "?"))), str(it.get("rarity", "")), str(it.get("slot", "")), bonus])
	_inv_label.text = "\n".join(lines)

func _on_item_clicked(meta) -> void:
	var parts := str(meta).split("|")
	if parts.size() >= 2 and net != null and _connected:
		net.equip.rpc_id(1, parts[0], parts[1])

func recv_inventory_changed() -> void:
	if _inv_panel != null and _inv_panel.visible:
		_load_inventory()
	if _shop_panel != null and _shop_panel.visible:   # a buy/sell/roll changed our items + credits
		_render_shop_buy()
		_load_shop_sell()

# ---- quests (server-authoritative; the log + tracker render from server-pushed state) ----
# server pushes the full quest state once on join (recv_quest_state) and an update per change.
func recv_quest_state(states: Dictionary) -> void:
	_quests = {}
	for qid in states:
		var st = states[qid]
		_quests[str(qid)] = {"progress": int(st.get("progress", 0)), "completed": bool(st.get("completed", false))}
	_refresh_quests()

func recv_quest_update(quest_id: String, progress: int, completed: bool) -> void:
	var was = _quests.get(quest_id)
	_quests[quest_id] = {"progress": progress, "completed": completed}
	var q = Quests.get_quest(quest_id)
	if q != null:                                    # toast on newly-ready or newly-completed
		var cnt := int(q["objective"]["count"])
		if completed and (was == null or not bool(was.get("completed", false))):
			AudioManager.play_sfx("quest")
			_quest_toast("[color=#ffd24d]✔ Quest complete:[/color] %s" % _esc(str(q["name"])))
		elif progress >= cnt and (was == null or int(was.get("progress", 0)) < cnt):
			_quest_toast("[color=#9fe8a0]Quest ready to turn in:[/color] %s [color=#7f93a8](see the Quest Giver)[/color]" % _esc(str(q["name"])))
	_refresh_quests()

func _quest_toast(line: String) -> void:
	_chat_lines.append(line)
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0
	_chat_log.modulate.a = 1.0

func _refresh_quests() -> void:
	_update_quest_tracker()
	if _quest_panel != null and _quest_panel.visible:
		_render_questlog()
	if _qgiver_panel != null and _qgiver_panel.visible:
		_render_qgiver()

# the always-on HUD tracker (active quests + progress). Rebuilt only on a quest event, not per frame.
func _update_quest_tracker() -> void:
	if _quest_tracker == null:
		_quest_tracker = VBoxContainer.new()
		_quest_tracker.add_theme_constant_override("separation", 2)
		_hud.add_child(_quest_tracker)
		_reposition_quest_tracker()
		_hud.get_viewport().size_changed.connect(_reposition_quest_tracker)   # stay pinned on window resize
		_quest_tracker_title = Label.new()
		_quest_tracker_title.add_theme_font_size_override("font_size", 13)
		_quest_tracker_title.modulate = Color(1.0, 0.86, 0.5)
		_quest_tracker_title.text = "✦ Quests  (J)"
		_quest_tracker.add_child(_quest_tracker_title)
	for c in _quest_tracker.get_children():          # clear the per-quest lines, keep the title
		if c != _quest_tracker_title:
			c.queue_free()
	var any := false
	for qid in Quests.order():
		if not _quests.has(qid):
			continue
		var st = _quests[qid]
		if bool(st.get("completed", false)):
			continue
		var q = Quests.get_quest(qid)
		if q == null:
			continue
		any = true
		var cnt := int(q["objective"]["count"])
		var prog := int(st.get("progress", 0))
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 12)
		if prog >= cnt:
			lbl.text = "✓ %s  (ready)" % str(q["name"])
			lbl.modulate = Color(0.62, 0.9, 0.55)
		else:
			lbl.text = "• %s  %d/%d" % [str(q["name"]), prog, cnt]
			lbl.modulate = Color(0.85, 0.88, 0.95)
		_quest_tracker.add_child(lbl)
	_quest_tracker.visible = any

func _reposition_quest_tracker() -> void:
	if _quest_tracker != null:
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_quest_tracker.position = Vector2(vp.x - 250.0, 150.0)

func _build_questlog() -> void:
	_quest_panel = CenterContainer.new()
	_quest_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_quest_panel.visible = false
	_hud.add_child(_quest_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(560, 0)
	_quest_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Quest Journal   (J to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	_quest_label = RichTextLabel.new()
	_quest_label.bbcode_enabled = true
	_quest_label.scroll_active = true
	_quest_label.custom_minimum_size = Vector2(520, 440)
	vb.add_child(_quest_label)

func _toggle_questlog() -> void:
	if _quest_panel == null:
		return
	_quest_panel.visible = not _quest_panel.visible
	if _quest_panel.visible:
		if _inv_panel != null:                       # only one full-screen modal at a time
			_inv_panel.visible = false
		if _shop_panel != null:
			_shop_panel.visible = false
		if _qgiver_panel != null:
			_qgiver_panel.visible = false
		_render_questlog()

func _render_questlog() -> void:
	if _quest_label == null:
		return
	var pf = _find_fighter(_player_id)
	var lvl := int(pf.get("level", 1)) if pf != null else 1
	var active := []
	var avail := []
	var locked := []
	var done := []
	for qid in Quests.order():
		var q = Quests.get_quest(qid)
		if q == null:
			continue
		var cnt := int(q["objective"]["count"])
		var nm: String = _esc(str(q["name"]))
		var desc: String = _esc(str(q.get("desc", "")))
		if _quests.has(qid):
			var st = _quests[qid]
			if bool(st.get("completed", false)):
				done.append("[color=#6b7686]✓ %s[/color]" % nm)
			else:
				var prog := int(st.get("progress", 0))
				if prog >= cnt:
					active.append("[color=#9fe8a0]%s  (%d/%d) — ready, turn in at the Quest Giver[/color]\n   [color=#7f93a8]%s[/color]" % [nm, prog, cnt, desc])
				else:
					active.append("[color=#dfe6f0]%s[/color]  [color=#8ad6ff]%d/%d[/color]\n   [color=#7f93a8]%s[/color]" % [nm, prog, cnt, desc])
		else:
			var prereq := str(q.get("prereq", ""))
			var minl := int(q.get("min_level", 1))
			var prereq_ok: bool = prereq == "" or (_quests.has(prereq) and bool(_quests[prereq].get("completed", false)))
			if lvl >= minl and prereq_ok:
				avail.append("[color=#dfe6f0]%s[/color]\n   [color=#7f93a8]%s[/color]  [color=#5a6472](reward: %s)[/color]" % [nm, desc, _reward_text(q)])
			else:
				var reason: String = ("needs lvl %d" % minl) if lvl < minl else ("requires: %s" % _esc(_prereq_name(prereq)))
				locked.append("[color=#5a6472]🔒 %s  (%s)[/color]" % [nm, reason])
	var out := ["[color=#7f93a8]Accept & turn in quests at the [color=#ffd24d]Quest Giver[/color] in the Home Base (press E near it).[/color]\n"]
	if not active.is_empty():
		out.append("[b][color=#8ad6ff]Active[/color][/b]")
		out.append_array(active)
	if not avail.is_empty():
		out.append("\n[b][color=#9fe8a0]Available[/color][/b]")
		out.append_array(avail)
	if not locked.is_empty():
		out.append("\n[b][color=#7f93a8]Locked[/color][/b]")
		out.append_array(locked)
	if not done.is_empty():
		out.append("\n[b][color=#6b7686]Completed[/color][/b]")
		out.append_array(done)
	if active.is_empty() and avail.is_empty() and locked.is_empty() and done.is_empty():
		out.append("[color=#7f93a8]No quests available yet.[/color]")
	_quest_label.text = "\n".join(out)

func _reward_text(q: Dictionary) -> String:
	var rw: Dictionary = q.get("rewards", {})
	var parts := []
	if int(rw.get("xp", 0)) > 0:
		parts.append("%d xp" % int(rw["xp"]))
	if int(rw.get("credits", 0)) > 0:
		parts.append("◈%d" % int(rw["credits"]))
	if rw.has("item"):
		parts.append("%s item" % str((rw["item"] as Dictionary).get("rarity", "")))
	return ", ".join(parts)

func _prereq_name(prereq: String) -> String:
	var q = Quests.get_quest(prereq)
	return str(q["name"]) if q != null else prereq

func _on_quest_meta(meta) -> void:
	if net == null or not _connected:
		return
	var p := str(meta).split("|")
	if p.size() >= 2 and (p[0] == "accept" or p[0] == "turnin"):
		net.quest_action.rpc_id(1, p[0], p[1])      # server re-validates you're at the home-base giver

# ---- quest giver (home-base NPC: the ONLY place to accept / turn in; J is a read-only journal) ----
func _build_qgiver_dialog() -> void:
	_qgiver_panel = CenterContainer.new()
	_qgiver_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_qgiver_panel.visible = false
	_hud.add_child(_qgiver_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(560, 0)
	_qgiver_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "📜 Quest Giver   (E to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	_qgiver_label = RichTextLabel.new()
	_qgiver_label.bbcode_enabled = true
	_qgiver_label.scroll_active = true
	_qgiver_label.custom_minimum_size = Vector2(520, 440)
	_qgiver_label.meta_clicked.connect(_on_quest_meta)
	vb.add_child(_qgiver_label)

func _toggle_qgiver() -> void:
	if _qgiver_panel == null:
		return
	_qgiver_panel.visible = not _qgiver_panel.visible
	if _qgiver_panel.visible:
		if _inv_panel != null:                       # only one full-screen panel at a time
			_inv_panel.visible = false
		if _shop_panel != null:
			_shop_panel.visible = false
		if _quest_panel != null:
			_quest_panel.visible = false
		_render_qgiver()

func _render_qgiver() -> void:
	if _qgiver_label == null:
		return
	var pf = _find_fighter(_player_id)
	var lvl := int(pf.get("level", 1)) if pf != null else 1
	var ready := []
	var avail := []
	var active := []
	for qid in Quests.order():
		var q = Quests.get_quest(qid)
		if q == null:
			continue
		var cnt := int(q["objective"]["count"])
		var nm: String = _esc(str(q["name"]))
		var desc: String = _esc(str(q.get("desc", "")))
		if _quests.has(qid):
			var st = _quests[qid]
			if bool(st.get("completed", false)):
				continue
			var prog := int(st.get("progress", 0))
			if prog >= cnt:
				ready.append("[url=turnin|%s][color=#ffd24d][b][Turn In][/b][/color][/url]  [color=#9fe8a0]%s[/color]  [color=#5a6472](reward: %s)[/color]" % [qid, nm, _reward_text(q)])
			else:
				active.append("[color=#dfe6f0]%s[/color]  [color=#8ad6ff]%d/%d[/color]" % [nm, prog, cnt])
		else:
			var prereq := str(q.get("prereq", ""))
			var minl := int(q.get("min_level", 1))
			var prereq_ok: bool = prereq == "" or (_quests.has(prereq) and bool(_quests[prereq].get("completed", false)))
			if lvl >= minl and prereq_ok:
				avail.append("[url=accept|%s][color=#9fe8a0][b][Accept][/b][/color][/url]  [color=#dfe6f0]%s[/color]\n   [color=#7f93a8]%s[/color]  [color=#5a6472](reward: %s)[/color]" % [qid, nm, desc, _reward_text(q)])
	var out := []
	if not ready.is_empty():
		out.append("[b][color=#ffd24d]Ready to turn in[/color][/b]")
		out.append_array(ready)
	if not avail.is_empty():
		out.append(("\n" if not ready.is_empty() else "") + "[b][color=#9fe8a0]Available[/color][/b]")
		out.append_array(avail)
	if not active.is_empty():
		out.append("\n[b][color=#8ad6ff]In progress[/color][/b]")
		out.append_array(active)
	if out.is_empty():
		out.append("[color=#7f93a8]Nothing for you right now — come back after you level up or finish a quest.[/color]")
	_qgiver_label.text = "\n".join(out)

# the blue quest-giver marker in the home base + the "press E" proximity prompt (mirrors the shop pad)
func _render_questgiver_pad() -> void:
	var qg = _state.get("questgiver")
	var sig := JSON.stringify(qg)
	if sig == _qgiver_sig:
		return
	_qgiver_sig = sig
	if _qgiver_root != null:
		_qgiver_root.queue_free()
		_qgiver_root = null
	if qg == null or _world_root == null:
		return
	_qgiver_root = Node3D.new()
	_world_root.add_child(_qgiver_root)
	var pos := Vector3((float(qg["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(qg["y"]) - _ah() / 2.0) * SCALE)
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = World.QUESTGIVER_RADIUS * SCALE * 0.5
	cyl.bottom_radius = World.QUESTGIVER_RADIUS * SCALE * 0.6
	cyl.height = 2.6
	pillar.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.74, 1.0, 0.32)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.42, 0.66, 1.0)
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.material_override = mat
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pillar.position = pos + Vector3(0.0, 1.3, 0.0)
	_qgiver_root.add_child(pillar)
	var lbl := Label3D.new()
	lbl.text = "📜 Quest Giver"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0016
	lbl.font_size = 52
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = Color(0.72, 0.85, 1.0)
	lbl.position = pos + Vector3(0.0, 3.4, 0.0)
	_qgiver_root.add_child(lbl)

func _update_questgiver_proximity() -> void:
	if _qgiver_hint == null:
		_qgiver_hint = Label.new()
		_qgiver_hint.add_theme_font_size_override("font_size", 18)
		_qgiver_hint.modulate = Color(0.72, 0.85, 1.0)
		_qgiver_hint.visible = false
		_hud.add_child(_qgiver_hint)
	var qg = _state.get("questgiver")
	var pf = _find_fighter(_player_id)
	_near_qgiver = false
	if qg != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(qg["x"]), float(pf["y"]) - float(qg["y"])).length()
		_near_qgiver = d <= World.QUESTGIVER_RADIUS
	if _near_qgiver and (_qgiver_panel == null or not _qgiver_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_qgiver_hint.text = "Press [E] to talk to the Quest Giver"
		_qgiver_hint.position = Vector2(vp.x / 2.0 - 140.0, vp.y - 180.0)
		_qgiver_hint.visible = true
	else:
		_qgiver_hint.visible = false
	if not _near_qgiver and _qgiver_panel != null and _qgiver_panel.visible:
		_qgiver_panel.visible = false                  # walked away → close the dialog

# ---- settings (audio volumes + mute; persisted by AudioManager to user://settings.cfg) ----
func _build_settings() -> void:
	_settings_panel = CenterContainer.new()
	_settings_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings_panel.visible = false
	_hud.add_child(_settings_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(400, 0)
	_settings_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Settings   (O to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	for bus in ["Master", "Music", "SFX"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lbl := Label.new()
		lbl.text = bus
		lbl.custom_minimum_size = Vector2(70, 0)
		row.add_child(lbl)
		var sl := HSlider.new()
		sl.min_value = 0.0
		sl.max_value = 1.0
		sl.step = 0.01
		sl.custom_minimum_size = Vector2(240, 0)
		sl.value = float(AudioManager.vol.get(bus, 0.9))
		sl.value_changed.connect(_set_vol.bind(bus))
		row.add_child(sl)
		vb.add_child(row)
	var mute := CheckBox.new()
	mute.text = "Mute all"
	mute.button_pressed = AudioManager.muted
	mute.toggled.connect(func(on: bool) -> void: AudioManager.set_muted(on))
	vb.add_child(mute)

func _set_vol(v: float, bus: String) -> void:
	AudioManager.set_volume(bus, v)

func _toggle_settings() -> void:
	if _settings_panel == null:
		return
	_settings_panel.visible = not _settings_panel.visible

# ---- shop (home-zone economy: buy from a catalog, gamble a roll, sell inventory back) ----
func recv_shop_info(info: Dictionary) -> void:
	_shop_info = info

func _build_shop() -> void:
	_shop_panel = CenterContainer.new()
	_shop_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop_panel.visible = false
	_hud.add_child(_shop_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(680, 0)
	_shop_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Shop   (B to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	vb.add_child(hb)
	_shop_buy_lbl = RichTextLabel.new()
	_shop_buy_lbl.bbcode_enabled = true
	_shop_buy_lbl.scroll_active = true
	_shop_buy_lbl.custom_minimum_size = Vector2(330, 430)
	_shop_buy_lbl.meta_clicked.connect(_on_shop_meta)
	hb.add_child(_shop_buy_lbl)
	_shop_sell_lbl = RichTextLabel.new()
	_shop_sell_lbl.bbcode_enabled = true
	_shop_sell_lbl.scroll_active = true
	_shop_sell_lbl.custom_minimum_size = Vector2(330, 430)
	_shop_sell_lbl.meta_clicked.connect(_on_shop_meta)
	hb.add_child(_shop_sell_lbl)

func _toggle_shop() -> void:
	if _shop_panel == null:
		return
	_shop_panel.visible = not _shop_panel.visible
	if _shop_panel.visible:
		_render_shop_buy()
		_load_shop_sell()
	else:
		_close_sell_confirm()

func _my_credits() -> int:
	var pf = _find_fighter(_player_id)
	return int(pf.get("credits", 0)) if pf != null else 0

func _render_shop_buy() -> void:
	if _shop_buy_lbl == null:
		return
	var lines := ["[b]BUY[/b]   [color=#ffd24d]%d credits[/color]\n" % _my_credits()]
	lines.append("[color=#7f93a8]Catalog — click to buy:[/color]")
	for e in _shop_info.get("catalog", []):
		var col: String = RARITY_COLORS.get(str(e.get("rarity", "")), "#cfd6df")
		lines.append("[url=buy|%s|%s][color=%s]%s[/color][/url] [color=#9fe8a0]+%d %s[/color] — [color=#ffd24d]%d[/color]" % [
			str(e["slot"]), str(e["rarity"]), col, _esc(str(e["name"])), int(e["bonus_amt"]), str(e["bonus_stat"]), int(e["price"])])
	lines.append("\n[color=#7f93a8]Random roll (random item of that tier):[/color]")
	var roll: Dictionary = _shop_info.get("roll", {})
	for rar in ["common", "uncommon", "rare", "epic"]:
		if roll.has(rar):
			lines.append("[url=roll|%s][color=%s]Roll %s[/color][/url] — [color=#ffd24d]%d[/color]" % [rar, RARITY_COLORS.get(rar, "#cfd6df"), rar.capitalize(), int(roll[rar])])
	_shop_buy_lbl.text = "\n".join(lines)

func _load_shop_sell() -> void:
	if _shop_sell_lbl == null or supa == null:
		return
	_shop_sell_lbl.text = "[b]SELL[/b]\n[color=#7f93a8]loading…[/color]"
	var r = await supa.get_inventory()
	if _shop_sell_lbl == null:
		return
	if not r.get("ok"):
		_shop_sell_lbl.text = "[b]SELL[/b]\n[color=#ff8a8a]couldn't load inventory[/color]"
		return
	var items: Array = r.get("items", [])
	var sell: Dictionary = _shop_info.get("sell", {})
	_shop_sell_cache.clear()
	var lines := ["[b]SELL[/b]   [color=#7f93a8]click to sell[/color]\n"]
	if items.is_empty():
		lines.append("[color=#7f93a8]nothing to sell — go earn some loot[/color]")
	for it in items:
		var iid: String = str(it.get("id", ""))
		var rar: String = str(it.get("rarity", "common"))
		var col: String = RARITY_COLORS.get(rar, "#cfd6df")
		var price: int = int(sell.get(rar, 0))
		var eq: String = " [color=#ffd24d]★[/color]" if bool(it.get("equipped", false)) else ""
		_shop_sell_cache[iid] = {"name": str(it.get("name", "?")), "rarity": rar, "price": price}
		lines.append("[url=sell|%s][color=%s]%s[/color][/url]%s [color=#7f93a8](%s)[/color] — [color=#ffd24d]%d[/color]" % [
			iid, col, _esc(str(it.get("name", "?"))), eq, str(it.get("slot", "")), price])
	_shop_sell_lbl.text = "\n".join(lines)

func _on_shop_meta(meta) -> void:
	if net == null or not _connected:
		return
	var p := str(meta).split("|")
	match p[0]:
		"buy":
			if p.size() >= 3:
				net.shop_buy.rpc_id(1, p[1], p[2])
		"roll":
			if p.size() >= 2:
				net.shop_roll.rpc_id(1, p[1])
		"sell":
			if p.size() >= 2:
				_show_sell_confirm(p[1])        # confirm before selling (avoid mis-clicks)

func _show_sell_confirm(item_id: String) -> void:
	var info = _shop_sell_cache.get(item_id)
	if info == null:
		return
	_close_sell_confirm()
	_sell_confirm = Panel.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_sell_confirm.add_child(vb)
	var lbl := Label.new()
	lbl.text = "Sell %s (%s) for ◈%d?" % [str(info["name"]), str(info["rarity"]), int(info["price"])]
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var yes := Button.new()
	yes.text = "Sell"
	yes.pressed.connect(func() -> void:
		if net != null and _connected:
			net.shop_sell.rpc_id(1, item_id)
		_close_sell_confirm())
	row.add_child(yes)
	var no := Button.new()
	no.text = "Cancel"
	no.pressed.connect(_close_sell_confirm)
	row.add_child(no)
	_hud.add_child(_sell_confirm)
	_sell_confirm.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_sell_confirm.position = Vector2((vp.x - _sell_confirm.size.x) / 2.0, vp.y / 2.0 - 40.0)

func _close_sell_confirm() -> void:
	if _sell_confirm != null:
		_sell_confirm.queue_free()
		_sell_confirm = null

# the gold shop pad in the home base + the "press B" proximity prompt
func _render_shop_pad() -> void:
	var shop = _state.get("shop")
	var sig := JSON.stringify(shop)
	if sig == _shop_sig:
		return
	_shop_sig = sig
	if _shop_root != null:
		_shop_root.queue_free()
		_shop_root = null
	if shop == null or _world_root == null:
		return
	_shop_root = Node3D.new()
	_world_root.add_child(_shop_root)
	var pos := Vector3((float(shop["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(shop["y"]) - _ah() / 2.0) * SCALE)
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = World.SHOP_RADIUS * SCALE * 0.5
	cyl.bottom_radius = World.SHOP_RADIUS * SCALE * 0.6
	cyl.height = 2.6
	pillar.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.82, 0.3, 0.34)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.78, 0.25)
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.material_override = mat
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pillar.position = pos + Vector3(0.0, 1.3, 0.0)
	_shop_root.add_child(pillar)
	var lbl := Label3D.new()
	lbl.text = "🛒 Shop"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0016
	lbl.font_size = 52
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = Color(1.0, 0.88, 0.5)
	lbl.position = pos + Vector3(0.0, 3.4, 0.0)
	_shop_root.add_child(lbl)

func _update_shop_proximity() -> void:
	if _shop_hint == null:
		_shop_hint = Label.new()
		_shop_hint.add_theme_font_size_override("font_size", 18)
		_shop_hint.modulate = Color(1.0, 0.88, 0.5)
		_shop_hint.visible = false
		_hud.add_child(_shop_hint)
	var shop = _state.get("shop")
	var pf = _find_fighter(_player_id)
	_near_shop = false
	if shop != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(shop["x"]), float(pf["y"]) - float(shop["y"])).length()
		_near_shop = d <= World.SHOP_RADIUS
	if _near_shop and (_shop_panel == null or not _shop_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_shop_hint.text = "Press [B] to shop"
		_shop_hint.position = Vector2(vp.x / 2.0 - 70.0, vp.y - 150.0)
		_shop_hint.visible = true
	else:
		_shop_hint.visible = false
	if not _near_shop and _shop_panel != null and _shop_panel.visible:
		_shop_panel.visible = false                  # walked away → close the shop
		_close_sell_confirm()

# ---- admin tool (only the admin account ever receives recv_admin) ----
func recv_admin(on: bool) -> void:
	_is_admin = on
	if on and _admin_panel == null:
		_build_admin_panel()

func _build_admin_panel() -> void:
	_admin_panel = PanelContainer.new()
	var vb := VBoxContainer.new()
	_admin_panel.add_child(vb)
	var title := Label.new()
	title.text = "⚙ ADMIN  (F1)"
	vb.add_child(title)
	var cmds := [
		["Level +", "level_up", {}], ["Level -", "level_down", {}], ["+100 XP", "add_xp", {"amt": 100}], ["+500 Credits", "add_credits", {"amt": 500}],
		["Give Item", "give_item", {}], ["Clear Items", "clear_items", {}],
		["God Mode", "god", {}], ["Heal", "heal", {}],
		["→ Home", "goto", {"map": "home"}], ["→ Combat", "goto", {"map": "combat"}],
		["→ Frontier", "goto", {"map": "frontier"}], ["→ Arena", "goto", {"map": "arena"}],
		["Spawn Mob", "spawn_mob", {"level": 3}], ["Clear Mobs", "clear_mobs", {}], ["Reset Mobs", "reset_mobs", {}],
	]
	for c in cmds:
		var b := Button.new()
		b.text = str(c[0])
		var cmd: String = str(c[1])
		var args: Dictionary = c[2]
		b.pressed.connect(func() -> void: _admin(cmd, args))
		vb.add_child(b)
	_hud.add_child(_admin_panel)
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_admin_panel.position = Vector2(vp.x - 180.0, 70.0)
	_admin_panel.visible = false

func _admin(cmd: String, args: Dictionary) -> void:
	if _is_admin and net != null and _connected:
		net.admin_cmd.rpc_id(1, cmd, args)

func recv_loot(item: String, rarity: String, slot: String, amt: int, stat: String) -> void:
	print("[loot] %s [%s] +%d %s" % [item, rarity, amt, stat])
	AudioManager.play_sfx("loot")
	var col: String = RARITY_COLORS.get(rarity, "#cfd6df")
	var bonus := ("   +%d %s" % [amt, stat]) if amt != 0 else ""
	_chat_lines.append("[color=#ffd24d]★ Looted[/color] [color=%s]%s[/color] [color=#7f93a8](%s · %s)%s[/color]" % [col, _esc(item), rarity, slot, bonus])
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0                              # new line → pop the log back up
	_chat_log.modulate.a = 1.0
	if _inv_panel.visible:
		_load_inventory()

# input runs at the fixed physics rate (bounded), independent of render fps
var _aw_t := 0
var _auto_equipped := false
var _aw_invited := false
var _aw_shopped := false
func _auto_equip() -> void:                          # debug: equip the first looted item
	if supa == null:
		return
	var r = await supa.get_inventory()
	if r.get("ok") and r.get("items", []).size() > 0:
		var it = r["items"][0]
		print("[equip] auto-equipping %s" % str(it.get("name")))
		net.equip.rpc_id(1, str(it["id"]), str(it["slot"]))

func _physics_process(_delta: float) -> void:
	if _player == null or _player_id == "":
		return
	_update_chat_fade(_delta)
	if _chat_grace > 0:
		_chat_grace -= 1
	if _chatting or _chat_grace > 0:
		_player.intent["mx"] = 0.0                   # hold still while typing (and the frame after, so
		_player.intent["my"] = 0.0                   # the click that dismissed chat doesn't fire an ability)
		_player.intent["ability"] = ""
	elif autowalk:
		_player.intent["mx"] = 0.0                   # debug: stand and fight (combat / XP tests)
		_player.intent["my"] = 0.0
		_aw_t += 1
		if _aw_t % 12 == 0:
			var ks: Array = _player.ability_keys()
			if ks.size() > 0:
				_player.intent["ability"] = ks[0]
		if _aw_t == 30 and net != null and _connected:   # debug: exercise the chat path once
			net.send_chat.rpc_id(1, "hello from the test bot")
		if _aw_t == 60 and not _aw_shopped and net != null and _connected:   # debug: buy from the shop once
			_aw_shopped = true
			net.shop_buy.rpc_id(1, "weapon", "common")
		if _aw_t == 90 and not _aw_invited and net != null and _connected:   # debug: invite the first other player
			for f in _state.get("fighters", []):
				if int(f.get("team", 0)) == 0 and str(f["id"]) != _player_id:
					_aw_invited = true
					net.party_invite.rpc_id(1, str(f["id"]))
					break
		if _aw_t == 720 and not _auto_equipped:          # debug: equip a looted item (~12s in)
			_auto_equipped = true
			_auto_equip()
	else:
		_player.poll(_yaw)
	_send_movement()                                 # unreliable, latest-wins
	if not _chatting and _player.intent["ability"] != "":
		_send_ability(_player.intent["ability"])     # reliable, de-duplicated
		_player.intent["ability"] = ""

func _send_movement() -> void:
	var mv := {"mx": _player.intent["mx"], "my": _player.intent["my"], "target": _focus_id, "friend": _friend_id}
	if server != null:
		server.submit_intent_local(1, mv)
	elif net != null and _connected:
		net.submit_intent.rpc_id(1, mv)

# Tab-target: sticky cycle through alive enemies, nearest-first. Holds the chosen target until Tab
# (next), Esc (clear), or it dies/leaves (cleared in _update_focus).
func _cycle_focus() -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	var enemies := []
	for f in _state.get("fighters", []):
		if str(f["id"]) == _player_id or not bool(f.get("alive", true)):
			continue
		if _hostile_pair(pf, f):                     # team enemies + non-party players in a PvP zone
			enemies.append(f)
	if enemies.is_empty():
		_focus_id = ""
		return
	var px: float = float(pf["x"])
	var py: float = float(pf["y"])
	enemies.sort_custom(func(a, b): return Vector2(float(a["x"]) - px, float(a["y"]) - py).length_squared() < Vector2(float(b["x"]) - px, float(b["y"]) - py).length_squared())
	var cur := -1
	for i in enemies.size():
		if str(enemies[i]["id"]) == _focus_id:
			cur = i
			break
	var nxt: int = ((cur + 1) % enemies.size()) if cur >= 0 else 0
	_focus_id = str(enemies[nxt]["id"])

# clear a dead/gone focus, and draw the ring marker on the current target
func _update_focus() -> void:
	if _focus_id != "":
		var ft = _find_fighter(_focus_id)
		if ft == null or not bool(ft.get("alive", true)):
			_focus_id = ""
	if _focus_marker == null:
		_focus_marker = _make_focus_marker()
	if _focus_marker == null:
		return
	var t = _find_fighter(_focus_id) if _focus_id != "" else null
	if t != null:
		_focus_marker.visible = true
		_focus_marker.position = _world(t) + Vector3(0.0, 0.09, 0.0)
		_focus_marker.scale = Vector3.ONE * _ring_pulse()
	else:
		_focus_marker.visible = false

func _ring_pulse() -> float:
	return 1.0 + 0.09 * sin(Time.get_ticks_msec() / 1000.0 * 5.0)   # gentle in/out so it draws the eye

func _make_focus_marker() -> Node3D:
	if _world_root == null:
		return null
	return _make_target_ring(Color(1.0, 0.32, 0.26))   # enemy target = red, encircling the base disc

# a bright flat ring that sits AROUND the fighter's base disc (radius ~1.25) so it reads at a glance
func _make_target_ring(col: Color) -> Node3D:
	if _world_root == null:
		return null
	var m := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.28
	torus.outer_radius = 1.62
	torus.rings = 6
	m.mesh = torus                               # TorusMesh is already flat in the XZ plane (lies on the ground)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 4.0
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.visible = false
	_world_root.add_child(m)
	return m

# ---- parties: HUD frames (live HP, click to pick a heal/buff target), friend ring, invites ----
func _update_party() -> void:
	if _friend_id != "" and not _in_party(_friend_id) and _friend_id != _player_id:
		_friend_id = ""
	_sync_party_panel()
	if _friend_marker == null:
		_friend_marker = _make_friend_marker()
	if _friend_marker != null:
		var t = _find_fighter(_friend_id) if _friend_id != "" else null
		_friend_marker.visible = t != null
		if t != null:
			_friend_marker.position = _world(t) + Vector3(0.0, 0.07, 0.0)
			_friend_marker.scale = Vector3.ONE * _ring_pulse()

func _in_party(fid: String) -> bool:
	for m in _party:
		if str(m.get("fid", "")) == fid:
			return true
	return false

func _sync_party_panel() -> void:
	if _party_panel == null:
		_party_panel = VBoxContainer.new()
		_party_panel.add_theme_constant_override("separation", 4)
		_party_panel.position = Vector2(12.0, 150.0)
		_hud.add_child(_party_panel)
		_leave_btn = Button.new()
		_leave_btn.text = "Leave Party"
		_leave_btn.pressed.connect(func() -> void:
			if net != null and _connected:
				net.party_leave.rpc_id(1)
			_friend_id = "")
		_party_panel.add_child(_leave_btn)
	var fids := []
	for m in _party:
		fids.append(str(m["fid"]))
	var cur := []
	for fr in _party_frames:
		cur.append(str(fr["fid"]))
	if fids != cur:                                  # membership changed → rebuild frames
		for fr in _party_frames:
			fr["root"].queue_free()
		_party_frames.clear()
		for fid in fids:
			_party_frames.append(_make_party_frame(fid))
		_party_panel.move_child(_leave_btn, _party_panel.get_child_count() - 1)   # keep it at the bottom
	_leave_btn.visible = _party.size() > 0           # only while actually in a party
	for i in _party_frames.size():
		var m = _party[i]
		var fr = _party_frames[i]
		var frac: float = clampf(float(m["hp"]) / max(float(m["maxHP"]), 1.0), 0.0, 1.0)
		fr["fill"].size = Vector2(146.0 * frac, 14.0)
		fr["fill"].color = Color(0.3, 0.8, 0.4) if bool(m["alive"]) else Color(0.5, 0.5, 0.55)
		var you: String = "  [you]" if str(m["fid"]) == _player_id else ""
		fr["name"].text = "%s  %d/%d%s" % [str(m["name"]), int(m["hp"]), int(m["maxHP"]), you]
		fr["sel"].visible = (str(m["fid"]) == _friend_id)

func _make_party_frame(fid: String) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(152.0, 36.0)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var sel := ColorRect.new()
	sel.size = Vector2(152.0, 36.0)
	sel.color = Color(1.0, 0.85, 0.3, 0.22)
	sel.visible = false
	root.add_child(sel)
	var nm := Label.new()
	nm.position = Vector2(5.0, 1.0)
	nm.add_theme_font_size_override("font_size", 12)
	root.add_child(nm)
	var bg := ColorRect.new()
	bg.position = Vector2(3.0, 20.0)
	bg.size = Vector2(146.0, 14.0)
	bg.color = Color(0, 0, 0, 0.5)
	root.add_child(bg)
	var fill := ColorRect.new()
	fill.position = Vector2(3.0, 20.0)
	fill.size = Vector2(146.0, 14.0)
	fill.color = Color(0.3, 0.8, 0.4)
	root.add_child(fill)
	root.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select_friend(fid))
	_party_panel.add_child(root)
	return {"root": root, "fid": fid, "fill": fill, "name": nm, "sel": sel}

func _select_friend(fid: String) -> void:
	_friend_id = "" if _friend_id == fid else fid   # click the frame again to clear

# Ctrl+Tab cycles the heal/buff target through the party (self included)
func _cycle_friend() -> void:
	var ids := []
	for m in _party:
		ids.append(str(m["fid"]))
	if ids.is_empty():
		_friend_id = ""
		return
	var cur := ids.find(_friend_id)
	_friend_id = ids[(cur + 1) % ids.size()] if cur >= 0 else ids[0]

func _make_friend_marker() -> Node3D:
	return _make_target_ring(Color(0.35, 0.95, 0.5))   # ally heal/buff target = green

# the OTHER player nearest the cursor in screen space (for click-to-invite)
func _player_under_cursor() -> Dictionary:
	if _cam == null:
		return {}
	var mp: Vector2 = _hud.get_viewport().get_mouse_position()
	var best := {}
	var bestd := 54.0
	for f in _state.get("fighters", []):
		if int(f.get("team", 0)) != 0 or str(f["id"]) == _player_id or not _nodes.has(f["id"]):
			continue
		var wp: Vector3 = _world(f) + Vector3(0.0, 1.0, 0.0)
		if _cam.is_position_behind(wp):
			continue
		var d: float = _cam.unproject_position(wp).distance_to(mp)
		if d < bestd:
			bestd = d
			best = f
	return best

# returns true if the click landed on an invitable player (so we swallow it, no basic attack)
func _try_invite_click() -> bool:
	var p := _player_under_cursor()
	if p.is_empty() or _in_party(str(p["id"])):
		return false
	var nm: String = str(p.get("name", GameData.CLASSES[str(p["classId"])]["name"]))
	_show_invite_popup(str(p["id"]), nm)
	return true

func _show_invite_popup(fid: String, nm: String) -> void:
	if _invite_popup != null:
		_invite_popup.queue_free()
	_invite_popup = Panel.new()
	var vb := VBoxContainer.new()
	_invite_popup.add_child(vb)
	var lbl := Label.new()
	lbl.text = "Invite %s?" % nm
	vb.add_child(lbl)
	var btn := Button.new()
	btn.text = "Invite to Party"
	btn.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_invite.rpc_id(1, fid)
		_invite_popup.queue_free()
		_invite_popup = null)
	vb.add_child(btn)
	_hud.add_child(_invite_popup)
	_invite_popup.reset_size()
	_invite_popup.position = _hud.get_viewport().get_mouse_position() + Vector2(10.0, 10.0)

# an incoming invite → accept/decline prompt
func recv_party_invite(inviter_name: String, inviter_fid: String) -> void:
	if autowalk:                                     # test bots auto-accept (skip the UI)
		if net != null and _connected:
			net.party_accept.rpc_id(1, inviter_fid)
		return
	_invite_from_fid = inviter_fid
	if _invite_prompt != null:
		_invite_prompt.queue_free()
	_invite_prompt = Panel.new()
	var vb := VBoxContainer.new()
	_invite_prompt.add_child(vb)
	var lbl := Label.new()
	lbl.text = "%s invited you to a party" % inviter_name
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	vb.add_child(row)
	var yes := Button.new()
	yes.text = "Accept"
	yes.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_accept.rpc_id(1, _invite_from_fid)
		_close_invite_prompt())
	row.add_child(yes)
	var no := Button.new()
	no.text = "Decline"
	no.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_decline.rpc_id(1)
		_close_invite_prompt())
	row.add_child(no)
	_hud.add_child(_invite_prompt)
	_invite_prompt.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_invite_prompt.position = Vector2((vp.x - _invite_prompt.size.x) / 2.0, 120.0)

func _close_invite_prompt() -> void:
	if _invite_prompt != null:
		_invite_prompt.queue_free()
		_invite_prompt = null

func _send_ability(key: String) -> void:
	_play_cast_sound(key)
	_aseq += 1
	if server != null:
		server.submit_ability_local(1, key, _aseq)
	elif net != null and _connected:
		net.submit_ability.rpc_id(1, key, _aseq)

# a cast sound for the local player's ability, mapped from its type (only if it's off cooldown,
# so spamming a key on cooldown doesn't machine-gun the sound).
func _play_cast_sound(key: String) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	if float((pf.get("cds", {}) as Dictionary).get(key, 0.0)) > 0.0:
		return
	var c = GameData.CLASSES.get(pf["classId"])
	if c == null:
		return
	for ab in c["abilities"]:
		if ab["key"] == key:
			var nm := "cast_ability"
			if ab.get("ult", false):
				nm = "cast_ult"
			else:
				match ab["type"]:
					"melee", "meleeAoe", "dashAttack", "leapAttack": nm = "cast_melee"
					"projectile", "barrage": nm = "cast_ranged"
					"allybuff", "allyheal", "teamheal": nm = "cast_support"
			AudioManager.play_sfx(nm, _world(pf))
			return

# render only — the server owns the sim
func _process(delta: float) -> void:
	if supa != null and net != null and _connected:
		_reauth_t += delta
		if _reauth_t >= REAUTH_INTERVAL:
			_reauth_t = 0.0
			_do_reauth()
	if _state.is_empty():
		_update_hud()          # still show the connecting/error banner before any snapshot
		return
	_sync_nodes_to_state()
	_render_world(delta)
	_update_focus()
	_update_party()
	_render_shop_pad()
	_update_shop_proximity()
	_render_questgiver_pad()
	_update_questgiver_proximity()

# ---- transport callbacks ----
func _on_connected() -> void:
	_connected = true
	_net_msg = ""
	print("[netclient] connected — authenticating to the zone")
	if net != null:
		net.authenticate.rpc_id(1, access_token)

# keep the server's access token fresh without ever sending the refresh token over the wire
func _do_reauth() -> void:
	if supa != null and await supa.refresh_session() and net != null:
		net.reauth.rpc_id(1, supa.access_token)

# shown on the HUD when the connection fails or the server goes away
func net_error(msg: String) -> void:
	_net_msg = msg
	push_warning("[netclient] " + msg)

func receive_snapshot(snap: Dictionary) -> void:
	_state = snap
	_party = snap.get("party", [])
	if _player != null and _player_id != "":
		var pf = _find_fighter(_player_id)
		if pf != null and _player.class_id != pf["classId"]:
			_player.class_id = pf["classId"]
	var map := str(snap.get("map", ""))          # zone change → portal whoosh + music crossfade
	if map != _last_map:
		if _last_map != "":
			AudioManager.play_sfx("portal")
		_last_map = map
		AudioManager.play_music(map)
	var lpf = _find_fighter(_player_id)           # level-up fanfare
	if lpf != null:
		var lvl := int(lpf.get("level", 1))
		if _last_level > 0 and lvl > _last_level:
			AudioManager.play_sfx("level_up")
		_last_level = lvl
	_handle_events()             # spawn damage-number / hit FX from this snapshot's events

func assign_fighter(fid: String) -> void:
	_player_id = fid
	print("[netclient] assigned fighter ", fid)

# spawn render nodes for new fighters, free nodes for ones that left, revive on respawn
func _sync_nodes_to_state() -> void:
	var present := {}
	for f in _state["fighters"]:
		present[f["id"]] = true
		_absent.erase(f["id"])                  # back in interest range
		if not _nodes.has(f["id"]):
			_spawn(f)
		else:
			var n = _nodes[f["id"]]
			n["holder"].visible = true          # unhide if it was hidden during the despawn grace
			if f["alive"] and n["died"]:        # server respawned it → reset the death pose
				n["died"] = false
				n["busy"] = ""
				n["ui"].visible = true
				n["holder"].position = _world(f)   # snap to spawn (don't slide from the death spot)
				n["last"] = n["holder"].position
				n["vel"] = Vector2.ZERO
				if n["anim"] != null:
					_safe_play(n["anim"], n["anims"].get("idle", "idle"))
	# entities out of interest range: hide now, but keep the model around briefly so boundary
	# jitter doesn't re-instantiate the GLB on every crossing.
	var dt := get_process_delta_time()
	for id in _nodes.keys():
		if not present.has(id):
			var n = _nodes[id]
			n["holder"].visible = false
			_absent[id] = float(_absent.get(id, 0.0)) + dt
			if _absent[id] >= DESPAWN_GRACE:
				if is_instance_valid(n["holder"]):
					n["holder"].queue_free()
				_nodes.erase(id)
				_absent.erase(id)

# Enter opens/sends chat, Esc cancels; camera/zoom otherwise (class-cycle/reset are server-side)
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		if (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and not _chatting:
			_open_chat()
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_ESCAPE:
			if _chatting:
				_close_chat()
				get_viewport().set_input_as_handled()
				return
			elif _inv_panel.visible:
				_inv_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _quest_panel != null and _quest_panel.visible:
				_quest_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _qgiver_panel != null and _qgiver_panel.visible:
				_qgiver_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _settings_panel != null and _settings_panel.visible:
				_settings_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _sell_confirm != null:
				_close_sell_confirm()
				get_viewport().set_input_as_handled()
				return
			elif _shop_panel != null and _shop_panel.visible:
				_shop_panel.visible = false
				_close_sell_confirm()
				get_viewport().set_input_as_handled()
				return
			elif _invite_prompt != null or _invite_popup != null:
				_close_invite_prompt()
				if _invite_popup != null:
					_invite_popup.queue_free()
					_invite_popup = null
				get_viewport().set_input_as_handled()
				return
			elif _friend_id != "":             # clear the ally target
				_friend_id = ""
				get_viewport().set_input_as_handled()
				return
			elif _focus_id != "":              # clear the tab-target
				_focus_id = ""
				get_viewport().set_input_as_handled()
				return
		elif e.keycode == KEY_I and not _chatting:
			_toggle_inventory()
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_J and not _chatting:
			_toggle_questlog()
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_TAB and not _chatting:
			if e.ctrl_pressed:
				_cycle_friend()             # Ctrl+Tab: cycle the ally heal/buff target
			else:
				_cycle_focus()              # Tab: cycle the enemy target
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_F1 and _is_admin and _admin_panel != null:
			_admin_panel.visible = not _admin_panel.visible
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_B and not _chatting and (_near_shop or (_shop_panel != null and _shop_panel.visible)):
			_toggle_shop()                  # open/close the shop while on the home pad
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_E and not _chatting and (_near_qgiver or (_qgiver_panel != null and _qgiver_panel.visible)):
			_toggle_qgiver()                # talk to the quest giver while near it
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_O and not _chatting:
			_toggle_settings()              # audio / options
			get_viewport().set_input_as_handled()
			return
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_RIGHT:
			if e.pressed:
				_dragging = true
				_rmb_moved = false
			else:
				_dragging = false
				if not _rmb_moved and not _chatting:
					_try_invite_click()             # a right-CLICK (no drag) on a player → invite popup
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_dist = clampf(_dist / ZOOM_STEP, DIST_MIN, DIST_MAX)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_dist = clampf(_dist * ZOOM_STEP, DIST_MIN, DIST_MAX)
	elif e is InputEventMouseMotion and _dragging:
		if e.relative.length() > 2.0:               # any real drag = camera, not an invite click
			_rmb_moved = true
		_yaw -= e.relative.x * ORBIT_SENS
		_pitch = clampf(_pitch + e.relative.y * ORBIT_SENS, PITCH_MIN, PITCH_MAX)

func _update_hud() -> void:
	if _net_msg != "":
		_info.text = "[b]Legends MMO — Online[/b]\n[color=#ff7a7a]%s[/color]" % _net_msg
		_bar.text = ""
		return
	if _player_id == "" or _player == null or _state.is_empty():
		_info.text = "[b]Legends MMO — Online[/b]\n[color=#7f93a8]connecting…[/color]"
		_bar.text = ""
		return
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	var c: Dictionary = GameData.CLASSES[pf["classId"]]
	var alive_txt := "[color=#ff6b6b](respawning…)[/color]" if not pf["alive"] else ""
	var lvl := int(pf.get("level", 1))
	var xp := int(pf.get("xp", 0))
	var xpn := int(pf.get("xpNext", 100))
	var zone := _zone_name(str(_state.get("map", "")))
	var zone_chip := ("[color=#ff6b6b][b]⚔ %s · PvP[/b][/color]" % zone) if bool(_state.get("pvp", false)) else ("[color=#8ad6ff]◗ %s[/color]" % zone)
	_info.text = "[b]%s[/b]  [color=#9fb4c8]%s · %s[/color]   [color=#ffd24d][b]Lvl %d[/b][/color]  HP %d/%d %s   [color=#9fe8a0]XP %d/%d[/color]   [color=#ffd24d]◈ %d[/color]   %s   [color=#7fd4ff]ONLINE[/color]\n[color=#7f93a8]WASD · 1-8 abilities · LMB basic · RMB camera ([b]right-click a player[/b] = invite) · [b]Tab[/b] enemy · [b]Ctrl+Tab[/b]/frame = ally · [b]I[/b] bag · [b]J[/b] journal · [b]O[/b] options[/color]" % [
		c["name"], c["sport"], c["role"], lvl, int(round(pf["hp"])), int(pf["maxHP"]), alive_txt, xp, xpn, int(pf.get("credits", 0)), zone_chip]
	_bar.text = ""
	_update_hotbar(pf)                           # the visual skill bar (shared with local mode)

func _zone_name(map: String) -> String:
	match map:
		"home": return "Home Base"
		"combat": return "Combat Zone"
		"frontier": return "Frontier"
		"arena": return "Arena"
		_: return map.capitalize() if map != "" else "—"
