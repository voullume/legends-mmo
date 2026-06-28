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
const RARITY_COLORS := {"common": "#cfd6df", "uncommon": "#7fe08a", "rare": "#5aa0ff", "epic": "#c77dff", "legendary": "#ff8c1a", "mythic": "#ff4d6d"}
const RARITY_ORDER := ["common", "uncommon", "rare", "epic", "legendary", "mythic"]   # low → high tier
const RARITY_RANK := {"common": 0, "uncommon": 1, "rare": 2, "epic": 3, "legendary": 4, "mythic": 5}
const SELL_BATCH_MAX := 50                                                   # one bulk sell ≤ this (server caps too)
const STAT_KEYS := ["PWR", "PRE", "SPD", "END", "INS", "CLU"]                 # 6 stats, stable display order
const STAT_NAMES := {"PWR": "Power", "PRE": "Precision", "SPD": "Speed", "END": "Endurance", "INS": "Insight", "CLU": "Clutch"}
# P7 paperdoll: the 11 equip slots [item-slot, label, copy-index] (ring appears twice — cap 2)
const PAPERDOLL_SLOTS := [["head", "Head", 0], ["chest", "Chest", 0], ["legs", "Legs", 0], ["hands", "Hands", 0],
	["feet", "Feet", 0], ["main_hand", "Main Hand", 0], ["off_hand", "Off Hand", 0], ["neck", "Neck", 0],
	["ring", "Ring 1", 0], ["ring", "Ring 2", 1], ["trinket", "Trinket", 0]]
# P4 forge — these MUST mirror the server (Server.gd RARITIES mult, SALVAGE_YIELD, upgrade cost formula, MAX_UPGRADE)
const RARITY_MULT := {"common": 1, "uncommon": 2, "rare": 4, "epic": 8, "legendary": 14, "mythic": 20}
const SALVAGE_YIELD := {"common": 1, "uncommon": 2, "rare": 5, "epic": 12, "legendary": 30, "mythic": 75}
const MAX_UPGRADE := 10
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
var _sheet_panel: Control                    # character sheet (K) — computed base+gear stats + item power
var _sheet_label: RichTextLabel
var _inv_items := []                          # last-loaded inventory cache (for hover tooltips)
var _inv_grid: GridContainer                  # P7: the item-tile grid
var _inv_paperdoll: GridContainer             # P7: the equipped-slots paperdoll
var _inv_status: Label                        # P7: "N items" / loading / empty
var _inv_ctx: PopupMenu                       # P7: right-click context menu
var _inv_ctx_item := ""                       # the item id the context menu is acting on
var _chat_grace := 0          # frames after closing chat where input stays suppressed
var _inv_loading := false     # an inventory GET is in flight
var _inv_pending := false     # a refresh was requested while loading
var _shop_panel: Control = null
var _shop_buy_status: Label = null            # BUY header + credit balance
var _shop_buy_grid: GridContainer = null      # BUY catalog tiles
var _shop_roll_row: HBoxContainer = null      # random-roll buttons
var _shop_sell_status: Label = null           # SELL/SALVAGE header + balance
var _shop_sell_controls: VBoxContainer = null # mode / select-all / sort / filter rows
var _shop_sell_grid: GridContainer = null     # SELL item tiles
var _shop_sell_footer: HBoxContainer = null   # Sell-selected + clear
var _shop_info := {}          # catalog + roll/sell prices (from recv_shop_info)
var _shop_root: Node3D = null # the 3D shop pad visual
var _shop_sig := ""
var _shop_hint: Label = null  # "Press B to shop" proximity prompt
var _near_shop := false
var _forge_root: Node3D = null   # the 3D forge pad visual (P4)
var _forge_sig := ""
var _forge_hint: Label = null
var _near_forge := false
var _forge_panel: Control
var _forge_status: Label = null               # scrap + credits + hint
var _forge_grid: GridContainer = null         # upgrade/reforge item tiles
var _forge_craft_grid: GridContainer = null   # craft recipe tiles
var _sell_salvage := false    # sell panel mode: false = sell for credits, true = salvage for scrap
var _forge_items := []        # last-loaded inventory cache for the forge panel
var _forge_loading := false   # re-entrancy guard for the forge load (mirrors _inv_loading)
var _forge_pending := false
var _shop_sell_cache := {}    # item_id -> {name, rarity, price} for the sell confirmation
var _sell_confirm: Panel = null
var _sell_items := []         # last-loaded inventory (Array[Dictionary]) — re-render toggles without re-fetch
var _sell_selection := {}     # item_id -> true, the multi-select set in the SELL list
var _sell_sort := "rarity"    # rarity | slot | power
var _sell_filter_slot := ""   # "" = all slots, else one of the 10 item-type slots (head…trinket)
var _sell_loading := false    # re-entrancy guard for the SELL list load (mirrors _inv_loading)
var _sell_pending := false    # a reload was requested while one was in flight
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
	_build_charsheet()
	_build_forge()
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

# an item's stat block: primary (falling back to legacy bonus_* for pre-P2/quest items) + each affix.
# Shared by the inventory, shop-buy and sell views so one item always reads the same everywhere.
func _item_stats_str(it: Dictionary) -> String:
	var psv = it.get("primary_stat")                          # coerce JSON null → "" (str(null) is "<null>")
	var ps: String = "" if psv == null else str(psv)
	var pa: int = int(it.get("primary_amt", 0))
	if ps == "":
		var bsv = it.get("bonus_stat")
		ps = "" if bsv == null else str(bsv)
	if pa == 0:
		pa = int(it.get("bonus_amt", 0))
	var parts := []
	if ps != "" and pa != 0:
		parts.append("[color=#9fe8a0]+%d %s[/color]" % [pa, ps])
	var affs = it.get("affixes", [])
	if affs is Array:
		for a in affs:
			if typeof(a) == TYPE_DICTIONARY:
				parts.append("[color=#7fb0e8]+%d %s[/color]" % [int(a.get("amt", 0)), str(a.get("stat", ""))])
	return "  ".join(parts)

# compact "iLvl · power" tag for an item
func _item_meta_str(it: Dictionary) -> String:
	return "[color=#7f8a99]i%d · ✦%d[/color]" % [int(it.get("ilvl", 1)), int(it.get("item_power", 0))]

func _build_inventory() -> void:
	_inv_panel = CenterContainer.new()
	_inv_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_inv_panel.visible = false
	_hud.add_child(_inv_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(760, 0)
	_inv_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	var t := Label.new()
	t.text = "Inventory   (I to close)"
	t.add_theme_font_size_override("font_size", 22)
	head.add_child(t)
	_inv_status = Label.new()
	_inv_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_inv_status.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	head.add_child(_inv_status)
	vb.add_child(head)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	vb.add_child(body)
	# paperdoll (equipped slots) — left
	var pd_box := VBoxContainer.new()
	var pd_t := Label.new()
	pd_t.text = "Equipped"
	pd_t.add_theme_color_override("font_color", Color(0.62, 0.7, 0.78))
	pd_box.add_child(pd_t)
	_inv_paperdoll = GridContainer.new()
	_inv_paperdoll.columns = 1
	_inv_paperdoll.add_theme_constant_override("v_separation", 4)
	pd_box.add_child(_inv_paperdoll)
	body.add_child(pd_box)
	# item grid (scrollable) — right
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(456, 430)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(sc)
	_inv_grid = GridContainer.new()
	_inv_grid.columns = 3
	_inv_grid.add_theme_constant_override("h_separation", 6)
	_inv_grid.add_theme_constant_override("v_separation", 6)
	sc.add_child(_inv_grid)
	# right-click context menu (lock / equip)
	_inv_ctx = PopupMenu.new()
	_inv_ctx.id_pressed.connect(_on_inv_ctx)
	_inv_ctx.popup_hide.connect(func() -> void:    # menu dismissed (incl. ESC/click-away) → drop the tooltip
		if _tooltip != null: _tooltip.visible = false)
	_hud.add_child(_inv_ctx)

# --- character sheet (K): computed base+gear attributes + applied combat finals + item power (P3) ---
func _build_charsheet() -> void:
	_sheet_panel = CenterContainer.new()
	_sheet_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sheet_panel.visible = false
	_hud.add_child(_sheet_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(440, 0)
	_sheet_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Character   (K to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	_sheet_label = RichTextLabel.new()
	_sheet_label.bbcode_enabled = true
	_sheet_label.scroll_active = true
	_sheet_label.custom_minimum_size = Vector2(400, 380)
	vb.add_child(_sheet_label)

func _toggle_charsheet() -> void:
	if _sheet_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_sheet_panel.visible = not _sheet_panel.visible
	if _sheet_panel.visible:
		if _inv_panel != null: _inv_panel.visible = false      # one full-screen modal at a time
		if _quest_panel != null: _quest_panel.visible = false
		_render_charsheet()

# render from the server's per-player `self` block (applied, capped, post-FORMAT_MODS — never raw item amts)
func _render_charsheet() -> void:
	if _sheet_label == null:
		return
	var si: Dictionary = _state.get("self", {})
	var pf = _find_fighter(_player_id)
	var cls_id: String = str(si.get("classId", "")) if si.has("classId") else (str(pf.get("classId", "")) if pf != null else "")
	if cls_id == "" or not GameData.CLASSES.has(cls_id):
		_sheet_label.text = "[color=#7f93a8]loading…[/color]"
		return
	var base: Dictionary = GameData.CLASSES[cls_id]["stats"]
	var bonus: Dictionary = si.get("equip_bonus", {})
	var fin: Dictionary = si if not si.is_empty() else (pf if pf != null else {})
	var lines := ["[color=#7f93a8]Level %d[/color]    [color=#ffd24d]✦ Item Power %d[/color]\n" % [int(si.get("level", 0)), int(si.get("item_power", 0))]]
	lines.append("[b]Attributes[/b]  [color=#7f93a8](base [color=#9fe8a0]+gear[/color])[/color]")
	for st in STAT_KEYS:
		var b: int = int(base.get(st, 0))
		var g: int = int(bonus.get(st, 0))
		var gtxt: String = "  [color=#9fe8a0]+%d[/color]" % g if g > 0 else ""
		lines.append("  [color=#8a93a0]%s[/color]  [color=#cfd6df]%d[/color]%s" % [str(STAT_NAMES.get(st, st)), b + g, gtxt])
	lines.append("\n[b]Combat[/b]")
	lines.append("  Max HP  [color=#cfd6df]%d[/color]" % int(fin.get("maxHP", 0)))
	lines.append("  Damage  [color=#cfd6df]+%d%%[/color]" % int(round((float(fin.get("dmgMult", 1.0)) - 1.0) * 100.0)))
	lines.append("  Crit  [color=#cfd6df]%d%%[/color] [color=#7f93a8]×%.2f[/color]" % [int(round(float(fin.get("crit", 0.0)) * 100.0)), float(fin.get("critMult", 1.6))])
	lines.append("  Move Speed  [color=#cfd6df]%d[/color]" % int(round(float(fin.get("ms", 0.0)))))
	lines.append("  Cooldown Reduction  [color=#cfd6df]%d%%[/color]" % int(round(float(fin.get("cdr", 0.0)) * 100.0)))
	lines.append("  Clutch (low HP)  [color=#cfd6df]+%d%% dmg[/color] · [color=#cfd6df]%d%% DR[/color]" % [int(round(float(fin.get("clutchDmg", 0.0)) * 100.0)), int(round(float(fin.get("clutchDR", 0.0)) * 100.0))])
	# active set bonuses (P5) — from equipped EPIC+ pieces, stacking above the 60 cap
	var sets: Dictionary = si.get("set_bonus", {})
	var active := []
	for sid in sets:
		var sb: Dictionary = sets[sid]
		if int(sb.get("bonus", 0)) > 0:
			var sdef: Dictionary = GameData.SET_DEFS.get(sid, {})
			active.append("  [color=#cdbcff]%s[/color] (%d pc) [color=#9fe8a0]+%d %s[/color]" % [
				str(sdef.get("name", sid)), int(sb.get("count", 0)), int(sb["bonus"]), str(sb.get("stat", ""))])
	if not active.is_empty():
		lines.append("\n[b]Set Bonuses[/b]  [color=#7f93a8](epic+ pieces)[/color]")
		lines.append_array(active)
	# procs from equipped uniques (P6)
	var myprocs = si.get("procs", [])
	if myprocs is Array and not myprocs.is_empty():
		lines.append("\n[b]Procs[/b]  [color=#7f93a8](from uniques)[/color]")
		for pr in myprocs:
			var nm: String = str(GameData.PROC_CATALOG.get(str(pr.get("id", "")), {}).get("name", str(pr.get("id", ""))))
			var trig: String = str(pr.get("trigger", "")).replace("on_", "on ")
			var amt: float = float(pr.get("amt", 0.0))
			var desc := ""
			match str(pr.get("effect", "")):
				"DOT": desc = "%d dmg/s for %.0fs" % [int(round(amt)), float(pr.get("dur", 3.0))]
				"FLAT": desc = "+%d burst" % int(round(amt))
				"LIFESTEAL": desc = "heal %d%% of dmg" % int(round(amt * 100.0))
			lines.append("  [color=#ffb454]✦ %s[/color] [color=#7f93a8](%s)[/color] %s" % [nm, trig, desc])
	_sheet_label.text = "\n".join(lines)

func _show_item_tooltip(it, owned: Array) -> void:
	if it == null or _tooltip == null:
		if _tooltip != null: _tooltip.visible = false
		return
	_tt_label.text = _item_tooltip_text(it, owned)
	_tooltip.visible = true
	_tooltip.reset_size()
	var mp: Vector2 = _hud.get_viewport().get_mouse_position()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	var pos := Vector2(mp.x + 16.0, mp.y + 16.0)
	pos.x = clampf(pos.x, 8.0, max(8.0, vp.x - _tooltip.size.x - 8.0))   # keep on-screen
	pos.y = clampf(pos.y, 8.0, max(8.0, vp.y - _tooltip.size.y - 8.0))
	_tooltip.position = pos

func _item_tooltip_text(it: Dictionary, owned: Array) -> String:
	var rar: String = str(it.get("rarity", "common"))
	var uidv = it.get("unique_id")
	var uid: String = "" if uidv == null else str(uidv)
	var col: String = "#ff9d3c" if uid != "" else RARITY_COLORS.get(rar, "#cfd6df")   # uniques: gold
	var slot: String = str(it.get("slot", ""))
	var L := ["[color=%s][b]%s[/b][/color]%s" % [col, _esc(str(it.get("name", "?"))), ("  [color=#ff9d3c]UNIQUE[/color]" if uid != "" else "")]]
	L.append("[color=#7f8a99]%s · %s · i%d · ✦%d[/color]" % [rar, slot, int(it.get("ilvl", 1)), int(it.get("item_power", 0))])
	var sid := str(it.get("set_id", ""))
	if sid != "":
		L.append("[color=#cdbcff]%s set[/color]" % str(GameData.SET_DEFS.get(sid, {}).get("name", sid)))
	var pidv = it.get("proc_id")                                    # P6: proc description
	var pid: String = "" if pidv == null else str(pidv)
	if pid != "":
		L.append("[color=#ffb454]✦ %s[/color]" % _proc_desc(pid, int(it.get("proc_tier", 0))))
	var stats := _item_stats_str(it)
	if stats != "":
		L.append(stats)
	var cmp = _replace_candidate(it, owned, slot)
	if cmp != null:
		L.append("[color=#7f93a8]vs equipped %s:[/color]" % _esc(str(cmp.get("name", "?"))))
		var d := _stat_delta(it, cmp)
		if d.is_empty():
			L.append("  [color=#7f93a8](no stat change)[/color]")
		else:
			for st in STAT_KEYS:                            # stable order
				if d.has(st):
					var v: int = int(d[st])
					if v > 0:
						L.append("  [color=#9fe8a0]▲ +%d %s[/color]" % [v, st])
					else:
						L.append("  [color=#ff8a8a]▼ %d %s[/color]" % [v, st])
	elif _equipped_count(owned, slot) < (2 if slot == "ring" else 1):
		L.append("[color=#9fe8a0](fills an empty %s slot)[/color]" % slot)
	return "\n".join(L)

func _item_stat_totals(it: Dictionary) -> Dictionary:        # raw per-stat from primary + affixes (legacy-safe)
	var t := {}
	var psv = it.get("primary_stat")
	var ps: String = "" if psv == null else str(psv)
	var pa: int = int(it.get("primary_amt", 0))
	if ps == "":
		var bsv = it.get("bonus_stat")
		ps = "" if bsv == null else str(bsv)
	if pa == 0:
		pa = int(it.get("bonus_amt", 0))
	if ps != "":
		t[ps] = int(t.get(ps, 0)) + pa
	var affs = it.get("affixes", [])
	if affs is Array:
		for a in affs:
			if typeof(a) == TYPE_DICTIONARY:
				var s := str(a.get("stat", ""))
				if s != "":
					t[s] = int(t.get(s, 0)) + int(a.get("amt", 0))
	return t

func _stat_delta(a: Dictionary, b: Dictionary) -> Dictionary:
	var ta := _item_stat_totals(a)
	var tb := _item_stat_totals(b)
	var keys := {}
	for k in ta: keys[k] = true
	for k in tb: keys[k] = true
	var d := {}
	for k in keys:
		var diff: int = int(ta.get(k, 0)) - int(tb.get(k, 0))
		if diff != 0:
			d[k] = diff
	return d

func _equipped_count(owned: Array, slot: String) -> int:
	var n := 0
	for it in owned:
		if bool(it.get("equipped", false)) and str(it.get("slot", "")) == slot:
			n += 1
	return n

func _replace_candidate(it: Dictionary, owned: Array, slot: String):
	# the equipped item you'd replace in this slot: at capacity → the lowest-item_power equipped; else null
	var cap := 2 if slot == "ring" else 1
	var eq := []
	for o in owned:
		if bool(o.get("equipped", false)) and str(o.get("slot", "")) == slot and str(o.get("id", "")) != str(it.get("id", "")):
			eq.append(o)
	if eq.size() < cap:
		return null
	eq.sort_custom(func(x, y): return int(x.get("item_power", 0)) < int(y.get("item_power", 0)))
	return eq[0]

func _toggle_inventory() -> void:
	if _tooltip != null: _tooltip.visible = false     # a hover tooltip won't get meta_hover_ended if its label hides
	_inv_panel.visible = not _inv_panel.visible
	if _inv_panel.visible:
		if _quest_panel != null:                     # only one full-screen modal at a time
			_quest_panel.visible = false
		_load_inventory()

func _load_inventory() -> void:
	if supa == null or _inv_grid == null:
		return
	if _inv_loading:                         # coalesce concurrent loads → always show the latest result
		_inv_pending = true
		return
	_inv_loading = true
	_inv_status.text = "loading…"
	var r = await supa.get_inventory()
	_inv_loading = false
	if _inv_pending:
		_inv_pending = false
		_load_inventory()
		return
	if _inv_grid == null:                         # panel torn down mid-await
		return
	if _tooltip != null:                          # a hovered tile about to be freed won't fire mouse_exited
		_tooltip.visible = false
	for ch in _inv_grid.get_children():           # clear the old tiles either way
		ch.queue_free()
	if not r.get("ok"):
		_inv_status.text = "couldn't load inventory"
		_rebuild_paperdoll([])
		return
	var items: Array = r.get("items", [])
	_inv_items = items                            # cache for hover comparison tooltips
	_rebuild_paperdoll(items)
	if items.is_empty():
		_inv_status.text = "empty — kill mobs to find loot"
		return
	_inv_status.text = "%d items · click to equip · right-click to lock" % items.size()
	var view: Array = items.duplicate()           # equipped first, then rarity desc, then name
	view.sort_custom(_inv_sort)
	for it in view:
		_inv_grid.add_child(_inv_tile(it))

func _inv_sort(a, b) -> bool:
	var ae := 1 if bool(a.get("equipped", false)) else 0
	var be := 1 if bool(b.get("equipped", false)) else 0
	if ae != be:
		return ae > be
	var ra := int(RARITY_RANK.get(str(a.get("rarity", "")), 0))
	var rb := int(RARITY_RANK.get(str(b.get("rarity", "")), 0))
	if ra != rb:
		return ra > rb
	return str(a.get("name", "")) < str(b.get("name", ""))

func _item_color(it: Dictionary) -> Color:
	var uv = it.get("unique_id")
	if uv != null and str(uv) != "":
		return Color.html("#ff9d3c")                  # uniques: gold
	return Color.html(RARITY_COLORS.get(str(it.get("rarity", "common")), "#cfd6df"))

func _item_color_hex(it: Dictionary) -> String:    # the same color as a "#rrggbb" string for bbcode
	var uv = it.get("unique_id")
	if uv != null and str(uv) != "":
		return "#ff9d3c"
	return RARITY_COLORS.get(str(it.get("rarity", "common")), "#cfd6df")

# a plain message shown in place of tiles (empty list / hint)
func _hint_tile(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	return l

# rarity-bordered tile background (shared by the shop + forge grids)
func _rarity_box(border: Color, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.17, 0.20, 0.25, 0.96) if hover else Color(0.10, 0.12, 0.16, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = border
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(7)
	return sb

# a reusable grid tile: rarity-bordered panel + a bbcode header (full info), optional action row (real
# Buttons), hover→compare tooltip, and optional left/right-click callbacks on the panel body itself.
func _grid_tile(border: Color, header_bb: String, tip_item, owned: Array, extra: Control = null, on_left = null, on_right = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(224, 0)
	var sb := _rarity_box(border, false)
	var sbh := _rarity_box(border, true)
	p.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE     # clicks fall through to the panel (action Buttons still capture)
	p.add_child(vb)
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.custom_minimum_size = Vector2(208, 0)
	rtl.text = header_bb
	vb.add_child(rtl)
	if extra != null:
		vb.add_child(extra)
	p.mouse_entered.connect(func() -> void:
		p.add_theme_stylebox_override("panel", sbh)
		if tip_item != null: _show_item_tooltip(tip_item, owned))
	p.mouse_exited.connect(func() -> void:
		p.add_theme_stylebox_override("panel", sb)
		if _tooltip != null: _tooltip.visible = false)
	if on_left is Callable or on_right is Callable:
		var press := {"pos": Vector2.ZERO, "btn": 0}   # fire on release WITHOUT drag → a scroll-drag can't buy
		p.gui_input.connect(func(ev) -> void:
			if ev is InputEventMouseButton:
				if ev.pressed:
					press["pos"] = ev.position
					press["btn"] = ev.button_index
				elif ev.button_index == press["btn"] and ev.position.distance_to(press["pos"]) < 6.0:
					if ev.button_index == MOUSE_BUTTON_LEFT and on_left is Callable and (on_left as Callable).is_valid():
						(on_left as Callable).call()
					elif ev.button_index == MOUSE_BUTTON_RIGHT and on_right is Callable and (on_right as Callable).is_valid():
						(on_right as Callable).call())
	return p

# a small action Button for tiles (Forge upgrade/reforge/craft, etc.) — colored, optionally disabled
func _tile_btn(label: String, fg: Color, enabled: bool, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.disabled = not enabled
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.2))
	if enabled and on_press.is_valid():
		b.pressed.connect(on_press)
	return b

# a small toggle/control button (shop sell: mode / sort / filter / per-rarity) — caller picks the color
func _ctrl_btn(label: String, fg: Color, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.2))
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b

func _ctrl_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	return l

# one item tile: a rarity-bordered button. Left-click equips/unequips, hover shows the compare tooltip,
# right-click opens the context menu. Full stats live in the tooltip (tiles stay compact).
func _inv_tile(it: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(144, 44)
	b.clip_text = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var col := _item_color(it)
	var prefix := ""
	if bool(it.get("equipped", false)):
		prefix += "★ "
	if bool(it.get("locked", false)):
		prefix += "🔒 "
	b.text = prefix + str(it.get("name", "?"))
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", col.lightened(0.2))
	b.add_theme_color_override("font_pressed_color", col)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.16, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(7)
	b.add_theme_stylebox_override("normal", sb)
	var sbh: StyleBoxFlat = sb.duplicate()
	sbh.bg_color = Color(0.17, 0.20, 0.25, 0.96)
	b.add_theme_stylebox_override("hover", sbh)
	b.add_theme_stylebox_override("pressed", sbh)
	b.add_theme_stylebox_override("focus", sbh)
	var iid := str(it.get("id", ""))
	var slot := str(it.get("slot", ""))
	var itc: Dictionary = it
	b.pressed.connect(func() -> void:
		if net != null and _connected:
			net.equip.rpc_id(1, iid, slot))
	b.mouse_entered.connect(func() -> void: _show_item_tooltip(itc, _inv_items))
	b.mouse_exited.connect(func() -> void:
		if _tooltip != null: _tooltip.visible = false)
	b.gui_input.connect(func(ev) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			_open_inv_ctx(itc))
	return b

# the equipped-slots column (ring appears twice — cap 2). Each filled slot unequips on click.
func _rebuild_paperdoll(items: Array) -> void:
	if _inv_paperdoll == null:
		return
	for ch in _inv_paperdoll.get_children():
		ch.queue_free()
	var by_slot := {}
	for it in items:
		if bool(it.get("equipped", false)):
			var sl := str(it.get("slot", ""))
			if not by_slot.has(sl):
				by_slot[sl] = []
			by_slot[sl].append(it)
	for entry in PAPERDOLL_SLOTS:
		var sl: String = entry[0]
		var label: String = entry[1]
		var idx: int = entry[2]
		var eqs: Array = by_slot.get(sl, [])
		var it = eqs[idx] if idx < eqs.size() else null
		_inv_paperdoll.add_child(_paperdoll_slot(label, it))

func _paperdoll_slot(label: String, it) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(190, 28)
	b.clip_text = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if it == null:
		b.text = "%s:  —" % label
		b.disabled = true
		b.add_theme_color_override("font_disabled_color", Color(0.38, 0.43, 0.49))
		return b
	b.text = "%s:  %s" % [label, str(it.get("name", "?"))]
	b.add_theme_color_override("font_color", _item_color(it))
	var iid := str(it.get("id", ""))
	var slot := str(it.get("slot", ""))
	var itc: Dictionary = it
	b.pressed.connect(func() -> void:
		if net != null and _connected:
			net.equip.rpc_id(1, iid, slot))         # click an equipped slot → unequip
	b.mouse_entered.connect(func() -> void: _show_item_tooltip(itc, _inv_items))
	b.mouse_exited.connect(func() -> void:
		if _tooltip != null: _tooltip.visible = false)
	return b

func _open_inv_ctx(it: Dictionary) -> void:
	if _inv_ctx == null:
		return
	if _tooltip != null: _tooltip.visible = false   # the popup steals focus → tile won't get mouse_exited
	_inv_ctx_item = str(it.get("id", ""))
	var locked := bool(it.get("locked", false))
	_inv_ctx.set_meta("slot", str(it.get("slot", "")))
	_inv_ctx.set_meta("locked", locked)
	_inv_ctx.clear()
	_inv_ctx.add_item("Unequip" if bool(it.get("equipped", false)) else "Equip", 2)
	_inv_ctx.add_item("Unlock" if locked else "Lock", 1)
	var mp: Vector2 = _hud.get_viewport().get_mouse_position()
	_inv_ctx.reset_size()
	_inv_ctx.position = Vector2i(int(mp.x), int(mp.y))
	_inv_ctx.popup()

func _on_inv_ctx(id: int) -> void:
	if net == null or not _connected or _inv_ctx_item == "":
		return
	match id:
		1:  # lock / unlock
			net.inv_set_locked.rpc_id(1, _inv_ctx_item, not bool(_inv_ctx.get_meta("locked", false)))
		2:  # equip / unequip
			net.equip.rpc_id(1, _inv_ctx_item, str(_inv_ctx.get_meta("slot", "")))

func recv_inventory_changed() -> void:
	if _inv_panel != null and _inv_panel.visible:
		_load_inventory()
	if _shop_panel != null and _shop_panel.visible:   # a buy/sell/roll/lock changed our items + credits
		_render_shop_buy()
		_load_shop_sell()
	if _forge_panel != null and _forge_panel.visible: # an upgrade/salvage changed items, level, scrap
		_load_forge()

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
	if _tooltip != null: _tooltip.visible = false     # closing the inventory under the cursor won't fire mouse_exited
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
	if _tooltip != null: _tooltip.visible = false     # ditto — clear any stuck inventory hover tooltip
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
	pc.custom_minimum_size = Vector2(1010, 0)
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
	hb.add_theme_constant_override("separation", 20)
	vb.add_child(hb)
	# --- BUY column: catalog grid + random-roll buttons ---
	var buycol := VBoxContainer.new()
	buycol.add_theme_constant_override("separation", 6)
	hb.add_child(buycol)
	_shop_buy_status = Label.new()
	_shop_buy_status.text = "BUY"
	_shop_buy_status.add_theme_font_size_override("font_size", 16)
	buycol.add_child(_shop_buy_status)
	var buysc := ScrollContainer.new()
	buysc.custom_minimum_size = Vector2(474, 384)
	buysc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	buycol.add_child(buysc)
	_shop_buy_grid = GridContainer.new()
	_shop_buy_grid.columns = 2
	_shop_buy_grid.add_theme_constant_override("h_separation", 6)
	_shop_buy_grid.add_theme_constant_override("v_separation", 6)
	buysc.add_child(_shop_buy_grid)
	var rolllbl := Label.new()
	rolllbl.text = "Random roll (random item of that tier):"
	rolllbl.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	buycol.add_child(rolllbl)
	_shop_roll_row = HBoxContainer.new()
	_shop_roll_row.add_theme_constant_override("separation", 6)
	buycol.add_child(_shop_roll_row)
	# --- SELL column: status + control rows + item grid + footer ---
	var sellcol := VBoxContainer.new()
	sellcol.add_theme_constant_override("separation", 6)
	hb.add_child(sellcol)
	_shop_sell_status = Label.new()
	_shop_sell_status.add_theme_font_size_override("font_size", 16)
	sellcol.add_child(_shop_sell_status)
	_shop_sell_controls = VBoxContainer.new()
	_shop_sell_controls.add_theme_constant_override("separation", 3)
	sellcol.add_child(_shop_sell_controls)
	var sellsc := ScrollContainer.new()
	sellsc.custom_minimum_size = Vector2(474, 300)
	sellsc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sellcol.add_child(sellsc)
	_shop_sell_grid = GridContainer.new()
	_shop_sell_grid.columns = 2
	_shop_sell_grid.add_theme_constant_override("h_separation", 6)
	_shop_sell_grid.add_theme_constant_override("v_separation", 6)
	sellsc.add_child(_shop_sell_grid)
	_shop_sell_footer = HBoxContainer.new()
	_shop_sell_footer.add_theme_constant_override("separation", 10)
	sellcol.add_child(_shop_sell_footer)

func _toggle_shop() -> void:
	if _shop_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_shop_panel.visible = not _shop_panel.visible
	if _shop_panel.visible:
		_sell_selection.clear()             # fresh selection each time the shop opens
		_sell_salvage = false               # default to Sell mode on open
		_render_shop_buy()
		_load_shop_sell()
	else:
		_close_sell_confirm()

func _my_credits() -> int:
	var pf = _find_fighter(_player_id)
	return int(pf.get("credits", 0)) if pf != null else 0

func _my_scrap() -> int:
	return int(_state.get("self", {}).get("scrap", 0))

# human-readable description of a proc at a given tier (P6) — from GameData.PROC_CATALOG
func _proc_desc(proc_id: String, tier: int) -> String:
	var p: Dictionary = GameData.PROC_CATALOG.get(proc_id, {})
	if p.is_empty():
		return ""
	var amt: float = GameData.proc_amt(proc_id, tier)
	var trig: String = str(p.get("trigger", "")).replace("on_", "on ")
	var nm: String = str(p.get("name", proc_id))
	match str(p.get("effect", "")):
		"DOT": return "%s (%s): %d dmg/s for %.0fs" % [nm, trig, int(round(amt)), float(p.get("dur", 3.0))]
		"FLAT": return "%s (%s): +%d burst damage" % [nm, trig, int(round(amt))]
		"LIFESTEAL": return "%s (%s): heal %d%% of damage dealt" % [nm, trig, int(round(amt * 100.0))]
		_: return nm

func _upgrade_credit_cost(rarity: String, lvl: int) -> int:   # MUST match Server.gd
	return int(RARITY_MULT.get(rarity, 1)) * 25 * (lvl + 1)

func _upgrade_scrap_cost(rarity: String, lvl: int) -> int:    # MUST match Server.gd
	return int(RARITY_MULT.get(rarity, 1)) * (lvl + 1)

func _reforge_credit_cost(rarity: String, rc: int) -> int:    # MUST match Server.gd
	return int(RARITY_MULT.get(rarity, 1)) * 30 * (rc + 1)

func _reforge_scrap_cost(rarity: String, rc: int) -> int:     # MUST match Server.gd
	return int(RARITY_MULT.get(rarity, 1)) * 2 * (rc + 1)

# --- Forge panel (F at the forge pad): spend credits + scrap to upgrade gear (P4) ---
func _build_forge() -> void:
	_forge_panel = CenterContainer.new()
	_forge_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_forge_panel.visible = false
	_hud.add_child(_forge_panel)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(680, 0)
	_forge_panel.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 20)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	m.add_child(vb)
	var t := Label.new()
	t.text = "Forge   (F to close)"
	t.add_theme_font_size_override("font_size", 22)
	vb.add_child(t)
	_forge_status = Label.new()
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_forge_status.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	vb.add_child(_forge_status)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(636, 360)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(sc)
	_forge_grid = GridContainer.new()
	_forge_grid.columns = 2
	_forge_grid.add_theme_constant_override("h_separation", 6)
	_forge_grid.add_theme_constant_override("v_separation", 6)
	sc.add_child(_forge_grid)
	var ct := Label.new()
	ct.text = "Craft   (spend scrap for a random item)"
	ct.add_theme_color_override("font_color", Color(0.62, 0.7, 0.78))
	vb.add_child(ct)
	_forge_craft_grid = GridContainer.new()
	_forge_craft_grid.columns = 2
	_forge_craft_grid.add_theme_constant_override("h_separation", 6)
	_forge_craft_grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(_forge_craft_grid)

func _toggle_forge() -> void:
	if _forge_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_forge_panel.visible = not _forge_panel.visible
	if _forge_panel.visible:
		if _inv_panel != null: _inv_panel.visible = false      # one full-screen modal at a time
		if _sheet_panel != null: _sheet_panel.visible = false
		if _quest_panel != null: _quest_panel.visible = false
		_load_forge()

func _load_forge() -> void:
	if _forge_grid == null or supa == null:
		return
	if _forge_loading:                           # coalesce overlapping loads → the latest result wins
		_forge_pending = true
		return
	_forge_loading = true
	_forge_status.text = "loading…"
	var r = await supa.get_inventory()
	_forge_loading = false
	if _forge_pending:
		_forge_pending = false
		_load_forge()
		return
	if _forge_grid == null:
		return
	if not r.get("ok"):
		_forge_status.text = "couldn't load inventory"
		return
	_forge_items = r.get("items", [])
	_render_forge()

func _render_forge() -> void:
	if _forge_grid == null:
		return
	if _tooltip != null: _tooltip.visible = false
	for ch in _forge_grid.get_children(): ch.queue_free()
	for ch in _forge_craft_grid.get_children(): ch.queue_free()
	_forge_status.text = "%d scrap   ◈ %d        Upgrade raises an item's stat cap (toward the 60/stat ceiling) + its Item Power." % [_my_scrap(), _my_credits()]
	var view := _forge_items.duplicate()                       # equipped first, then by item power
	view.sort_custom(func(a, b):
		var ae := 1 if bool(a.get("equipped", false)) else 0
		var be := 1 if bool(b.get("equipped", false)) else 0
		if ae != be:
			return ae > be
		return int(a.get("item_power", 0)) > int(b.get("item_power", 0)))
	if view.is_empty():
		_forge_grid.add_child(_hint_tile("no gear to upgrade — find or buy some"))
	for it in view:
		var iid: String = str(it.get("id", ""))
		var rar: String = str(it.get("rarity", "common"))
		var lvl: int = int(it.get("upgrade_level", 0))
		var rc: int = int(it.get("reforge_count", 0))
		var eq: String = " [color=#ffd24d]★[/color]" if bool(it.get("equipped", false)) else ""
		var lvtxt: String = " [color=#c9a36a]+%d[/color]" % lvl if lvl > 0 else ""
		# cost line (kept verbatim from the old text UI: Upgrade →+N cost, Reforge cost)
		var costline := ""
		var can_up := false
		if lvl >= MAX_UPGRADE:
			costline = "[color=#9fe8a0]Upgrade: MAX[/color]"
		else:
			var cc: int = _upgrade_credit_cost(rar, lvl)
			var ucost: int = _upgrade_scrap_cost(rar, lvl)
			can_up = _my_credits() >= cc and _my_scrap() >= ucost
			costline = "[color=%s]Upgrade →+%d: ◈%d +%dsc[/color]" % ["#9fe8a0" if can_up else "#ff8a8a", lvl + 1, cc, ucost]
		var has_rf := int(RARITY_RANK.get(rar, 0)) >= 1          # uncommon+ has affixes to reroll
		var can_rf := false
		if has_rf:
			var rcc: int = _reforge_credit_cost(rar, rc)
			var rsc: int = _reforge_scrap_cost(rar, rc)
			can_rf = _my_credits() >= rcc and _my_scrap() >= rsc
			costline += "    [color=%s]Reforge: ◈%d +%dsc[/color]" % ["#cdbcff" if can_rf else "#ff8a8a", rcc, rsc]
		var header := "[color=%s]%s[/color]%s%s [color=#7f8a99](%s · i%d · ✦%d)[/color]\n%s" % [
			_item_color_hex(it), _esc(str(it.get("name", "?"))), eq, lvtxt,
			str(it.get("slot", "")), int(it.get("ilvl", 1)), int(it.get("item_power", 0)), costline]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.add_child(_tile_btn("Upgrade", Color.html("#ffcf8a"), lvl < MAX_UPGRADE and can_up, func() -> void:
			if net != null and _connected: net.forge_upgrade.rpc_id(1, iid)))
		if has_rf:
			row.add_child(_tile_btn("Reforge", Color.html("#cdbcff"), can_rf, func() -> void:
				if net != null and _connected: net.forge_reforge.rpc_id(1, iid)))
		_forge_grid.add_child(_grid_tile(_item_color(it), header, it, _forge_items, row))
	# Craft recipes (P5): spend scrap → a random item of the recipe's rarity
	for rcp in GameData.RECIPES:
		var scr: int = int(rcp.get("scrap", 0))
		var rr: String = str(rcp.get("rarity", "common"))
		var rcol: Color = Color.html(RARITY_COLORS.get(rr, "#cfd6df"))
		var unique := bool(rcp.get("unique", false))
		var afford := _my_scrap() >= scr
		var rid := str(rcp.get("id", ""))
		var head := "[color=#bfe3ff]%s[/color]\n→ [color=%s]%s[/color]  [color=%s]%d scrap[/color]" % [
			_esc(str(rcp.get("name", "?"))), RARITY_COLORS.get(rr, "#cfd6df"), ("unique" if unique else rr),
			"#9fe8a0" if afford else "#ff8a8a", scr]
		var crow := HBoxContainer.new()
		crow.add_child(_tile_btn("Craft", Color.html("#bfe3ff"), afford, func() -> void:
			if net != null and _connected: net.craft.rpc_id(1, rid)))
		_forge_craft_grid.add_child(_grid_tile(rcol, head, null, [], crow))

func _render_shop_buy() -> void:
	if _shop_buy_grid == null:
		return
	if _tooltip != null: _tooltip.visible = false
	if _shop_buy_status != null:
		_shop_buy_status.text = "BUY    ◈ %d" % _my_credits()
	for ch in _shop_buy_grid.get_children(): ch.queue_free()
	for ch in _shop_roll_row.get_children(): ch.queue_free()
	var cat: Array = _shop_info.get("catalog", [])
	if cat.is_empty():
		_shop_buy_grid.add_child(_hint_tile("catalog unavailable"))
	for e in cat:
		var rr: String = str(e.get("rarity", ""))
		var slot: String = str(e.get("slot", ""))
		var price: int = int(e.get("price", 0))
		var pcol: String = "#ffd24d" if _my_credits() >= price else "#ff8a8a"
		var stats := _item_stats_str(e)
		var header := "[color=%s]%s[/color] [color=#7f8a99](%s · %s)[/color]\n%s%s[color=%s]◈ %d[/color]" % [
			RARITY_COLORS.get(rr, "#cfd6df"), _esc(str(e.get("name", ""))), rr, slot,
			stats, ("   " if stats != "" else ""), pcol, price]
		_shop_buy_grid.add_child(_grid_tile(Color.html(RARITY_COLORS.get(rr, "#cfd6df")), header, e, _sell_items, null,
			func() -> void:
				if net != null and _connected: net.shop_buy.rpc_id(1, slot, rr)))
	var roll: Dictionary = _shop_info.get("roll", {})
	for rar in ["common", "uncommon", "rare", "epic"]:
		if roll.has(rar):
			var rprice: int = int(roll[rar])
			_shop_roll_row.add_child(_tile_btn("Roll %s  ◈%d" % [rar.capitalize(), rprice],
				Color.html(RARITY_COLORS.get(rar, "#cfd6df")), _my_credits() >= rprice,
				func() -> void:
					if net != null and _connected: net.shop_roll.rpc_id(1, rar)))

func _load_shop_sell() -> void:
	if _shop_sell_grid == null or supa == null:
		return
	if _sell_loading:                            # coalesce overlapping loads → always show the latest result
		_sell_pending = true
		return
	_sell_loading = true
	_shop_sell_status.text = "SELL — loading…"
	var r = await supa.get_inventory()
	_sell_loading = false
	if _sell_pending:                            # a reload was requested mid-flight → run once more with fresh data
		_sell_pending = false
		_load_shop_sell()
		return
	if _shop_sell_grid == null:
		return
	if not r.get("ok"):
		_shop_sell_status.text = "SELL — couldn't load inventory"
		return
	_sell_items = r.get("items", [])
	var present := {}                             # drop any selection whose item is gone (sold elsewhere)
	for it in _sell_items:
		present[str(it.get("id", ""))] = true
	for id in _sell_selection.keys():
		if not present.has(id):
			_sell_selection.erase(id)
	_render_shop_sell()
	if _shop_panel != null and _shop_panel.visible:
		_render_shop_buy()                       # refresh BUY hover-compare Δ with the freshly-loaded inventory

# render the SELL list from the cached _sell_items + UI state (selection / sort / filter). Cheap to call
# on every toggle — no network. Selecting is multi-select; equipped (★) and locked items are unselectable.
func _render_shop_sell() -> void:
	if _shop_sell_grid == null:
		return
	if _tooltip != null: _tooltip.visible = false
	var sell: Dictionary = _shop_info.get("sell", {})
	var items: Array = _sell_items
	_shop_sell_cache.clear()                     # value cache the confirm dialog reads back (credits + scrap)
	for it in items:
		var rr0: String = str(it.get("rarity", "common"))
		_shop_sell_cache[str(it.get("id", ""))] = {"name": str(it.get("name", "?")), "rarity": rr0, "price": int(sell.get(rr0, 0)), "scrap": int(SALVAGE_YIELD.get(rr0, 1))}
	_shop_sell_status.text = "%s   %s" % ["SALVAGE" if _sell_salvage else "SELL", ("%d scrap" % _my_scrap()) if _sell_salvage else ("◈ %d" % _my_credits())]
	for ch in _shop_sell_controls.get_children(): ch.queue_free()
	for ch in _shop_sell_grid.get_children(): ch.queue_free()
	for ch in _shop_sell_footer.get_children(): ch.queue_free()
	var dim := Color(0.5, 0.58, 0.66)
	# mode row: Sell (◈ credits) ↔ Salvage (scrap)
	var moderow := HBoxContainer.new()
	moderow.add_theme_constant_override("separation", 8)
	moderow.add_child(_ctrl_label("mode:"))
	moderow.add_child(_ctrl_btn(("● Sell ◈" if not _sell_salvage else "○ Sell ◈"), (Color.html("#bdf5c0") if not _sell_salvage else dim), func() -> void:
		_sell_salvage = false
		_render_shop_sell()))
	moderow.add_child(_ctrl_btn(("● Salvage" if _sell_salvage else "○ Salvage"), (Color.html("#c9a36a") if _sell_salvage else dim), func() -> void:
		_sell_salvage = true
		_render_shop_sell()))
	_shop_sell_controls.add_child(moderow)
	if items.is_empty():
		_shop_sell_grid.add_child(_hint_tile("nothing here — go earn some loot"))
		return
	# tally sellable (unlocked, unequipped) per rarity + find the protected top tier (counts ALL owned)
	var sellable_by_rar := {}
	var top_rank := -1
	var top_rar := ""
	for it in items:
		var rar: String = str(it.get("rarity", "common"))
		var rank: int = int(RARITY_RANK.get(rar, 0))
		if rank > top_rank:
			top_rank = rank
			top_rar = rar
		if bool(it.get("equipped", false)) or bool(it.get("locked", false)):
			continue
		if not sellable_by_rar.has(rar):
			sellable_by_rar[rar] = []
		(sellable_by_rar[rar] as Array).append(str(it.get("id", "")))
	# per-rarity select-all (top tier flagged 🛡 protected → opt in explicitly)
	var selrow := HFlowContainer.new()
	selrow.add_child(_ctrl_label("select:"))
	for rar in RARITY_ORDER:
		if not sellable_by_rar.has(rar):
			continue
		var ids: Array = sellable_by_rar[rar]
		var all_sel := true
		for id in ids:
			if not _sell_selection.has(id):
				all_sel = false
				break
		var rar_l: String = rar
		var prot: String = " 🛡" if rar == top_rar else ""
		selrow.add_child(_ctrl_btn("%s %s%s" % [("✓" if all_sel else "○"), rar.capitalize(), prot], Color.html(RARITY_COLORS.get(rar, "#cfd6df")), func() -> void:
			_toggle_sell_rarity(rar_l)))
	_shop_sell_controls.add_child(selrow)
	if top_rar != "":
		_shop_sell_controls.add_child(_ctrl_label("🛡 your top tier — protected; click to opt in"))
	# sort row (client-side)
	var sortrow := HBoxContainer.new()
	sortrow.add_theme_constant_override("separation", 8)
	sortrow.add_child(_ctrl_label("sort:"))
	for key in ["rarity", "slot", "power"]:
		var k_l: String = key
		sortrow.add_child(_ctrl_btn(key.capitalize(), (Color.html("#ffd24d") if _sell_sort == key else dim), func() -> void:
			_sell_sort = k_l
			_render_shop_sell()))
	_shop_sell_controls.add_child(sortrow)
	# slot-filter row (client-side)
	var slotrow := HFlowContainer.new()
	slotrow.add_child(_ctrl_label("slot:"))
	for sl in ["", "head", "chest", "legs", "hands", "feet", "main_hand", "off_hand", "neck", "ring", "trinket"]:
		var sl_l: String = sl
		var lbl2: String = "All" if sl == "" else sl.capitalize()
		slotrow.add_child(_ctrl_btn(lbl2, (Color.html("#ffd24d") if _sell_filter_slot == sl else dim), func() -> void:
			_sell_filter_slot = sl_l
			_render_shop_sell()))
	_shop_sell_controls.add_child(slotrow)
	# item tiles (filtered + sorted). Left-click selects (no-op if equipped/locked), right-click toggles lock.
	var view := []
	for it in items:
		if _sell_filter_slot != "" and str(it.get("slot", "")) != _sell_filter_slot:
			continue
		view.append(it)
	view.sort_custom(_sell_sort_cmp)
	for it in view:
		var iid: String = str(it.get("id", ""))
		var rar2: String = str(it.get("rarity", "common"))
		var equipped: bool = bool(it.get("equipped", false))
		var locked: bool = bool(it.get("locked", false))
		var selected: bool = _sell_selection.has(iid)
		var price: int = int(sell.get(rar2, 0))
		var val: int = int(SALVAGE_YIELD.get(rar2, 1)) if _sell_salvage else price
		var valtxt: String = ("[color=#c9a36a]%d scrap[/color]" % val) if _sell_salvage else ("[color=#ffd24d]◈%d[/color]" % val)
		var marks: String = ""
		if equipped: marks += "[color=#ffd24d]★[/color] "
		marks += ("[color=#ffb454]🔒[/color] " if locked else "[color=#5a6472]🔓[/color] ")   # lock state, always shown
		if selected: marks += "[color=#9fe8a0]✓[/color] "
		var status: String = ""
		if equipped: status = " [color=#7f93a8](equipped)[/color]"
		elif locked: status = " [color=#7f93a8](locked · right-click to unlock)[/color]"
		var stats := _item_stats_str(it)
		var header := "%s[color=%s]%s[/color]%s\n[color=#7f8a99](%s · ✦%d)[/color]%s — %s" % [
			marks, _item_color_hex(it), _esc(str(it.get("name", "?"))), status,
			str(it.get("slot", "")), int(it.get("item_power", 0)), ("  " + stats if stats != "" else ""), valtxt]
		var border: Color = Color.html("#9fe8a0") if selected else _item_color(it)
		var iid_l: String = iid
		_shop_sell_grid.add_child(_grid_tile(border, header, it, _sell_items, null,
			func() -> void: _toggle_sell_select(iid_l),
			func() -> void: _toggle_item_lock(iid_l)))
	# footer: selected count + total → confirm → shop_sell_many / salvage_many (first SELL_BATCH_MAX only, so
	# the quoted count + total match exactly what will be sold).
	var keys: Array = _sell_selection.keys()
	var n: int = keys.size()
	var sell_n: int = min(n, SELL_BATCH_MAX)
	var total := 0
	for i in sell_n:
		var info = _shop_sell_cache.get(keys[i])
		if info != null:
			total += int(info["scrap"] if _sell_salvage else info["price"])
	if n > 0:
		var verb: String = "Salvage" if _sell_salvage else "Sell"
		var unit: String = ("%d scrap" % total) if _sell_salvage else ("◈%d" % total)
		var btxt: String = ("%s Selected (%d) — %s" % [verb, sell_n, unit]) if n <= SELL_BATCH_MAX else ("%s Selected (%d of %d) — %s" % [verb, sell_n, n, unit])
		_shop_sell_footer.add_child(_ctrl_btn(btxt, (Color.html("#ffcf8a") if _sell_salvage else Color.html("#bdf5c0")), func() -> void:
			_confirm_sell_selected()))
		_shop_sell_footer.add_child(_ctrl_btn("clear", dim, func() -> void:
			_sell_selection.clear()
			_render_shop_sell()))
	else:
		_shop_sell_footer.add_child(_ctrl_label("click an item to select · right-click to lock-protect · pick a rarity to select all"))

func _sell_sort_cmp(a, b) -> bool:
	match _sell_sort:
		"slot":
			var sa := str(a.get("slot", ""))
			var sb := str(b.get("slot", ""))
			if sa != sb:
				return sa < sb
			return int(RARITY_RANK.get(str(a.get("rarity", "")), 0)) > int(RARITY_RANK.get(str(b.get("rarity", "")), 0))
		"power":
			return int(a.get("item_power", 0)) > int(b.get("item_power", 0))
		_:
			var ra := int(RARITY_RANK.get(str(a.get("rarity", "")), 0))
			var rb := int(RARITY_RANK.get(str(b.get("rarity", "")), 0))
			if ra != rb:
				return ra > rb                   # highest rarity first
			return str(a.get("name", "")) < str(b.get("name", ""))

# toggle one item's membership in the sell selection (equipped/locked items can't be selected)
func _toggle_sell_select(item_id: String) -> void:
	for it in _sell_items:
		if str(it.get("id", "")) == item_id:
			if bool(it.get("equipped", false)) or bool(it.get("locked", false)):
				return
			break
	if _sell_selection.has(item_id):
		_sell_selection.erase(item_id)
	else:
		_sell_selection[item_id] = true
	_render_shop_sell()

# per-rarity select-all: if every sellable item of this rarity is already selected, deselect them; else
# select them all. Locked/equipped items are excluded (the top tier is just a rarity you opt into here).
func _toggle_sell_rarity(rarity: String) -> void:
	var ids := []
	for it in _sell_items:
		if str(it.get("rarity", "")) != rarity:
			continue
		if bool(it.get("equipped", false)) or bool(it.get("locked", false)):
			continue
		ids.append(str(it.get("id", "")))
	if ids.is_empty():
		return
	var all_sel := true
	for id in ids:
		if not _sell_selection.has(id):
			all_sel = false
			break
	for id in ids:
		if all_sel:
			_sell_selection.erase(id)
		else:
			_sell_selection[id] = true
	_render_shop_sell()

# flip an item's persistent locked flag (server-side, persisted). Drop it from the selection locally;
# the server's recv_inventory_changed push re-loads the list with the new lock state.
func _toggle_item_lock(item_id: String) -> void:
	if net == null or not _connected:
		return
	var cur := false
	for it in _sell_items:
		if str(it.get("id", "")) == item_id:
			cur = bool(it.get("locked", false))
			break
	_sell_selection.erase(item_id)
	net.inv_set_locked.rpc_id(1, item_id, not cur)

func _confirm_sell_selected() -> void:
	if net == null or not _connected:
		return
	var ids: Array = _sell_selection.keys().slice(0, SELL_BATCH_MAX)   # cap FIRST so the quoted total matches
	if ids.is_empty():
		return
	var total := 0
	for id in ids:
		var info = _shop_sell_cache.get(id)
		if info != null:
			total += int(info["scrap"] if _sell_salvage else info["price"])
	var plural: String = "s" if ids.size() != 1 else ""
	if _sell_salvage:
		_show_sell_confirm("Salvage %d item%s for %d scrap?" % [ids.size(), plural, total], func() -> void:
			if net != null and _connected:
				net.salvage_many.rpc_id(1, ids)
			_sell_selection.clear())
	else:
		_show_sell_confirm("Sell %d item%s for ◈%d?" % [ids.size(), plural, total], func() -> void:
			if net != null and _connected:
				net.shop_sell_many.rpc_id(1, ids)
			_sell_selection.clear())

# generic confirm modal (reused by the bulk-sell flow). on_yes runs if the player confirms.
func _show_sell_confirm(prompt: String, on_yes: Callable) -> void:
	_close_sell_confirm()
	_sell_confirm = Panel.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_sell_confirm.add_child(vb)
	var lbl := Label.new()
	lbl.text = prompt
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var yes := Button.new()
	yes.text = "Confirm"
	yes.pressed.connect(func() -> void:
		on_yes.call()
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

# the forge pad in the home base + the "press F" proximity prompt (mirrors the shop pad)
func _render_forge_pad() -> void:
	var forge = _state.get("forge")
	var sig := JSON.stringify(forge)
	if sig == _forge_sig:
		return
	_forge_sig = sig
	if _forge_root != null:
		_forge_root.queue_free()
		_forge_root = null
	if forge == null or _world_root == null:
		return
	_forge_root = Node3D.new()
	_world_root.add_child(_forge_root)
	var pos := Vector3((float(forge["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(forge["y"]) - _ah() / 2.0) * SCALE)
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = World.FORGE_RADIUS * SCALE * 0.5
	cyl.bottom_radius = World.FORGE_RADIUS * SCALE * 0.6
	cyl.height = 2.6
	pillar.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.45, 0.2, 0.34)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.15)
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.material_override = mat
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pillar.position = pos + Vector3(0.0, 1.3, 0.0)
	_forge_root.add_child(pillar)
	var lbl := Label3D.new()
	lbl.text = "🔨 Forge"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0016
	lbl.font_size = 52
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = Color(1.0, 0.6, 0.4)
	lbl.position = pos + Vector3(0.0, 3.4, 0.0)
	_forge_root.add_child(lbl)

func _update_forge_proximity() -> void:
	if _forge_hint == null:
		_forge_hint = Label.new()
		_forge_hint.add_theme_font_size_override("font_size", 18)
		_forge_hint.modulate = Color(1.0, 0.6, 0.4)
		_forge_hint.visible = false
		_hud.add_child(_forge_hint)
	var forge = _state.get("forge")
	var pf = _find_fighter(_player_id)
	_near_forge = false
	if forge != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(forge["x"]), float(pf["y"]) - float(forge["y"])).length()
		_near_forge = d <= World.FORGE_RADIUS
	if _near_forge and (_forge_panel == null or not _forge_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_forge_hint.text = "Press [F] to forge"
		_forge_hint.position = Vector2(vp.x / 2.0 - 70.0, vp.y - 180.0)
		_forge_hint.visible = true
	else:
		_forge_hint.visible = false
	if not _near_forge and _forge_panel != null and _forge_panel.visible:
		_forge_panel.visible = false                 # walked away → close the forge

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
		["→ Frontier", "goto", {"map": "frontier"}], ["→ Depths", "goto", {"map": "depths"}], ["→ Arena", "goto", {"map": "arena"}],
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
			net.shop_buy.rpc_id(1, "main_hand", "common")
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
	_render_forge_pad()
	_update_forge_proximity()
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
	if _sheet_panel != null and _sheet_panel.visible:    # keep the character sheet live while it's open
		_render_charsheet()
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
			if _tooltip != null: _tooltip.visible = false    # clear any stuck item-hover tooltip on close
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
			elif _sheet_panel != null and _sheet_panel.visible:
				_sheet_panel.visible = false
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
			elif _forge_panel != null and _forge_panel.visible:
				_forge_panel.visible = false
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
		elif e.keycode == KEY_K and not _chatting:
			_toggle_charsheet()
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
		elif e.keycode == KEY_F and not _chatting and (_near_forge or (_forge_panel != null and _forge_panel.visible)):
			_toggle_forge()                 # open/close the forge while on the home pad
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
	_info.text = "[b]%s[/b]  [color=#9fb4c8]%s · %s[/color]   [color=#ffd24d][b]Lvl %d[/b][/color]  HP %d/%d %s   [color=#9fe8a0]XP %d/%d[/color]   [color=#ffd24d]◈ %d[/color]   [color=#c9a36a]%d scrap[/color]   %s   [color=#7fd4ff]ONLINE[/color]\n[color=#7f93a8]WASD · 1-8 abilities · LMB basic · RMB camera ([b]right-click a player[/b] = invite) · [b]Tab[/b] enemy · [b]Ctrl+Tab[/b]/frame = ally · [b]I[/b] bag · [b]K[/b] sheet · [b]J[/b] journal · [b]F[/b] forge · [b]O[/b] options[/color]" % [
		c["name"], c["sport"], c["role"], lvl, int(round(pf["hp"])), int(pf["maxHP"]), alive_txt, xp, xpn, int(pf.get("credits", 0)), _my_scrap(), zone_chip]
	_bar.text = ""
	_update_hotbar(pf)                           # the visual skill bar (shared with local mode)

func _zone_name(map: String) -> String:
	match map:
		"home": return "Home Base"
		"combat": return "Combat Zone"
		"frontier": return "Frontier"
		"depths": return "The Depths"
		"arena": return "Arena"
		_: return map.capitalize() if map != "" else "—"
