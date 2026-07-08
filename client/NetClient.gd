extends "res://client/Client.gd"
## NETWORKED CLIENT (Phase 2). Extends the Phase-1 renderer and reuses every rendering helper;
## the only difference is WHERE the world comes from: instead of ticking the sim locally, it
## fills _state from server snapshots and sends its input to the server's controlled seam.
##
## Two transports, identical rendering:
##   ONLINE — a remote client: intents/snapshots via the Net RPC bridge.
##   HOST   — the player who is also hosting: talks to the in-process Server directly.

const REAUTH_INTERVAL := 1500.0   # re-issue a fresh access token every 25 min (< ~1h TTL)
const MOVE_SEND_INTERVAL := 1.0 / 30.0   # cap input sends at the server tick (30 Hz); 60 Hz floods the UDP buffer
var _move_send_t := 0.0
const DESPAWN_GRACE := 3.0        # keep an out-of-interest node hidden this long before freeing
const RARITY_COLORS := Palette.RARITY_HEX      # P0: the rarity ramp now lives in client/ui/Palette.gd
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

signal logout_requested      # user chose "Log Out" (settings) or "Return to Login" (disconnect) → Main tears down + reloads
var _dc_overlay: Control = null              # prominent full-screen "disconnected" notice (dim + banner + Return to Login)
var _dc_msg_label: Label = null
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
var _invite_popup: PanelContainer = null      # "Invite <name>?" after clicking a player
var _invite_prompt: PanelContainer = null     # an incoming invite (accept/decline)
var _invite_from_fid := ""
# party loot want/need/pass roll (one prompt at a time; extra drops queue)
var _loot_roll_queue := []                    # [{drop_id, info, ms}]
var _loot_roll_panel: PanelContainer = null
var _loot_roll_cur := -1                       # drop_id currently prompting
var _loot_roll_deadline := 0.0                 # secs left before auto-pass
var _loot_roll_timer_lbl: Label = null
var _inv_panel: Control
var _sheet_panel: Control                    # character sheet (K) — computed base+gear stats + item power
var _sheet_label: RichTextLabel
var _inv_items := []                          # last-loaded inventory cache (for hover tooltips)
var _inv_grid: GridContainer                  # P7: the item-tile grid
var _inv_paperdoll: GridContainer             # P7: the equipped-slots paperdoll
var _inv_status: Label                        # P7: "N items" / loading / empty
var _inv_ctx: PopupMenu                       # P7: right-click context menu
var _inv_ctx_item := ""                       # the item id the context menu is acting on
var _inv_controls: HBoxContainer = null       # sort buttons + Equip Best (rebuilt per render)
var _inv_sort_mode := "rarity"                # rarity | type | power
var _inv_change_seq := 0                       # bumped on recv_inventory_changed (Equip Best waits on it)
var _equip_best_busy := false                  # re-entrancy guard for the Equip Best sequence
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
# Builder Mode (P3): the Build Shop pad/panel (buy furniture) + the locked-locker "Purchase" portal prompt
var _build_info := {}              # catalog + caps + unlock cost (from recv_build_info)
var _build_shop_panel: Control = null
var _build_shop_status: Label = null
var _build_shop_grid: GridContainer = null
var _build_shop_root: Node3D = null
var _build_shop_sig := ""
var _build_shop_hint: Label = null
var _near_build_shop := false
var _locker_portal_hint: Label = null
var _near_locker_portal := false
var _was_locker_unlocked := false   # tracks false→true to toast "Locker Room unlocked!" once
# Builder Mode (P3b): the in-Locker-Room build editor (F4 in your own unlocked room). Server-driven — every
# place/move/remove is an RPC; the room renders from the server's snapshot decals (client is purely UX).
var _lb_on := false                 # is the locker build editor active?
var _lb_pal := []                   # palette: your OWNED UNPLACED build items [{id, model}]
var _lb_idx := 0                    # index into _lb_pal (the item to place next)
var _lb_h := 2.0                    # scale (height) for the next placement
var _lb_yaw := 0.0                  # yaw for the next placement
var _lb_oy := 0.0                   # lift (stacking) for the next placement
var _lb_grab_id := ""               # id of the PLACED prop being moved (follows the cursor); "" = none
var _lb_grab_model := ""            # model of the grabbed prop (so the ghost shows what you're moving)
var _lb_grab_from := {}             # the grabbed prop's xform BEFORE the move (for undo)
var _lb_undo := []                  # stack of reverse-ops [{act,id,xform?}] for Ctrl+Z
var _lb_del_id := ""                # id of the prop pending a [Y]/[N] delete confirmation ("" = not confirming)
var _lb_del_ghost: Node3D = null    # RED highlight of the prop about to be deleted
var _lb_del_panel: Panel = null     # the centered Delete? / Keep / Pick-another button menu
var _lb_del_panel_model := ""       # model currently shown in the menu title (rebuild when it changes)
var _build_help_panel: Panel = null # the onboarding "how to build" popup (auto on locker entry + [H])
var _build_help_hide := false       # persisted pref: skip the auto-popup on entry (settings.cfg [build]/hide_help)
var _build_help_hint: Label = null  # the always-visible "press [H] for build help" reminder in the locker
var _lb_lbl: Label = null           # the editor HUD line
var _lb_ghost: Node3D = null        # translucent preview of the to-place / being-moved prop at the cursor
var _lb_ghost_key := ""             # model+"@"+h of the current ghost (rebuild only when it changes)
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
# Practice Vendor (reward loop) — the Rookie Camp set bought with Practice Tokens, at a home pad.
var _vendor_info := {}
var _vendor_panel: Control = null
var _vendor_status: Label = null
var _vendor_rows: VBoxContainer = null
var _vendor_root: Node3D = null
var _vendor_sig := ""
var _vendor_hint: Label = null
var _near_vendor := false
# Camp Circuit (endgame): the Intensity selector at the home entry portal
var _camp_panel: Control = null
var _camp_rows: VBoxContainer = null
var _camp_status: Label = null
var _camp_hint: Label = null
var _near_camp := false
# Wardrobe (P4 cosmetics): a key-toggled dye panel (buy with credits + equip)
var _wardrobe_panel: Control = null
var _wardrobe_rows: VBoxContainer = null
var _wardrobe_status: Label = null
# Leaderboards + Two-Minute Drill (P5)
var _lb_panel: Control = null
var _lb_rows: VBoxContainer = null
var _lb_status: Label = null
var _lb_cat := "drill"
var _lb_entries := []
var _drill_banner: Label = null
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
var _settings_reset_note: Label = null      # "UI layout reset" confirmation
var _last_level := 0                         # for the level-up sound
var _last_map := ""                          # for zone-change sound + music crossfade

# Replaces the LOCAL sandbox setup: no local match — wait for the server to assign a fighter.
func _enter_mode() -> void:
	Engine.max_fps = 60
	_meter_party_only = true     # §4a: online, the meter defaults to party scope (zone is the opt-in)
	_player = PlayerCtl.new()
	add_child(_player)
	_player_id = ""              # set by assign_fighter()
	_build_chat()
	_build_inventory()
	_build_charsheet()
	_build_forge()
	_build_shop()
	_build_build_shop_panel()
	_build_vendor()
	_build_camp()
	_build_wardrobe()
	_build_leaderboard()
	_build_questlog()
	_build_qgiver_dialog()
	_build_settings()
	_build_locker()
	_build_disconnect_overlay()
	_build_juice_online()
	var ua := OS.get_cmdline_user_args()
	if "--meter" in ua:                           # dev-only: open the §4a meter on boot (pairs with --shot)
		_toggle_meter()
	var oi := ua.find("--open")                   # dev-only: open a named panel after the first snapshot
	if oi >= 0 and oi + 1 < ua.size():
		_dev_open = str(ua[oi + 1])
	if "--juicetest" in ua:                       # dev-only: fire demo P4 juice once connected (for --shot)
		_dev_juice = true
	print("[netclient] ready — awaiting server fighter assignment")

var _dev_juice := false

var _dev_open := ""                               # dev-only screenshot hook: panel to open once connected
func _dev_open_panel() -> void:
	var which := _dev_open
	_dev_open = ""                                # clear FIRST so a later snapshot can't re-toggle mid-await
	match which:
		"charsheet": _toggle_charsheet()
		"settings": _toggle_settings()
		"wardrobe": _toggle_wardrobe()
		"questlog": _toggle_questlog()
		"leaderboard": _toggle_leaderboard()
		"camp": _toggle_camp()
		"inventory": _toggle_inventory()
		"shop": _toggle_shop()
		"forge": _toggle_forge()
		"vendor": _toggle_vendor()
		"qgiver": _toggle_qgiver()
		"locker": _toggle_locker()
	if which == "locker" and "--sel" in OS.get_cmdline_user_args():
		await get_tree().create_timer(1.5).timeout   # dev: select main_hand to show the detail panel
		_select_locker_slot("main_hand", 0)
	if which == "inventory" and "--equipbest" in OS.get_cmdline_user_args():
		await get_tree().create_timer(2.0).timeout   # dev: run Equip Best once the inventory has loaded
		_equip_best()

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
	var p := Widgets.panel("Inventory", "I / Esc", 760.0, _toggle_inventory)
	_inv_panel = p["root"]
	_hud.add_child(_inv_panel)
	var vb: VBoxContainer = p["body"]
	_inv_status = Label.new()
	_inv_status.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	_inv_status.add_theme_color_override("font_color", Palette.TEXT_DIM)
	vb.add_child(_inv_status)
	_inv_controls = HBoxContainer.new()           # sort + Equip Best (populated by _render_inv_tiles)
	_inv_controls.add_theme_constant_override("separation", 8)
	vb.add_child(_inv_controls)
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
	var p := Widgets.panel("Character", "K / Esc", 440.0, _toggle_charsheet)
	_sheet_panel = p["root"]
	_hud.add_child(_sheet_panel)
	var vb: VBoxContainer = p["body"]
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
		if _locker_panel != null: _locker_panel.visible = false
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

# ============================================================ Locker Loadout (paperdoll)
# A full-screen gear + stats screen (the "Locker Loadout" design): two slot columns flanking a live 3D
# model of the player, a right-side item-details panel, and a bottom stat bar. Slot art =
# client/ui/icons/<slot>.png (white line-art, tinted by item rarity). Equipping happens here or in the bag.
const LOCKER_LEFT := [["head", "Head", 0], ["chest", "Chest", 0], ["hands", "Hands", 0], ["legs", "Legs", 0], ["feet", "Feet", 0]]
const LOCKER_RIGHT := [["neck", "Neck", 0], ["ring", "Ring 1", 0], ["ring", "Ring 2", 1], ["main_hand", "Main Hand", 0], ["off_hand", "Off Hand", 0], ["trinket", "Trinket", 0]]
var _locker_panel: Control = null
var _locker_slots := []                   # [{key, idx, panel, sb, icon, name}]
var _locker_items := []                   # last-loaded inventory
var _locker_sel := {"key": "", "idx": 0}  # selected slot
var _locker_detail: VBoxContainer = null
var _locker_stats: HBoxContainer = null
var _locker_stat_sig := "-"                # change-guard so the stat bar rebuilds only when values change
var _locker_name: Label = null            # top-center: character name (prominent)
var _locker_subtitle: Label = null        # top-center: class · Lv N (item power lives in the bottom OVR only)
var _locker_loading := false
var _locker_pending := false
var _slot_tex_cache := {}
# center 3D figure
var _locker_vp: SubViewport = null
var _locker_model_holder: Node3D = null
var _locker_model_class := ""
var _locker_model_dye := "-"

func _slot_icon(key: String) -> Texture2D:
	if not _slot_tex_cache.has(key):
		var p := "res://client/ui/icons/%s.png" % key
		_slot_tex_cache[key] = load(p) if ResourceLoader.exists(p) else null
	return _slot_tex_cache[key]

func _build_locker() -> void:
	_locker_panel = Control.new()
	_locker_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_locker_panel.visible = false
	_hud.add_child(_locker_panel)
	var bg := ColorRect.new()                 # full-bleed opaque dark backdrop (modal — hides the world + eats clicks)
	bg.color = Color(0.03, 0.04, 0.06, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_locker_panel.add_child(bg)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 22)
	_locker_panel.add_child(m)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	m.add_child(root)
	# header: a full-width band with the LOCKER LOADOUT title anchored left, the ✕ anchored right, and the
	# CHARACTER NAME + class/level in a full-rect CenterContainer so it's truly SCREEN-centered (not offset
	# by the differing widths of the left title vs the right ✕).
	var head := Control.new()
	head.custom_minimum_size = Vector2(0, 56)
	root.add_child(head)
	var titv := VBoxContainer.new()               # left: the screen title
	titv.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var tit := Label.new()
	tit.text = "LOCKER LOADOUT"
	tit.add_theme_font_size_override("font_size", 24)
	tit.add_theme_color_override("font_color", Palette.TEXT_DIM)
	titv.add_child(tit)
	var tag := Label.new()
	tag.text = "GEAR UP · SHOW UP · TAKE OVER"
	tag.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	tag.add_theme_color_override("font_color", Palette.ACCENT)
	titv.add_child(tag)
	head.add_child(titv)
	var namecc := CenterContainer.new()           # center: the character (prominent, screen-centered)
	namecc.set_anchors_preset(Control.PRESET_FULL_RECT)
	namecc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(namecc)
	var namev := VBoxContainer.new()
	namecc.add_child(namev)
	_locker_name = Label.new()
	_locker_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_locker_name.add_theme_font_size_override("font_size", 30)
	_locker_name.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	namev.add_child(_locker_name)
	_locker_subtitle = Label.new()
	_locker_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_locker_subtitle.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	_locker_subtitle.add_theme_color_override("font_color", Palette.ACCENT2)
	namev.add_child(_locker_subtitle)
	var x := Button.new()                          # right: close
	x.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	x.text = "✕"
	x.focus_mode = Control.FOCUS_NONE
	x.pressed.connect(_toggle_locker)
	head.add_child(x)
	root.add_child(HSeparator.new())
	# body: left slots | 3D figure | right slots | detail
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	var leftcol := VBoxContainer.new()
	leftcol.add_theme_constant_override("separation", 8)
	for e in LOCKER_LEFT:
		leftcol.add_child(_locker_slot(str(e[0]), str(e[1]), int(e[2])))
	body.add_child(leftcol)
	body.add_child(_build_locker_viewport())
	var rightcol := VBoxContainer.new()
	rightcol.add_theme_constant_override("separation", 8)
	for e in LOCKER_RIGHT:
		rightcol.add_child(_locker_slot(str(e[0]), str(e[1]), int(e[2])))
	body.add_child(rightcol)
	var detailpc := PanelContainer.new()
	detailpc.custom_minimum_size = Vector2(320, 0)
	var dm := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		dm.add_theme_constant_override("margin_" + s, 12)
	detailpc.add_child(dm)
	_locker_detail = VBoxContainer.new()
	_locker_detail.add_theme_constant_override("separation", 6)
	dm.add_child(_locker_detail)
	body.add_child(detailpc)
	# bottom stat bar
	root.add_child(HSeparator.new())
	_locker_stats = HBoxContainer.new()
	_locker_stats.add_theme_constant_override("separation", 14)
	root.add_child(_locker_stats)

# one equipment slot cell: rarity-framed icon + label + equipped name. Click selects it into the detail.
func _locker_slot(key: String, label: String, idx: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(210, 62)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.BG_INSET)
	sb.set_border_width_all(2)
	sb.border_color = Palette.BORDER
	sb.set_corner_radius_all(7)
	sb.set_content_margin_all(6)
	p.add_theme_stylebox_override("panel", sb)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(hb)
	var icon := TextureRect.new()
	icon.texture = _slot_icon(key)
	icon.custom_minimum_size = Vector2(46, 46)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.modulate = Color(Palette.TEXT_FAINT, 0.5)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(icon)
	var vb := VBoxContainer.new()
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(vb)
	var ll := Label.new()
	ll.text = label.to_upper()
	ll.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	ll.add_theme_color_override("font_color", Palette.TEXT_DIM)
	vb.add_child(ll)
	var nm := Label.new()
	nm.text = "— empty —"
	nm.clip_text = true
	nm.custom_minimum_size = Vector2(130, 0)
	nm.add_theme_font_size_override("font_size", Palette.SIZE_BODY)
	nm.add_theme_color_override("font_color", Palette.TEXT_FAINT)
	vb.add_child(nm)
	var entry := {"key": key, "idx": idx, "panel": p, "sb": sb, "icon": icon, "name": nm, "item": null}
	p.gui_input.connect(func(ev) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_select_locker_slot(key, idx))
	p.mouse_entered.connect(func() -> void:       # hover an equipped slot → the compare tooltip (vs deltas)
		if entry.get("item") != null: _show_item_tooltip(entry["item"], _locker_items))
	p.mouse_exited.connect(func() -> void:
		if _tooltip != null: _tooltip.visible = false)
	_locker_slots.append(entry)
	return p

# the center live 3D figure — the player's own character model, rotating, in its own SubViewport world.
func _build_locker_viewport() -> Control:
	var vpc := SubViewportContainer.new()
	vpc.stretch = true
	vpc.custom_minimum_size = Vector2(300, 470)
	vpc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_locker_vp = SubViewport.new()
	_locker_vp.own_world_3d = true
	_locker_vp.transparent_bg = true
	_locker_vp.msaa_3d = Viewport.MSAA_2X
	vpc.add_child(_locker_vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.9, 6.4)
	cam.rotation_degrees = Vector3(-3, 0, 0)
	cam.fov = 36
	_locker_vp.add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-34, -38, 0)
	key.light_energy = 1.35
	_locker_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, 140, 0)
	fill.light_energy = 0.55
	_locker_vp.add_child(fill)
	_locker_model_holder = Node3D.new()
	_locker_vp.add_child(_locker_model_holder)
	return vpc

# (re)build the 3D figure when the class or dye changes; otherwise it just keeps rotating.
func _update_locker_model() -> void:
	if _locker_model_holder == null:
		return
	var si: Dictionary = _state.get("self", {})
	var pf = _find_fighter(_player_id)
	var cls: String = str(si.get("classId", "")) if si.has("classId") else (str(pf.get("classId", "")) if pf != null else "")
	var dye: String = str(si.get("cos_dye", ""))
	if cls == "" or not GameData.CLASSES.has(cls):
		return
	if cls == _locker_model_class and dye == _locker_model_dye:
		return
	_locker_model_class = cls
	_locker_model_dye = dye
	for c in _locker_model_holder.get_children():
		c.queue_free()
	var kit := _make_character({"classId": cls, "id": "locker", "team": 0})
	var model = kit["model"]
	var msc: float = kit["scale"]
	model.scale = Vector3(msc, msc, msc)
	model.position.y = CHAR_Y + float(kit.get("yoff", 0.0))
	_locker_model_holder.add_child(model)
	var ap = kit["anim"]
	if ap != null:
		ap.playback_default_blend_time = 0.12
		_safe_play(ap, kit["anims"].get("idle", "idle"))
	if dye != "":
		# self block ships the dye ID ("emerald"); _apply_dye wants a hex — resolve it (the in-world model
		# uses the server-resolved `dye` field, but the locker reads cos_dye raw). Guard var stays the ID.
		_apply_dye(model, str(GameData.DYE_CATALOG.get(dye, {}).get("color", "")))

func _toggle_locker() -> void:
	if _locker_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_locker_panel.visible = not _locker_panel.visible
	if _locker_panel.visible:                 # full-screen opaque modal → close every other panel under it
		for pnl in [_inv_panel, _sheet_panel, _quest_panel, _shop_panel, _forge_panel, _vendor_panel, _camp_panel, _wardrobe_panel, _lb_panel, _qgiver_panel, _settings_panel, _meter_panel]:
			if pnl != null: pnl.visible = false
		_locker_stat_sig = "-"                # force a fresh stat-bar rebuild on (re)open
		_update_locker_model()
		_load_locker()

func _load_locker() -> void:
	if supa == null or _locker_panel == null:
		return
	if _locker_loading:
		_locker_pending = true
		return
	_locker_loading = true
	var r = await supa.get_inventory()
	_locker_loading = false
	if _locker_pending:
		_locker_pending = false
		_load_locker()
		return
	if _locker_panel == null:
		return
	_locker_items = r.get("items", []) if r.get("ok") else []
	_refresh_locker()

# rebuild slot art/names + the stat bar + the detail panel from the current inventory + self block.
func _refresh_locker() -> void:
	if _locker_panel == null:
		return
	var equipped := {}                         # "key|idx" → item (idx picks between the two rings)
	var by_slot := {}
	for it in _locker_items:
		if bool(it.get("equipped", false)):
			var sl := str(it.get("slot", ""))
			if not by_slot.has(sl): by_slot[sl] = []
			by_slot[sl].append(it)
	for entry in _locker_slots:
		var sl: String = entry["key"]
		var idx: int = entry["idx"]
		var eqs: Array = by_slot.get(sl, [])
		var it = eqs[idx] if idx < eqs.size() else null
		entry["item"] = it                          # for the hover compare tooltip
		var icon: TextureRect = entry["icon"]
		var nm: Label = entry["name"]
		var sb: StyleBoxFlat = entry["sb"]
		if it != null:
			var col := _item_color(it)
			icon.modulate = col
			nm.text = str(it.get("name", "?"))
			nm.add_theme_color_override("font_color", col)
			sb.border_color = col
			sb.bg_color = Color(col, 0.10)
		else:
			icon.modulate = Color(Palette.TEXT_FAINT, 0.5)
			nm.text = "— empty —"
			nm.add_theme_color_override("font_color", Palette.TEXT_FAINT)
			sb.border_color = Palette.BORDER
			sb.bg_color = Color(Palette.BG_INSET)
	_update_locker_header()
	_update_locker_stats()
	_render_locker_detail()

# top-center character header (name + class · level) — live from each snapshot. Item power is shown ONLY
# in the bottom-left OVR cell of the stat bar (per the requested layout).
func _update_locker_header() -> void:
	if _locker_name == null:
		return
	var si: Dictionary = _state.get("self", {})
	var pf2 = _find_fighter(_player_id)
	var cls: String = str(si.get("classId", "")) if si.has("classId") else (str(pf2.get("classId", "")) if pf2 != null else "")
	var cdef: Dictionary = GameData.CLASSES.get(cls, {})
	var nm2: String = str(pf2.get("name", "")) if pf2 != null else ""
	_locker_name.text = nm2 if nm2 != "" else str(cdef.get("name", "—"))
	_locker_subtitle.text = "%s · %s · Lv %d" % [str(cdef.get("name", "")), str(cdef.get("role", "")), int(si.get("level", 0))]

func _update_locker_stats() -> void:
	if _locker_stats == null:
		return
	var si: Dictionary = _state.get("self", {})
	var pf = _find_fighter(_player_id)
	var cls: String = str(si.get("classId", "")) if si.has("classId") else (str(pf.get("classId", "")) if pf != null else "")
	# stats only change on equip/level, but the self block can populate item_power/gear a beat AFTER open —
	# so refresh live per snapshot, but skip the ~15-node rebuild when nothing changed (no 30 Hz churn).
	var sig := "%s|%d|%s" % [cls, int(si.get("item_power", 0)), JSON.stringify(si.get("equip_bonus", {}))]
	if sig == _locker_stat_sig:
		return
	_locker_stat_sig = sig
	for c in _locker_stats.get_children():
		c.queue_free()
	# OVR = item power
	var ovr := VBoxContainer.new()
	ovr.custom_minimum_size = Vector2(78, 0)
	var ol := Label.new(); ol.text = "OVR"; ol.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION); ol.add_theme_color_override("font_color", Palette.TEXT_DIM)
	ovr.add_child(ol)
	var ov := Label.new(); ov.text = str(int(si.get("item_power", 0))); ov.add_theme_font_size_override("font_size", 26); ov.add_theme_color_override("font_color", Palette.ACCENT)
	ovr.add_child(ov)
	_locker_stats.add_child(ovr)
	if cls == "" or not GameData.CLASSES.has(cls):
		return
	var base: Dictionary = GameData.CLASSES[cls]["stats"]
	var bonus: Dictionary = si.get("equip_bonus", {})
	for st in STAT_KEYS:
		var val: int = int(base.get(st, 0)) + int(bonus.get(st, 0))
		var g: int = int(bonus.get(st, 0))
		_locker_stats.add_child(_locker_stat_cell(str(STAT_NAMES.get(st, st)), val, g))

func _locker_stat_cell(name: String, value: int, gear: int) -> Control:
	var vb := VBoxContainer.new()
	vb.custom_minimum_size = Vector2(96, 0)
	var n := Label.new()
	n.text = name.to_upper()
	n.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	n.add_theme_color_override("font_color", Palette.TEXT_DIM)
	vb.add_child(n)
	var vrow := HBoxContainer.new()
	vrow.add_theme_constant_override("separation", 5)
	var v := Label.new()
	v.text = str(value)
	v.add_theme_font_size_override("font_size", 20)
	v.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	vrow.add_child(v)
	if gear > 0:
		var gl := Label.new()
		gl.text = "+%d" % gear
		gl.size_flags_vertical = Control.SIZE_SHRINK_END
		gl.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
		gl.add_theme_color_override("font_color", Palette.XP)
		vrow.add_child(gl)
	vb.add_child(vrow)
	var bar := Widgets.bar(84, 5, Palette.ACCENT if gear > 0 else Palette.BORDER_BRIGHT)
	Widgets.set_bar(bar, clampf(float(value) / 130.0, 0.04, 1.0))
	vb.add_child(bar["root"])
	return vb

func _select_locker_slot(key: String, idx: int) -> void:
	_locker_sel = {"key": key, "idx": idx}
	for entry in _locker_slots:              # highlight the selected slot
		var sb: StyleBoxFlat = entry["sb"]
		sb.set_border_width_all(3 if (entry["key"] == key and entry["idx"] == idx) else 2)
	_render_locker_detail()

# the item-details panel: the selected slot's equipped item (art, rarity, stats, power) + Unequip, plus a
# compact "equip from bag" list of the alternatives you own for that slot.
func _render_locker_detail() -> void:
	if _locker_detail == null:
		return
	for c in _locker_detail.get_children():
		c.queue_free()
	var key: String = str(_locker_sel.get("key", ""))
	if key == "":
		_locker_detail.add_child(Widgets.section("ITEM DETAILS"))
		_locker_detail.add_child(Widgets.hint("Select an equipment slot to see the piece + swap gear you own for it."))
		return
	var idx: int = int(_locker_sel.get("idx", 0))
	var slot_items := []                       # everything you own in this slot
	var equipped = null
	var eq_count := 0
	for it in _locker_items:
		if str(it.get("slot", "")) == key:
			slot_items.append(it)
			if bool(it.get("equipped", false)):
				if eq_count == idx: equipped = it
				eq_count += 1
	_locker_detail.add_child(Widgets.section("ITEM DETAILS"))
	var big := TextureRect.new()               # the big rarity-tinted slot icon
	big.texture = _slot_icon(key)
	big.custom_minimum_size = Vector2(96, 96)
	big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	big.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	big.modulate = _item_color(equipped) if equipped != null else Color(Palette.TEXT_FAINT, 0.5)
	_locker_detail.add_child(big)
	var info := RichTextLabel.new()
	info.bbcode_enabled = true
	info.fit_content = true
	info.scroll_active = false
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.custom_minimum_size = Vector2(290, 0)
	if equipped != null:
		var stats := _item_stats_str(equipped)
		info.text = "[b][color=%s]%s[/color][/b]  [color=%s]★ EQUIPPED[/color]\n[color=%s]%s · %s · i%d · ✦%d[/color]%s" % [
			_item_color_hex(equipped), _esc(str(equipped.get("name", "?"))), Palette.hex(Palette.XP),
			Palette.hex(Palette.TEXT_FAINT), str(equipped.get("rarity", "")), key, int(equipped.get("ilvl", 1)),
			int(equipped.get("item_power", 0)), ("\n" + stats if stats != "" else "")]
	else:
		info.text = "[color=%s]No %s equipped.[/color]" % [Palette.hex(Palette.TEXT_DIM), key]
	_locker_detail.add_child(info)
	if equipped != null:
		var iid := str(equipped.get("id", ""))
		var slotk := str(equipped.get("slot", ""))
		var uneq := Button.new()
		uneq.text = "Unequip"
		uneq.pressed.connect(func() -> void:
			if net != null and _connected: net.equip.rpc_id(1, iid, slotk))
		_locker_detail.add_child(uneq)
	# swap list: the pieces you own for this slot but haven't equipped (sorted by item power)
	var others := []
	for it in slot_items:
		if equipped == null or str(it.get("id", "")) != str(equipped.get("id", "")):
			if not bool(it.get("equipped", false)):
				others.append(it)
	others.sort_custom(func(a, b): return int(a.get("item_power", 0)) > int(b.get("item_power", 0)))
	if not others.is_empty():
		# ▲ = beats the piece equipped in THIS slot (or fills an empty slot). Compared against the equipped
		# item's power directly — NOT _is_upgrade (which reads _inv_items, empty when only the locker is open).
		var eq_power := int(equipped.get("item_power", 0)) if equipped != null else -1
		_locker_detail.add_child(HSeparator.new())
		_locker_detail.add_child(Widgets.section("EQUIP FROM BAG"))
		var sc := ScrollContainer.new()
		sc.custom_minimum_size = Vector2(296, 150)
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		var lst := VBoxContainer.new()
		lst.add_theme_constant_override("separation", 3)
		sc.add_child(lst)
		for it in others:
			var is_up: bool = int(it.get("item_power", 0)) > eq_power
			var b := Button.new()
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.clip_text = true
			b.custom_minimum_size = Vector2(286, 30)
			b.add_theme_color_override("font_color", _item_color(it))
			b.text = "%s   ✦%d%s" % [str(it.get("name", "?")), int(it.get("item_power", 0)), ("  ▲" if is_up else "")]
			var iid2 := str(it.get("id", ""))
			var slotk2 := str(it.get("slot", ""))
			var itc: Dictionary = it                  # per-iteration copy for the hover-tooltip closure
			b.pressed.connect(func() -> void:
				if net != null and _connected: net.equip.rpc_id(1, iid2, slotk2))
			b.mouse_entered.connect(func() -> void: _show_item_tooltip(itc, _locker_items))   # vs-equipped deltas
			b.mouse_exited.connect(func() -> void:
				if _tooltip != null: _tooltip.visible = false)
			lst.add_child(b)
		_locker_detail.add_child(sc)

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
		var ipd: int = int(it.get("item_power", 0)) - int(cmp.get("item_power", 0))   # the at-a-glance upgrade call
		if ipd > 0:
			L.append("  [color=#9fe8a0]▲ +%d Item Power[/color]" % ipd)
		elif ipd < 0:
			L.append("  [color=#ff8a8a]▼ %d Item Power[/color]" % ipd)
		else:
			L.append("  [color=#7f93a8]= same Item Power[/color]")
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
		if _locker_panel != null: _locker_panel.visible = false
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
	_inv_items = r.get("items", [])               # cache for hover comparison tooltips
	_rebuild_paperdoll(_inv_items)
	_render_inv_tiles()
	if _build_shop_panel != null and _build_shop_panel.visible:   # Build Shop open → refresh its "N/cap owned" count
		_render_build_shop_catalog()

# rebuild the controls (sort + Equip Best) + status + the sorted tile grid from the cached _inv_items.
# Cheap (no re-fetch) — the sort buttons call this directly.
func _render_inv_tiles() -> void:
	if _inv_grid == null:
		return
	if _tooltip != null:
		_tooltip.visible = false
	for ch in _inv_grid.get_children():
		ch.queue_free()
	for ch in _inv_controls.get_children():
		ch.queue_free()
	# controls row: sort modes + Equip Best
	_inv_controls.add_child(_ctrl_label("sort:"))
	for key in ["rarity", "type", "power", "build"]:   # "build" = the Builder-Mode furniture tab
		var k_l: String = key
		_inv_controls.add_child(_ctrl_btn(key.capitalize(), Palette.ACCENT if _inv_sort_mode == key else Palette.TEXT_DIM, func() -> void:
			_inv_sort_mode = k_l
			_render_inv_tiles()))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_controls.add_child(spacer)
	var best := _ctrl_btn("⚡ Equip Best", Palette.ACCENT, _equip_best)
	best.disabled = _equip_best_busy
	_inv_controls.add_child(best)
	if _inv_sort_mode == "build":                      # Builder Mode: furniture/props ONLY (gear tabs exclude these)
		var bview := []
		for it in _inv_items:
			if str(it.get("category", "")) == "build":
				bview.append(it)
		if bview.is_empty():
			_inv_status.text = "no furniture yet — buy props at the Build Shop [P] in the home base"
			return
		var placed_n := 0
		for it in bview:
			if bool(it.get("placed", false)):
				placed_n += 1
		_inv_status.text = "%d furniture · %d placed · buy more at the Build Shop [P]" % [bview.size(), placed_n]
		bview.sort_custom(func(a, b): return str(a.get("model", "")) < str(b.get("model", "")))
		for it in bview:
			_inv_grid.add_child(_build_item_tile(it))
		return
	# gear tabs (rarity/type/power) — EXCLUDE build items so furniture never clutters the gear grid
	var gear := []
	for it in _inv_items:
		if str(it.get("category", "")) != "build":
			gear.append(it)
	if gear.is_empty():
		_inv_status.text = "empty — kill mobs to find loot"
		return
	var ups := 0
	for it in gear:
		if _is_upgrade(it):
			ups += 1
	var uptxt: String = "   ·   ▲ %d upgrade%s" % [ups, "" if ups == 1 else "s"] if ups > 0 else ""
	_inv_status.text = "%d items · click to equip · right-click to lock%s" % [gear.size(), uptxt]
	var view: Array = gear.duplicate()
	view.sort_custom(_inv_sort_cmp)
	for it in view:
		_inv_grid.add_child(_inv_tile(it))

func _inv_sort_cmp(a, b) -> bool:
	match _inv_sort_mode:
		"type":
			var sa := str(a.get("slot", ""))
			var sb := str(b.get("slot", ""))
			if sa != sb:
				return sa < sb
			return int(RARITY_RANK.get(str(a.get("rarity", "")), 0)) > int(RARITY_RANK.get(str(b.get("rarity", "")), 0))
		"power":
			return int(a.get("item_power", 0)) > int(b.get("item_power", 0))
		_:  # rarity: equipped first, then rarity desc, then name
			var ae := 1 if bool(a.get("equipped", false)) else 0
			var be := 1 if bool(b.get("equipped", false)) else 0
			if ae != be:
				return ae > be
			var ra := int(RARITY_RANK.get(str(a.get("rarity", "")), 0))
			var rb := int(RARITY_RANK.get(str(b.get("rarity", "")), 0))
			if ra != rb:
				return ra > rb
			return str(a.get("name", "")) < str(b.get("name", ""))

# an item's fit for the current class: sum of each stat × the class's base value for that stat, so a
# class's key stats (its high base stats) weigh heaviest. item_power breaks ties.
func _class_score(it: Dictionary, weights: Dictionary) -> int:
	var totals := _item_stat_totals(it)
	var s := 0
	for st in totals:
		s += int(totals[st]) * int(weights.get(st, 0))
	return s

# Equip Best: for each slot pick the top item(s) by class fit; unequip mismatches, equip the winners.
# The server rate-limits equips (300 ms + a serialize guard), so fire them one at a time, waiting for the
# recv_inventory_changed push (bumps _inv_change_seq) before the next — or a short timeout as a fallback.
func _equip_best() -> void:
	if _equip_best_busy or net == null or not _connected or _inv_items.is_empty():
		return
	var si: Dictionary = _state.get("self", {})
	var pf = _find_fighter(_player_id)
	var cls: String = str(si.get("classId", "")) if si.has("classId") else (str(pf.get("classId", "")) if pf != null else "")
	if cls == "" or not GameData.CLASSES.has(cls):
		return
	var weights: Dictionary = GameData.CLASSES[cls]["stats"]
	var by_slot := {}
	for it in _inv_items:
		var sl := str(it.get("slot", ""))
		if sl == "":
			continue
		if not by_slot.has(sl):
			by_slot[sl] = []
		by_slot[sl].append(it)
	var actions := []                             # [{id, slot}] — unequips first, then equips
	for sl in by_slot:
		var cap: int = 2 if sl == "ring" else 1
		var items: Array = by_slot[sl]
		items.sort_custom(func(a, b):
			var sca := _class_score(a, weights)
			var scb := _class_score(b, weights)
			if sca != scb:
				return sca > scb
			return int(a.get("item_power", 0)) > int(b.get("item_power", 0)))
		var best: Array = items.slice(0, cap)
		var best_ids := {}
		for b in best:
			best_ids[str(b.get("id", ""))] = true
		for it in items:                          # unequip anything worn in this slot that isn't a winner
			if bool(it.get("equipped", false)) and not best_ids.has(str(it.get("id", ""))):
				actions.append({"id": str(it.get("id", "")), "slot": sl})
		for b in best:                            # equip each winner not already worn
			if not bool(b.get("equipped", false)):
				actions.append({"id": str(b.get("id", "")), "slot": sl})
	if actions.is_empty():
		_inv_status.text = "already wearing your best gear for this class"
		return
	_equip_best_busy = true
	for ch in _inv_controls.get_children():       # disable the button while running
		if ch is Button and (ch as Button).text == "⚡ Equip Best":
			(ch as Button).disabled = true
	for i in actions.size():
		var a = actions[i]
		_inv_status.text = "⚡ equipping best gear…  (%d/%d)" % [i + 1, actions.size()]
		var seq := _inv_change_seq
		if net != null and _connected:
			net.equip.rpc_id(1, str(a["id"]), str(a["slot"]))
		var waited := 0.0                         # wait for this equip to land (server push), or bail after 1.4 s
		while _inv_change_seq == seq and waited < 1.4:
			await get_tree().create_timer(0.08).timeout
			waited += 0.08
		await get_tree().create_timer(0.12).timeout   # margin past the 300 ms equip rate window
	_equip_best_busy = false
	_load_inventory()

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

# true if this (unequipped) item is a strict Item-Power upgrade over what it would replace in its slot,
# OR fills a still-empty slot with any stats — the green ▲ tile marker + a heads-up for the player.
func _is_upgrade(it: Dictionary) -> bool:
	if bool(it.get("equipped", false)):
		return false
	var slot := str(it.get("slot", ""))
	if slot == "":
		return false
	var cmp = _replace_candidate(it, _inv_items, slot)
	if cmp == null:                             # slot has open capacity → an equippable piece with stats
		return _equipped_count(_inv_items, slot) < (2 if slot == "ring" else 1) and int(it.get("item_power", 0)) > 0
	return int(it.get("item_power", 0)) > int(cmp.get("item_power", 0))

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
	elif _is_upgrade(it):                        # a bag item that beats what it'd replace → at-a-glance ▲
		prefix += "▲ "
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
	_inv_change_seq += 1                          # Equip Best waits on this to pace its equips
	if _inv_panel != null and _inv_panel.visible:
		_load_inventory()
	if _shop_panel != null and _shop_panel.visible:   # a buy/sell/roll/lock changed our items + credits
		_render_shop_buy()
		_load_shop_sell()
	if _forge_panel != null and _forge_panel.visible: # an upgrade/salvage changed items, level, scrap
		_load_forge()
	if _vendor_panel != null and _vendor_panel.visible:   # a token buy changed our balance → refresh buttons
		_render_vendor()
	if _locker_panel != null and _locker_panel.visible:   # an equip/unequip changed the loadout
		_load_locker()
	if _build_shop_panel != null and _build_shop_panel.visible:   # a build_buy changed our furniture + credits
		_load_inventory()                             # reloads _inv_items → re-renders the catalog count via the _load_inventory hook
	if _lb_on:                                        # a build_buy/place/move/remove changed the palette → refresh it
		_lb_refresh_palette()

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

# the single choke point for quest/circuit/drill/cosmetic notifications. P4: fires a top-right toast
# AND keeps the chat-log append (scrollback history — the line already carries its own inline colors).
func _quest_toast(line: String) -> void:
	_toast(line, Palette.ACCENT)
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
	var p := Widgets.panel("Quest Journal", "J / Esc", 560.0, _toggle_questlog)
	_quest_panel = p["root"]
	_hud.add_child(_quest_panel)
	var vb: VBoxContainer = p["body"]
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
		if _locker_panel != null: _locker_panel.visible = false
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
	var out := ["[color=#7f93a8]Accept & turn in quests at the [color=#ffd24d]Quest Giver[/color] in the Home Base (press E near it).[/color]"]
	out.append(_secret_teaser())
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

# the gated-boss unlock teaser: quest-chain progress + Master Key status, without spoiling the specifics
# (the Camp panel already names the Final Lesson / Head Coach Arena, so this only tantalizes).
func _secret_teaser() -> String:
	var order: Array = Quests.order()
	var total := order.size()
	var ndone := 0
	for qid in order:
		if _quests.has(qid) and bool(_quests[qid].get("completed", false)):
			ndone += 1
	if total == 0:
		return ""
	if ndone >= total and _has_key():
		return "\n[color=#ffd24d]✦ The Final Lesson is open — seek what waits past the Head Coach Arena.[/color]"
	var key_txt: String = "[color=#9fe8a0]🔑 Master Key forged[/color]" if _has_key() else "[color=#7f93a8]🔑 forge the Master Key (Camp Circuit)[/color]"
	return "\n[color=#8a7fb0]✦ A hidden challenge stirs —[/color] [color=#cdbcff]%d/%d quests done[/color] · %s" % [ndone, total, key_txt]

func _reward_text(q: Dictionary) -> String:
	var rw: Dictionary = q.get("rewards", {})
	var parts := []
	if int(rw.get("xp", 0)) > 0:
		parts.append("[color=#9fe8a0]✦ %d XP[/color]" % int(rw["xp"]))
	if int(rw.get("credits", 0)) > 0:
		parts.append("[color=#ffd24d]◈ %d[/color]" % int(rw["credits"]))
	if rw.has("item"):
		var rar := str((rw["item"] as Dictionary).get("rarity", ""))
		parts.append("[color=%s]◆ %s item[/color]" % [RARITY_COLORS.get(rar, "#cfd6df"), rar])
	return "  ".join(parts)

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
	var p := Widgets.panel("📜 Quest Giver", "E / Esc", 560.0, _toggle_qgiver)
	_qgiver_panel = p["root"]
	_hud.add_child(_qgiver_panel)
	var vb: VBoxContainer = p["body"]
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
		if _locker_panel != null: _locker_panel.visible = false
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
	var p := Widgets.panel("Settings", "O / Esc", 400.0, _toggle_settings)
	_settings_panel = p["root"]
	_hud.add_child(_settings_panel)
	var vb: VBoxContainer = p["body"]
	vb.add_theme_constant_override("separation", 12)
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
	var rfx := CheckBox.new()                    # accessibility: shake/hitstop/FOV-punch are motion-sickness triggers
	rfx.text = "Reduce screen effects"
	rfx.tooltip_text = "Softens camera shake and turns off the hit camera-kick, zoom-punch and hitstop"
	rfx.button_pressed = reduce_fx
	rfx.toggled.connect(func(on: bool) -> void: set_reduce_fx(on))
	vb.add_child(rfx)
	var reset_ui := Button.new()                 # recover from a window dragged/resized off-screen
	reset_ui.text = "Reset UI Layout"
	reset_ui.tooltip_text = "Re-center every panel and clear saved window positions/sizes"
	reset_ui.pressed.connect(func() -> void:
		Widgets.reset_all_windows()
		_settings_status("UI layout reset"))
	vb.add_child(reset_ui)
	_settings_reset_note = Label.new()
	_settings_reset_note.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_settings_reset_note.add_theme_color_override("font_color", Palette.XP)
	vb.add_child(_settings_reset_note)
	var sep := HSeparator.new()
	vb.add_child(sep)
	var logout := Button.new()                   # log out → back to the login screen (no more quit-and-relaunch)
	logout.text = "Log Out"
	logout.pressed.connect(func() -> void: logout_requested.emit())
	vb.add_child(logout)

func _settings_status(msg: String) -> void:
	if _settings_reset_note != null:
		_settings_reset_note.text = msg

# a prominent full-screen notice when the connection drops — players kept missing the tiny top-left text and
# thought their character was just stuck. Mirrors the boss-ult overlay (dim ColorRect + centered content on _hud).
func _build_disconnect_overlay() -> void:
	_dc_overlay = ColorRect.new()
	_dc_overlay.color = Color(0.02, 0.03, 0.05, 0.82)          # dim the frozen game behind the notice
	_dc_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dc_overlay.mouse_filter = Control.MOUSE_FILTER_STOP        # swallow clicks to the dead session (only the button is live)
	_dc_overlay.z_index = 4096                                  # above even the z-4096 hover tooltip (tie broken by front-of-tree)
	_dc_overlay.visible = false
	_hud.add_child(_dc_overlay)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dc_overlay.add_child(center)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	center.add_child(vb)
	var title := Label.new()
	title.text = "Disconnected"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	title.add_theme_constant_override("outline_size", 12)
	vb.add_child(title)
	_dc_msg_label = Label.new()
	_dc_msg_label.text = "Lost connection to the server."
	_dc_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dc_msg_label.add_theme_font_size_override("font_size", 20)
	_dc_msg_label.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	vb.add_child(_dc_msg_label)
	var btn := Button.new()
	btn.text = "Return to Login"
	btn.custom_minimum_size = Vector2(220, 44)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func() -> void: logout_requested.emit())
	vb.add_child(btn)

func _set_vol(v: float, bus: String) -> void:
	AudioManager.set_volume(bus, v)

func _toggle_settings() -> void:
	if _settings_panel == null:
		return
	_settings_panel.visible = not _settings_panel.visible
	if _settings_panel.visible and _locker_panel != null:   # else it opens behind the opaque locker
		_locker_panel.visible = false

# ---- shop (home-zone economy: buy from a catalog, gamble a roll, sell inventory back) ----
func recv_shop_info(info: Dictionary) -> void:
	_shop_info = info

# Builder Mode (P3): the Build Shop catalog + caps + unlock cost, pushed on auth (mirrors recv_shop_info)
func recv_build_info(info: Dictionary) -> void:
	_build_info = info

func _build_shop() -> void:
	var p := Widgets.panel("Shop", "B / Esc", 1010.0, _toggle_shop)
	_shop_panel = p["root"]
	_hud.add_child(_shop_panel)
	var vb: VBoxContainer = p["body"]
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
		if _locker_panel != null: _locker_panel.visible = false
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

func _my_tokens() -> int:
	return int(_state.get("self", {}).get("tokens", 0))

# --- Practice Vendor (V at the home pad): spend Practice Tokens on the Rookie Camp set (reward loop) ---
func recv_vendor_info(info: Dictionary) -> void:
	_vendor_info = info

# P0 pattern-proof: the first panel migrated onto the Widgets scaffold + Palette tokens.
func _build_vendor() -> void:
	var p := Widgets.panel("◈ Practice Vendor — Rookie Camp Set", "V / Esc", 580.0, _toggle_vendor)
	_vendor_panel = p["root"]
	_hud.add_child(_vendor_panel)
	var vb: VBoxContainer = p["body"]
	_vendor_status = Widgets.status(Palette.TOKENS)
	vb.add_child(_vendor_status)
	vb.add_child(Widgets.hint("Earn Practice Tokens from Glitchyard kills + quest turn-ins. Equip 2 / 4 EPIC pieces for the set bonus (+END)."))
	_vendor_rows = VBoxContainer.new()
	_vendor_rows.add_theme_constant_override("separation", 6)
	vb.add_child(_vendor_rows)

func _toggle_vendor() -> void:
	if _vendor_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_vendor_panel.visible = not _vendor_panel.visible
	if _vendor_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_render_vendor()

func _render_vendor() -> void:
	if _vendor_panel == null or not _vendor_panel.visible or _vendor_rows == null:
		return
	_vendor_status.text = "Balance:  %d Practice Tokens" % _my_tokens()
	for c in _vendor_rows.get_children():
		c.queue_free()
	for it in (_vendor_info.get("catalog", []) as Array):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lbl := RichTextLabel.new()
		lbl.bbcode_enabled = true
		lbl.fit_content = true
		lbl.scroll_active = false
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.custom_minimum_size = Vector2(380, 0)
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		lbl.text = "[b][color=%s]%s[/color][/b]  [color=%s]%s[/color]   [color=%s]+%d %s[/color]" % [
			RARITY_COLORS.get("epic", "#cfd6df"), _esc(str(it.get("name", "?"))),
			Palette.hex(Palette.TEXT_FAINT), str(it.get("slot", "")),
			Palette.hex(Palette.XP), int(it.get("primary_amt", 0)), str(it.get("primary_stat", ""))]
		row.add_child(lbl)
		var price := int(it.get("price", 0))
		var btn := Button.new()
		btn.text = "Buy   %d Tokens" % price
		btn.disabled = _my_tokens() < price
		if not btn.disabled:
			btn.add_theme_color_override("font_color", Palette.TOKENS)
		btn.pressed.connect(_on_vendor_buy.bind(str(it.get("slot", ""))))
		row.add_child(btn)
		_vendor_rows.add_child(row)

func _on_vendor_buy(slot: String) -> void:
	if net != null:
		net.vendor_buy.rpc_id(1, slot)

# ---- Camp Circuit: the Intensity selector at the home entry portal + the clear notification ----
func _my_max_intensity() -> int:
	return maxi(1, int(_state.get("self", {}).get("max_intensity", 1)))
func _my_pages() -> int:
	return maxi(0, int(_state.get("self", {}).get("pages", 0)))
func _has_key() -> bool:
	return bool(_state.get("self", {}).get("has_key", false))
func _locker_unlocked() -> bool:                  # Builder Mode: do you own your Locker Room? (self-block flag)
	return bool(_state.get("self", {}).get("locker_unlocked", false))
func _key_cost() -> int:                          # authoritative Master Key cost from the server (no client drift)
	return maxi(1, int(_state.get("self", {}).get("key_cost", 300)))

func _camp_portal() -> Variant:                  # find the Camp ENTRY portal (only in home) by its label —
	if str(_state.get("map", "")) != "home":     # match "Circuit" so the instance's "◀ Leave Camp" exit never counts
		return null
	for p in (_state.get("portals", []) as Array):
		if str(p.get("label", "")).findn("circuit") >= 0:
			return p
	return null

func _build_camp() -> void:
	var p := Widgets.panel("⚔ Camp Circuit — Select Intensity", "C / Esc", 560.0, _toggle_camp)
	_camp_panel = p["root"]
	_hud.add_child(_camp_panel)
	var vb: VBoxContainer = p["body"]
	_camp_status = Widgets.status(Palette.ACCENT)
	vb.add_child(_camp_status)
	vb.add_child(Widgets.hint("Higher Intensity = tougher mobs but better loot (ilvl / rarity / drops) + more XP & credits. Clear the gatekeeper at your top tier to unlock the next."))
	_camp_rows = VBoxContainer.new()
	_camp_rows.add_theme_constant_override("separation", 6)
	vb.add_child(_camp_rows)

func _toggle_camp() -> void:
	if _camp_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_camp_panel.visible = not _camp_panel.visible
	if _camp_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_render_camp()

func _render_camp() -> void:
	if _camp_panel == null or not _camp_panel.visible or _camp_rows == null:
		return
	var mx := _my_max_intensity()
	_camp_status.text = "Highest unlocked:  Intensity %d" % mx
	for c in _camp_rows.get_children():
		c.queue_free()
	for tier in range(1, mx + 1):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var lbl := Label.new()
		var top := tier == mx
		lbl.text = "Intensity %d%s" % [tier, "   ◈ NEW — clear to advance" if top else ""]
		if top: lbl.add_theme_color_override("font_color", Color(0.62, 0.91, 0.63))
		lbl.custom_minimum_size = Vector2(360, 0)
		row.add_child(lbl)
		var btn := Button.new()
		btn.text = "Enter  I%d" % tier
		btn.pressed.connect(_on_enter_camp.bind(tier))
		row.add_child(btn)
		_camp_rows.add_child(row)
	# --- attunement (P2): Playbook Pages + the Master Key forge ---
	var sep := HSeparator.new()
	_camp_rows.add_child(sep)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	var plbl := Label.new()
	plbl.text = "◈ Playbook Pages:  %d / %d" % [_my_pages(), _key_cost()]
	plbl.add_theme_color_override("font_color", Color(0.31, 0.83, 1.0))
	plbl.custom_minimum_size = Vector2(360, 0)
	prow.add_child(plbl)
	if _has_key():
		var done := Label.new()
		done.text = "🔑 Master Key forged"
		done.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
		prow.add_child(done)
	else:
		var kbtn := Button.new()
		kbtn.text = "🔑 Forge Master Key"
		kbtn.disabled = _my_pages() < _key_cost()
		kbtn.pressed.connect(_on_craft_key)
		prow.add_child(kbtn)
	_camp_rows.add_child(prow)
	var khint := Label.new()
	khint.text = "The Master Key + every quest done opens the secret boss. Earn Pages from Circuit clears (more at higher Intensity) + the Head Coach."
	khint.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	khint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camp_rows.add_child(khint)

func _on_enter_camp(tier: int) -> void:
	if net != null:
		net.enter_camp.rpc_id(1, tier)
	if _camp_panel != null:
		_camp_panel.visible = false

func _on_craft_key() -> void:
	if net != null:
		net.craft_master_key.rpc_id(1)

# server → client: a Circuit run completed (bonus loot already granted server-side; announce + unlock)
func recv_circuit_clear(intensity: int, max_intensity: int) -> void:
	_quest_toast("[color=#ffd24d]⚔ Circuit Cleared — Intensity %d![/color]  Bonus loot + Pages awarded." % intensity)
	if max_intensity > intensity:
		_quest_toast("[color=#9fe8a0]★ Intensity %d unlocked![/color]" % max_intensity)
	if _camp_panel != null and _camp_panel.visible:
		_render_camp()                            # refresh the Pages counter live

# server → client: the Master Key was forged
func recv_key_crafted(ok: bool) -> void:
	if ok:
		_quest_toast("[color=#ffd24d]🔑 Master Key forged![/color]  The Final Lesson awaits past the Head Coach Arena.")
	if _camp_panel != null and _camp_panel.visible:
		_render_camp()

# ---- Wardrobe (P4 cosmetics): buy dyes with credits + equip them ----
func _my_cos_owned() -> Array:
	return (_state.get("self", {}).get("cos_owned", []) as Array)
func _my_cos_dye() -> String:
	return str(_state.get("self", {}).get("cos_dye", ""))
func _my_credits_val() -> int:
	return int(_state.get("self", {}).get("credits", _my_credits()))

func _build_wardrobe() -> void:
	var p := Widgets.panel("🎨 Wardrobe — Dyes", "G / Esc", 600.0, _toggle_wardrobe)
	_wardrobe_panel = p["root"]
	_hud.add_child(_wardrobe_panel)
	var vb: VBoxContainer = p["body"]
	_wardrobe_status = Widgets.status(Palette.ACCENT)
	vb.add_child(_wardrobe_status)
	vb.add_child(Widgets.hint("Cosmetic only — a colored wash on your character. Buy with credits (earned from kills / selling), then equip. Purely for style."))
	_wardrobe_rows = VBoxContainer.new()
	_wardrobe_rows.add_theme_constant_override("separation", 6)
	vb.add_child(_wardrobe_rows)

func _toggle_wardrobe() -> void:
	if _wardrobe_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_wardrobe_panel.visible = not _wardrobe_panel.visible
	if _wardrobe_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_render_wardrobe()

func _render_wardrobe() -> void:
	if _wardrobe_panel == null or not _wardrobe_panel.visible or _wardrobe_rows == null:
		return
	var owned := _my_cos_owned()
	var equipped := _my_cos_dye()
	_wardrobe_status.text = "Credits:  ◈ %d       Equipped:  %s" % [_my_credits_val(), (str(GameData.DYE_CATALOG.get(equipped, {}).get("name", "—")) if equipped != "" else "Default")]
	for c in _wardrobe_rows.get_children():
		c.queue_free()
	# a "Default (no dye)" row first
	_wardrobe_rows.add_child(_dye_row("", "Default (no dye)", "#8a8f98", owned, equipped))
	for id in GameData.DYE_IDS:
		var d: Dictionary = GameData.DYE_CATALOG[id]
		_wardrobe_rows.add_child(_dye_row(str(id), str(d["name"]), str(d["color"]), owned, equipped))

func _dye_row(id: String, dye_name: String, color_hex: String, owned: Array, equipped: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var swatch := ColorRect.new()
	swatch.color = Color(color_hex)
	swatch.custom_minimum_size = Vector2(26, 26)
	row.add_child(swatch)
	var lbl := Label.new()
	lbl.text = dye_name
	lbl.custom_minimum_size = Vector2(300, 0)
	row.add_child(lbl)
	if id == equipped:
		var eq := Label.new()
		eq.text = "✓ Equipped"
		eq.add_theme_color_override("font_color", Color(0.62, 0.91, 0.63))
		row.add_child(eq)
	elif id == "" or id in owned:
		var btn := Button.new()
		btn.text = "Equip"
		btn.pressed.connect(_on_equip_dye.bind(id))
		row.add_child(btn)
	else:
		var price := int(GameData.DYE_CATALOG[id]["price"])
		var btn := Button.new()
		btn.text = "Buy  ◈ %d" % price
		btn.disabled = _my_credits_val() < price
		btn.pressed.connect(_on_buy_dye.bind(id))
		row.add_child(btn)
	return row

func _on_buy_dye(id: String) -> void:
	if net != null:
		net.buy_cosmetic.rpc_id(1, id)

func _on_equip_dye(id: String) -> void:
	if net != null:
		net.equip_cosmetic.rpc_id(1, id)

func recv_cosmetics_changed(owned: Array, equipped: String) -> void:
	# write the authoritative pushed values into self so the panel is accurate NOW (the next snapshot also
	# carries them, but re-rendering from the ~30 Hz-old self block would show stale ownership for a frame).
	if _state.has("self"):
		_state["self"]["cos_owned"] = owned
		_state["self"]["cos_dye"] = equipped
	if _wardrobe_panel != null and _wardrobe_panel.visible:
		_render_wardrobe()
	_quest_toast("[color=#8ad6ff]🎨 Wardrobe updated.[/color]")

# ---- Leaderboards (P5) ----
const LB_CATS := [["drill", "Two-Minute Drill (wave)"], ["gear", "Gear Score"], ["intensity", "Camp Intensity"]]
func _build_leaderboard() -> void:
	var p := Widgets.panel("🏆 Leaderboards", "L / Esc", 560.0, _toggle_leaderboard)
	_lb_panel = p["root"]
	_hud.add_child(_lb_panel)
	var vb: VBoxContainer = p["body"]
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	vb.add_child(tabs)
	for cat in LB_CATS:
		var b := Button.new()
		b.text = str(cat[1])
		b.pressed.connect(_on_lb_category.bind(str(cat[0])))
		tabs.add_child(b)
	_lb_status = Label.new()
	_lb_status.add_theme_font_size_override("font_size", 15)
	_lb_status.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
	vb.add_child(_lb_status)
	_lb_rows = VBoxContainer.new()
	_lb_rows.add_theme_constant_override("separation", 3)
	vb.add_child(_lb_rows)

func _toggle_leaderboard() -> void:
	if _lb_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_lb_panel.visible = not _lb_panel.visible
	if _lb_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_on_lb_category(_lb_cat)                   # fetch the current tab on open

func _on_lb_category(cat: String) -> void:
	_lb_cat = cat
	if net != null:
		net.fetch_leaderboard.rpc_id(1, cat)      # server returns recv_leaderboard
	if _lb_status != null:
		_lb_status.text = "Loading %s…" % cat

func recv_leaderboard(category: String, entries: Array) -> void:
	if category != _lb_cat:
		return
	_lb_entries = entries
	_render_leaderboard()

func _render_leaderboard() -> void:
	if _lb_panel == null or not _lb_panel.visible or _lb_rows == null:
		return
	_lb_status.text = "Top %d — %s" % [_lb_entries.size(), _lb_cat]
	for c in _lb_rows.get_children():
		c.queue_free()
	if _lb_entries.is_empty():
		var none := Label.new()
		none.text = "No scores yet — be the first."
		none.add_theme_color_override("font_color", Color(0.5, 0.58, 0.66))
		_lb_rows.add_child(none)
		return
	var rank := 0
	for e in _lb_entries:
		rank += 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var rl := Label.new()
		rl.text = "%d." % rank
		rl.custom_minimum_size = Vector2(40, 0)
		if rank <= 3: rl.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
		row.add_child(rl)
		var nm := Label.new()
		nm.text = str((e as Dictionary).get("name", "?"))
		nm.custom_minimum_size = Vector2(340, 0)
		row.add_child(nm)
		var sc := Label.new()
		sc.text = str(int((e as Dictionary).get("score", 0)))
		sc.add_theme_color_override("font_color", Color(0.62, 0.91, 0.63))
		row.add_child(sc)
		_lb_rows.add_child(row)

func recv_drill_end(wave: int) -> void:
	_quest_toast("[color=#ffd24d]⏱ Two-Minute Drill — reached WAVE %d![/color]  Score submitted to the leaderboard." % wave)

# a big centered wave counter while inside the Drill (driven by the snapshot's drillWave)
func _update_drill_banner() -> void:
	if _drill_banner == null:
		_drill_banner = Label.new()
		_drill_banner.add_theme_font_size_override("font_size", 26)
		_drill_banner.modulate = Color(1.0, 0.7, 0.25)
		_drill_banner.visible = false
		_hud.add_child(_drill_banner)
	if _state.has("drillWave"):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_drill_banner.text = "⏱  TWO-MINUTE DRILL  ·  WAVE %d" % int(_state["drillWave"])
		_drill_banner.position = Vector2(vp.x / 2.0 - 200.0, 24.0)
		_drill_banner.visible = true
		if _zone_banner != null:                  # the drill banner already names the zone top-center —
			_zone_banner.visible = false          # suppress the redundant, overlapping zone chip
	else:
		_drill_banner.visible = false

func _update_camp_proximity() -> void:
	if _camp_hint == null:
		_camp_hint = Label.new()
		_camp_hint.add_theme_font_size_override("font_size", 18)
		_camp_hint.modulate = Color(1.0, 0.82, 0.3)
		_camp_hint.visible = false
		_hud.add_child(_camp_hint)
	var portal = _camp_portal()
	var pf = _find_fighter(_player_id)
	_near_camp = false
	if portal != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(portal["x"]), float(pf["y"]) - float(portal["y"])).length()
		_near_camp = d <= World.PORTAL_RADIUS + 24.0
	if _near_camp and (_camp_panel == null or not _camp_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_camp_hint.text = "Press [C] to run the Camp Circuit"
		_camp_hint.position = Vector2(vp.x / 2.0 - 130.0, vp.y - 200.0)
		_camp_hint.visible = true
	else:
		_camp_hint.visible = false
	if not _near_camp and _camp_panel != null and _camp_panel.visible:
		_camp_panel.visible = false                # walked away → close the selector

# human-readable description of a proc at a given tier (P6) — from GameData.PROC_CATALOG
func _proc_desc(proc_id: String, tier: int) -> String:
	var p: Dictionary = GameData.PROC_CATALOG.get(proc_id, {})
	if p.is_empty():
		return ""
	var amt: float = GameData.proc_amt(proc_id, tier)
	var trig: String = str(p.get("trigger", "")).replace("on_", "on ")
	var ch: float = float(p.get("chance", 1.0))
	if ch < 1.0:
		trig = "%d%% %s" % [int(round(ch * 100.0)), trig]   # e.g. "18% on hit"
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
	var p := Widgets.panel("Forge", "F / Esc", 680.0, _toggle_forge)
	_forge_panel = p["root"]
	_hud.add_child(_forge_panel)
	var vb: VBoxContainer = p["body"]
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
		if _locker_panel != null: _locker_panel.visible = false
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

# ---- Builder Mode (P3): the Build Shop pad + panel (buy furniture) + the locked-locker "Purchase" prompt ----
func _build_build_shop_panel() -> void:
	var p := Widgets.panel("Build Shop", "P / Esc", 560.0, _toggle_build_shop)
	_build_shop_panel = p["root"]
	_hud.add_child(_build_shop_panel)
	var vb: VBoxContainer = p["body"]
	_build_shop_status = Label.new()
	_build_shop_status.add_theme_font_size_override("font_size", 16)
	vb.add_child(_build_shop_status)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(524, 420)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(sc)
	_build_shop_grid = GridContainer.new()
	_build_shop_grid.columns = 2
	_build_shop_grid.add_theme_constant_override("h_separation", 6)
	_build_shop_grid.add_theme_constant_override("v_separation", 6)
	sc.add_child(_build_shop_grid)

func _toggle_build_shop() -> void:
	if _build_shop_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_build_shop_panel.visible = not _build_shop_panel.visible
	if _build_shop_panel.visible:
		if _shop_panel != null: _shop_panel.visible = false
		if _locker_panel != null: _locker_panel.visible = false
		_render_build_shop_catalog()
		_load_inventory()                            # populate _inv_items → an accurate "N/cap owned" count

func _render_build_shop_catalog() -> void:
	if _build_shop_grid == null:
		return
	if _tooltip != null: _tooltip.visible = false
	var cap := int(_build_info.get("owned_cap", 50))
	var model_cap := int(_build_info.get("model_cap", 20))
	var owned := 0                                    # total build items + a per-model tally (both from the inv cache)
	var by_model := {}
	for it in _inv_items:
		if str(it.get("category", "")) == "build":
			owned += 1
			var mm := str(it.get("model", ""))
			by_model[mm] = int(by_model.get(mm, 0)) + 1
	var full := owned >= cap
	if _build_shop_status != null:
		var fulltag := "   [color=#ff8a8a]· FULL[/color]" if full else ""
		_build_shop_status.text = "◈ %d credits    ·    %d/%d furniture owned%s" % [_my_credits(), owned, cap, fulltag]
	for ch in _build_shop_grid.get_children(): ch.queue_free()
	var cat: Array = _build_info.get("catalog", [])
	if cat.is_empty():
		_build_shop_grid.add_child(_hint_tile("Build Shop catalog unavailable"))
		return
	for e in cat:
		var model: String = str(e.get("model", ""))
		var tier: String = str(e.get("tier", ""))
		var price: int = int(e.get("price", 0))
		var mcount := int(by_model.get(model, 0))
		var at_model_cap := mcount >= model_cap
		var blocked := full or at_model_cap           # can't buy: total cap OR this model's per-model cap
		var afford: bool = _my_credits() >= price and not blocked
		var namecol := "#dfe6ef" if not blocked else "#77808c"   # dim the name when unbuyable
		var pcol := "#ffd24d" if afford else "#ff8a8a"
		var ccol := "#ff8a8a" if at_model_cap else "#7f8a99"     # per-model count turns red at the cap
		var captag := ""
		if full:
			captag = "   [color=#ff8a8a]· inventory full[/color]"
		elif at_model_cap:
			captag = "   [color=#ff8a8a]· MAX[/color]"
		var header := "[color=%s]%s[/color] [color=#7f8a99](%s)[/color]\n[color=%s]◈ %d[/color]   [color=%s]%d/%d[/color]%s" % \
			[namecol, _esc(model), tier, pcol, price, ccol, mcount, model_cap, captag]
		var border := Color.html("#8fb3d9") if not blocked else Color.html("#414b57")   # dimmed border when capped
		var m := model
		var pr := price
		var mmax := at_model_cap
		var mcap := model_cap
		_build_shop_grid.add_child(_grid_tile(border, header, null, [], null,
			func() -> void:
				if full:
					_toast("[color=#ff8a8a]Build inventory full — %d/%d owned. Remove or sell some first.[/color]" % [owned, cap], Color.html("#ff8a8a"))
				elif mmax:
					_toast("[color=#ff8a8a]You already own the max (%d) of %s[/color]" % [mcap, _esc(m)], Color.html("#ff8a8a"))
				elif _my_credits() < pr:
					_toast("[color=#ff8a8a]Not enough credits for %s (◈%d)[/color]" % [_esc(m), pr], Color.html("#ff8a8a"))
				elif net != null and _connected:
					net.build_buy.rpc_id(1, m)))

func _render_build_shop_pad() -> void:
	var pad = _state.get("build_shop")
	var sig := JSON.stringify(pad)
	if sig == _build_shop_sig:
		return
	_build_shop_sig = sig
	if _build_shop_root != null:
		_build_shop_root.queue_free()
		_build_shop_root = null
	if pad == null or _world_root == null:
		return
	_build_shop_root = Node3D.new()
	_world_root.add_child(_build_shop_root)
	var pos := Vector3((float(pad["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(pad["y"]) - _ah() / 2.0) * SCALE)
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = World.BUILD_SHOP_RADIUS * SCALE * 0.5
	cyl.bottom_radius = World.BUILD_SHOP_RADIUS * SCALE * 0.6
	cyl.height = 2.6
	pillar.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.72, 0.95, 0.32)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.42, 0.66, 0.95)
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.material_override = mat
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pillar.position = pos + Vector3(0.0, 1.3, 0.0)
	_build_shop_root.add_child(pillar)
	var lbl := Label3D.new()
	lbl.text = "🔨 Build Shop"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0016
	lbl.font_size = 52
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = Color(0.7, 0.85, 1.0)
	lbl.position = pos + Vector3(0.0, 3.4, 0.0)
	_build_shop_root.add_child(lbl)

func _update_build_shop_proximity() -> void:
	if _build_shop_hint == null:
		_build_shop_hint = Label.new()
		_build_shop_hint.add_theme_font_size_override("font_size", 18)
		_build_shop_hint.modulate = Color(0.7, 0.85, 1.0)
		_build_shop_hint.visible = false
		_hud.add_child(_build_shop_hint)
	var pad = _state.get("build_shop")
	var pf = _find_fighter(_player_id)
	_near_build_shop = false
	if pad != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(pad["x"]), float(pf["y"]) - float(pad["y"])).length()
		_near_build_shop = d <= World.BUILD_SHOP_RADIUS
	if _near_build_shop and (_build_shop_panel == null or not _build_shop_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_build_shop_hint.text = "Press [P] to shop for furniture"
		_build_shop_hint.position = Vector2(vp.x / 2.0 - 110.0, vp.y - 178.0)
		_build_shop_hint.visible = true
	else:
		_build_shop_hint.visible = false
	if not _near_build_shop and _build_shop_panel != null and _build_shop_panel.visible:
		_build_shop_panel.visible = false            # walked away → close

# the Locker Room portal, when you don't own it yet, shows a "press [Y] to Purchase" prompt (buy_locker_room).
# Once unlocked, walking onto the pad auto-enters (server-side), so this prompt just disappears.
func _update_locker_portal_proximity() -> void:
	if _locker_portal_hint == null:
		_locker_portal_hint = Label.new()
		_locker_portal_hint.add_theme_font_size_override("font_size", 18)
		_locker_portal_hint.modulate = Color(1.0, 0.85, 0.45)
		_locker_portal_hint.visible = false
		_hud.add_child(_locker_portal_hint)
	var pad = _state.get("locker_portal")
	var pf = _find_fighter(_player_id)
	_near_locker_portal = false
	if pad != null and pf != null and not _locker_unlocked():
		var d := Vector2(float(pf["x"]) - float(pad["x"]), float(pf["y"]) - float(pad["y"])).length()
		_near_locker_portal = d <= World.PORTAL_RADIUS + 26.0
	if _near_locker_portal:
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		var cost := int(_build_info.get("unlock_cost", 10000))
		_locker_portal_hint.text = "🔒 Your Locker Room — press [Y] to Purchase (◈ %d)" % cost
		_locker_portal_hint.position = Vector2(vp.x / 2.0 - 180.0, vp.y - 206.0)
		_locker_portal_hint.visible = true
	else:
		_locker_portal_hint.visible = false

func _buy_locker_room() -> void:
	if _locker_unlocked():
		return
	if _my_credits() < int(_build_info.get("unlock_cost", 10000)):
		_toast("[color=#ff8a8a]Not enough credits to unlock your Locker Room[/color]", Color.html("#ff8a8a"))
		return
	if net != null and _connected:
		net.buy_locker_room.rpc_id(1)

# one informational Build-inventory tile: the model name + a "placed" badge. Placement itself is P3b.
func _build_item_tile(it: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(144, 44)
	b.clip_text = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_NONE
	var placed := bool(it.get("placed", false))
	var col := Color.html("#9fe8a0") if placed else Color.html("#cfd6df")
	b.text = ("✔ " if placed else "") + str(it.get("model", it.get("name", "?")))
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", col.lightened(0.2))
	b.tooltip_text = str(it.get("model", "?")) + ("  · placed in your Locker Room" if placed else "  · in your Build tab (place it in your Locker Room)")
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.16, 0.92)
	sb.set_border_width_all(2)
	sb.border_color = col
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(7)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	return b

# ---- Builder Mode P3b: the Locker Room build editor (F4 in your own unlocked room) ----------------------------
# Reuses the F4-decorator feel (cursor place / grab-move / rotate / lift), but every action is a SERVER RPC
# (build_place/move/remove) and the room renders from the server's snapshot decals — the client never touches
# local JSON here and never trusts its own coords (the server clamps). F4 routes here (not the admin decorator)
# only when _locker_build_available() — i.e. you're standing in your own unlocked locker_room instance.
func _locker_build_available() -> bool:
	return str(_state.get("map", "")) == World.LOCKER and _locker_unlocked()

# the WORLD/map decorator (F4 outside your Locker Room) is GAME-MASTER ONLY on the live server (recv_admin, gated
# by the service-role admins table). Non-admins pressing F4 in the world get nothing; their Locker Room build
# editor still works (that's _locker_build_available, above). Overrides Client._world_build_allowed().
func _world_build_allowed() -> bool:
	return _is_admin

func _locker_build_toggle() -> void:
	if _lb_on:
		_lb_set_on(false)
		return
	if not _locker_build_available():
		return
	_lb_set_on(true)

func _lb_set_on(on: bool) -> void:
	_lb_on = on
	_lb_grab_id = ""
	_lb_grab_model = ""
	_lb_grab_from = {}
	_lb_undo.clear()
	_lb_del_id = ""
	if is_instance_valid(_lb_del_ghost):
		_lb_del_ghost.queue_free()
	_lb_del_ghost = null
	_lb_free_del_menu()
	if _lb_lbl == null and _hud != null:
		_lb_lbl = Label.new()
		_lb_lbl.add_theme_font_size_override("font_size", 14)
		_lb_lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		_lb_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_lb_lbl.add_theme_constant_override("outline_size", 4)
		_pin_topright(_lb_lbl, 44.0)
		_lb_lbl.z_index = 4096
		_lb_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hud.add_child(_lb_lbl)
	if _lb_lbl != null:
		_lb_lbl.visible = on
	if not on:
		if is_instance_valid(_lb_ghost):
			_lb_ghost.queue_free()
		_lb_ghost = null
		_lb_ghost_key = ""
		return
	if not _coords_on:
		_toggle_coords()                            # the coord readout pairs naturally with placing
	_lb_refresh_palette()
	_toast("[color=#9fe8a0]🔨 Build mode[/color]\n[color=#cfd6df]LMB place · [ ] pick · , . rotate · - = size · PgUp/Dn lift · G grab/move · X remove · F4 exit[/color]", Palette.ACCENT)

# the editor's input (only reached, via Client._input → _extra_input, while _lb_on). Mirrors _deco_input but RPC-driven.
func _extra_input(e: InputEvent) -> bool:
	if not _lb_on:
		return false
	var foc := get_viewport().gui_get_focus_owner()
	if foc is LineEdit or foc is TextEdit:
		return false                                # typing (chat) — don't steal keys
	return _lb_input(e)

func _lb_input(e: InputEvent) -> bool:
	# while confirming a delete, let mouse clicks fall through to the on-screen menu buttons (don't place)
	if _lb_del_id != "" and e is InputEventMouseButton:
		return false
	if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		if _lb_grab_id != "":                       # dropping a grabbed prop → move it here
			_lb_drop_move()
		else:                                       # place the selected palette item at the cursor
			_lb_place()
		return true
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_F4:
				_locker_build_toggle()
				return true
			KEY_Z:                                  # undo the last place / move / remove
				if e.ctrl_pressed:
					_lb_undo_last()
					return true
			KEY_G:                                  # grab the nearest placed prop (or drop the held one)
				if _lb_grab_id != "":
					_lb_drop_move()
				else:
					_lb_do_grab()
				return true
			KEY_X:                                  # target the nearest prop for deletion (press again → cycle to another)
				_lb_retarget_delete()
				return true
			KEY_Y:                                  # confirm the pending delete
				if _lb_del_id != "":
					_lb_confirm_delete()
					return true
			KEY_N:                                  # cancel the pending delete
				if _lb_del_id != "":
					_lb_del_id = ""
					_lb_update_lbl()
					return true
			KEY_BRACKETLEFT:
				if not _lb_pal.is_empty():
					_lb_idx = (_lb_idx - 1 + _lb_pal.size()) % _lb_pal.size()
					_lb_update_lbl()
				return true
			KEY_BRACKETRIGHT:
				if not _lb_pal.is_empty():
					_lb_idx = (_lb_idx + 1) % _lb_pal.size()
					_lb_update_lbl()
				return true
			KEY_COMMA:
				_lb_yaw -= 0.2618                   # ~15°
				_lb_update_lbl()
				return true
			KEY_PERIOD:
				_lb_yaw += 0.2618
				_lb_update_lbl()
				return true
			KEY_MINUS:
				_lb_h = clampf(_lb_h / 1.15, 0.4, 15.0)   # multiplicative → smooth across the wide 0.4–15 range
				_lb_update_lbl()
				return true
			KEY_EQUAL:
				_lb_h = clampf(_lb_h * 1.15, 0.4, 15.0)
				_lb_update_lbl()
				return true
			KEY_PAGEUP:
				_lb_oy = clampf(_lb_oy + 0.25, -1.0, 8.0)
				_lb_update_lbl()
				return true
			KEY_PAGEDOWN:
				_lb_oy = clampf(_lb_oy - 0.25, -1.0, 8.0)
				_lb_update_lbl()
				return true
	return false

# the placement transform the server will clamp (never trusted). Snapped like the admin decorator.
func _lb_xform() -> Dictionary:
	var p := _cursor_sim()
	return {"x": snappedf(p.x, 1.0), "y": snappedf(p.y, 1.0), "h": snappedf(_lb_h, 0.1),
		"yaw": snappedf(_lb_yaw, 0.01), "oy": snappedf(_lb_oy, 0.01)}

# the id of the nearest PLACED prop to EITHER the cursor OR the player's character (whichever is closer), or "" if
# none within range. The cursor raycast hits the GROUND, so aiming at a tall prop lands past its base — checking
# the character position too means "stand on/next to it and press X/G" reliably works. Used by G (grab) + X (remove).
func _lb_nearest_placed(exclude := "") -> String:
	var pts := []
	var cur := _cursor_sim()
	if cur.x >= 0.0:
		pts.append(cur)
	var pf = _find_fighter(_player_id)
	if pf != null:
		pts.append(Vector2(float(pf["x"]), float(pf["y"])))
	if pts.is_empty():
		return ""
	var best := ""
	var best_d := 110.0                             # pick radius (sim units) — generous; nearest to cursor OR character
	for d in (_state.get("decals", []) as Array):
		if not (d is Dictionary) or str(d.get("kind", "")) != "prop":
			continue
		var id := str(d.get("id", ""))
		if id == "" or id == exclude:               # exclude → X / "Pick another" cycles to a DIFFERENT prop
			continue
		var dp := Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		var dist := INF
		for p in pts:
			dist = minf(dist, (dp - p).length())
		if dist < best_d:
			best_d = dist
			best = id
	return best

# a placed decal (has the owner's item id) by id, or {} if not found.
func _lb_decal_by_id(id: String) -> Dictionary:
	for d in (_state.get("decals", []) as Array):
		if d is Dictionary and str(d.get("id", "")) == id:
			return d
	return {}

func _lb_decal_xform(d: Dictionary) -> Dictionary:
	return {"x": float(d.get("x", 0.0)), "y": float(d.get("y", 0.0)), "h": float(d.get("h", 2.0)),
		"yaw": float(d.get("yaw", 0.0)), "oy": float(d.get("oy", 0.0))}

# place the selected palette item at the cursor (server clamps + is authoritative). Records a reverse-op for undo.
func _lb_place() -> void:
	_lb_del_id = ""                                 # any other action cancels a pending delete-confirm
	if _lb_pal.is_empty():
		_toast("[color=#ff8a8a]No furniture to place — buy some at the Build Shop [P][/color]", Color.html("#ff8a8a"))
		return
	if net == null or not _connected:
		return
	var id := str((_lb_pal[_lb_idx] as Dictionary).get("id", ""))
	if id == "":
		return
	net.build_place.rpc_id(1, id, _lb_xform())
	_lb_push_undo({"act": "remove", "id": id})      # undo a place → remove it

# grab the nearest placed prop to move it: adopt its size/rotation/lift so the ghost shows it faithfully and the
# move preserves them (unless you then adjust), and remember its old spot for undo.
func _lb_do_grab() -> void:
	_lb_del_id = ""                                 # cancel any pending delete-confirm
	var gid := _lb_nearest_placed()
	if gid == "":
		_toast("[color=#ff8a8a]No placed prop nearby to grab — stand near it or aim at its base[/color]", Color.html("#ff8a8a"))
		return
	var d := _lb_decal_by_id(gid)
	_lb_grab_id = gid
	_lb_grab_model = str(d.get("model", ""))
	_lb_grab_from = _lb_decal_xform(d)
	_lb_h = float(d.get("h", _lb_h))
	_lb_yaw = float(d.get("yaw", _lb_yaw))
	_lb_oy = float(d.get("oy", _lb_oy))
	_lb_update_lbl()

# drop the grabbed prop at the cursor → move RPC + record the move for undo.
func _lb_drop_move() -> void:
	if _lb_grab_id == "":
		return
	if net != null and _connected:
		net.build_move.rpc_id(1, _lb_grab_id, _lb_xform())
		if not _lb_grab_from.is_empty():
			_lb_push_undo({"act": "move", "id": _lb_grab_id, "xform": _lb_grab_from.duplicate()})
	_lb_grab_id = ""
	_lb_grab_model = ""
	_lb_grab_from = {}
	_lb_update_lbl()

func _lb_push_undo(op: Dictionary) -> void:
	_lb_undo.append(op)
	if _lb_undo.size() > 40:
		_lb_undo.pop_front()

# undo the last edit: place→remove, remove→place-back, move→move-back. Server-authoritative (fires the inverse RPC).
func _lb_undo_last() -> void:
	_lb_del_id = ""                                 # cancel any pending delete-confirm
	if _lb_undo.is_empty():
		_toast("[color=#cfd6df]Nothing to undo[/color]", Palette.TEXT_DIM)
		return
	if net == null or not _connected:
		return
	var op: Dictionary = _lb_undo.pop_back()
	var id := str(op.get("id", ""))
	match str(op.get("act", "")):
		"remove":
			net.build_remove.rpc_id(1, id)
		"place":
			net.build_place.rpc_id(1, id, op.get("xform", {}))
		"move":
			net.build_move.rpc_id(1, id, op.get("xform", {}))
	_lb_grab_id = ""
	_lb_grab_model = ""
	_lb_grab_from = {}
	_toast("[color=#9fe8a0]↩ Undo[/color]", Palette.ACCENT)
	_lb_update_lbl()

# confirm the pending [Y]/[N] delete → remove the highlighted prop (recording it for undo).
func _lb_confirm_delete() -> void:
	if _lb_del_id == "":
		return
	var rd := _lb_decal_by_id(_lb_del_id)
	if net != null and _connected and not rd.is_empty():
		net.build_remove.rpc_id(1, _lb_del_id)
		_lb_push_undo({"act": "place", "id": _lb_del_id, "xform": _lb_decal_xform(rd)})
	_lb_del_id = ""
	_lb_update_lbl()

# target the nearest prop for deletion; called again (X or the "Pick another" button) it EXCLUDES the current
# target so it cycles to a different nearby prop.
func _lb_retarget_delete() -> void:
	var rid := _lb_nearest_placed(_lb_del_id)
	if rid != "":
		_lb_del_id = rid
	elif _lb_del_id == "":
		_toast("[color=#ff8a8a]No placed prop nearby — stand near it or aim at its base[/color]", Color.html("#ff8a8a"))
	# else: no OTHER prop nearby → keep the current target
	_lb_update_lbl()

func _lb_free_del_menu() -> void:
	if _lb_del_panel != null:
		_lb_del_panel.queue_free()
	_lb_del_panel = null
	_lb_del_panel_model = ""

# a centered "Delete this <model>?" menu with clickable buttons (Y/N/X keys still work too). Rebuilt when the
# targeted model changes; freed when the confirm ends. Reconciled with _lb_del_id each frame in _lb_update_del_highlight.
func _lb_build_del_menu(model: String) -> void:
	_lb_free_del_menu()
	if _hud == null:
		return
	_lb_del_panel_model = model
	_lb_del_panel = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.BG_PANEL
	sb.border_color = Palette.DANGER
	for s in ["left", "right", "top", "bottom"]:
		sb.set("border_width_" + s, 2)
		sb.set("corner_radius_" + s, 8)
		sb.set("content_margin_" + s, 18.0)
	_lb_del_panel.add_theme_stylebox_override("panel", sb)
	_lb_del_panel.mouse_filter = Control.MOUSE_FILTER_STOP   # absorb clicks over the menu chrome (don't leak to the game)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	_lb_del_panel.add_child(vb)
	var title := Label.new()
	title.text = "🗑  Delete this %s?" % model
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Palette.DANGER)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "It goes back to your Build tab · Ctrl+Z undoes it"
	sub.add_theme_color_override("font_color", Palette.TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	row.add_child(_tile_btn("🗑  Delete  (Y)", Palette.DANGER, true, _lb_confirm_delete))
	row.add_child(_tile_btn("Keep  (N)", Palette.TEXT, true, func() -> void: _lb_del_id = ""))
	row.add_child(_tile_btn("Pick another  (X)", Palette.ACCENT2, true, _lb_retarget_delete))
	_hud.add_child(_lb_del_panel)
	_lb_del_panel.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_lb_del_panel.position = Vector2((vp.x - _lb_del_panel.size.x) / 2.0, vp.y * 0.60 - _lb_del_panel.size.y / 2.0)

# ---- Locker Room onboarding: a "how to build" popup, auto-shown on entry (unless the player opts out) + [H] ----
func _load_build_help_pref() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(AudioManager.SETTINGS_PATH) == OK:
		_build_help_hide = bool(cfg.get_value("build", "hide_help", false))

func _set_build_help_hide(on: bool) -> void:
	_build_help_hide = on
	var cfg := ConfigFile.new()
	cfg.load(AudioManager.SETTINGS_PATH)          # keep the existing audio/fx sections
	cfg.set_value("build", "hide_help", on)
	cfg.save(AudioManager.SETTINGS_PATH)

# called on the map-change INTO the locker: auto-open the help unless the player checked "don't show".
func _on_enter_locker() -> void:
	_load_build_help_pref()
	if not _build_help_hide:
		_show_build_help()

func _close_build_help() -> void:
	if _build_help_panel != null:
		_build_help_panel.queue_free()
	_build_help_panel = null

func _toggle_build_help() -> void:
	if _build_help_panel != null:
		_close_build_help()
	else:
		_show_build_help()

func _show_build_help() -> void:
	_close_build_help()
	if _hud == null:
		return
	_build_help_panel = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Palette.BG_PANEL
	sb.border_color = Palette.ACCENT
	for s in ["left", "right", "top", "bottom"]:
		sb.set("border_width_" + s, 2)
		sb.set("corner_radius_" + s, 10)
		sb.set("content_margin_" + s, 22.0)
	_build_help_panel.add_theme_stylebox_override("panel", sb)
	_build_help_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_build_help_panel.add_child(vb)
	var title := Label.new()
	title.text = "🔨  Welcome to your Locker Room"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	vb.add_child(title)
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.custom_minimum_size = Vector2(540, 0)
	body.add_theme_color_override("default_color", Palette.TEXT)
	body.text = "This is your own [b]private space[/b] — decorate it however you like.\n\n" + \
		"[color=#ffd24d]How it works[/color]\n" + \
		"[b]1.[/b]  Buy furniture at the [color=#8ad6ff]Build Shop[/color] pad ([color=#ffd24d]P[/color]) back in the Home Base.\n" + \
		"[b]2.[/b]  Return here and press [color=#ffd24d]F4[/color] to enter [b]Build Mode[/b].\n" + \
		"[b]3.[/b]  While in Build Mode:\n" + \
		"       [color=#ffd24d][lb] [rb][/color] pick item    [color=#ffd24d]Left-click[/color] place    [color=#ffd24d]G[/color] grab / move    [color=#ffd24d]X[/color] remove\n" + \
		"       [color=#ffd24d], .[/color] rotate    [color=#ffd24d]- =[/color] resize    [color=#ffd24d]PgUp / PgDn[/color] lift    [color=#ffd24d]Ctrl+Z[/color] undo\n" + \
		"       [color=#ffd24d]F4[/color] leave Build Mode\n\n" + \
		"Removing a placed item sends it back to your Build tab. Your layout [b]saves automatically[/b]. Have fun!"
	vb.add_child(body)
	var cb := CheckBox.new()
	cb.text = "Don't show this automatically when I enter"
	cb.button_pressed = _build_help_hide
	cb.toggled.connect(func(on: bool) -> void: _set_build_help_hide(on))
	vb.add_child(cb)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	row.add_child(_tile_btn("Got it!", Palette.ACCENT, true, _close_build_help))
	var foot := Label.new()
	foot.text = "Press  [ H ]  anytime in your Locker Room to reopen this help."
	foot.add_theme_color_override("font_color", Palette.TEXT_DIM)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(foot)
	_hud.add_child(_build_help_panel)
	_build_help_panel.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_build_help_panel.position = Vector2((vp.x - _build_help_panel.size.x) / 2.0, (vp.y - _build_help_panel.size.y) / 2.0)

# the always-visible "[H] build help" reminder — shown while in the locker, but not while the help/build UI is up.
func _update_locker_help_hint() -> void:
	var in_locker := str(_state.get("map", "")) == World.LOCKER
	if not in_locker and _build_help_panel != null:   # left the locker with the help open → close it
		_close_build_help()
	if _build_help_hint == null:
		if not in_locker:
			return
		_build_help_hint = Label.new()
		_build_help_hint.add_theme_font_size_override("font_size", 14)
		_build_help_hint.add_theme_color_override("font_color", Palette.ACCENT)
		_build_help_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_build_help_hint.add_theme_constant_override("outline_size", 4)
		_build_help_hint.anchor_left = 0.5
		_build_help_hint.anchor_right = 0.5
		_build_help_hint.offset_left = -160.0
		_build_help_hint.offset_right = 160.0
		_build_help_hint.offset_top = 86.0            # just under the "LOCKER ROOM" zone banner
		_build_help_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_build_help_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_build_help_hint.z_index = 4096
		_build_help_hint.text = "🔨 Press  [ H ]  for build help"
		_hud.add_child(_build_help_hint)
	_build_help_hint.visible = in_locker and not _lb_on and _build_help_panel == null

# rebuild the palette (your OWNED UNPLACED build items) from the inventory cache. If the cache is empty, pull it.
func _lb_refresh_palette() -> void:
	if supa != null:                                # always pull fresh: a place/move/remove/buy just changed placed-state
		var r = await supa.get_inventory()
		if r.get("ok"):
			_inv_items = r.get("items", [])
	var pal := []
	for it in _inv_items:
		if str((it as Dictionary).get("category", "")) == "build" and not bool((it as Dictionary).get("placed", false)):
			pal.append({"id": str((it as Dictionary).get("id", "")), "model": str((it as Dictionary).get("model", ""))})
	pal.sort_custom(func(a, b): return str(a["model"]) < str(b["model"]))
	_lb_pal = pal
	if _lb_idx >= _lb_pal.size():
		_lb_idx = maxi(0, _lb_pal.size() - 1)
	_lb_update_lbl()

func _lb_update_lbl() -> void:
	if _lb_lbl == null:
		return
	if _lb_del_id != "":                            # a delete is pending confirmation → red prompt (see the red highlight)
		var dm := str(_lb_decal_by_id(_lb_del_id).get("model", "prop"))
		_lb_lbl.add_theme_color_override("font_color", Color(1.0, 0.6, 0.6))
		_lb_lbl.text = "⚠ DELETE  %s ?  (highlighted red)\n  [Y] yes, remove it   ·   [N] no, keep it   ·   [X] target a different prop   ·   F4 exit" % dm
		return
	_lb_lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))   # normal green
	# ALWAYS show the controls (even with no furniture) so the player never loses the reference.
	if _lb_grab_id != "":                           # moving: name the prop prominently so it's clear what will move
		var gm := _lb_grab_model if _lb_grab_model != "" else "prop"
		_lb_lbl.text = "🔨 BUILD — ▶ MOVING  %s ◀    yaw %.0f°  size %.1f  lift %.1f\n  the preview follows your cursor · , . rotate · - = size · PgUp/Dn lift · click or G to drop it here · Ctrl+Z undo · F4 exit" % [gm, rad_to_deg(_lb_yaw), _lb_h, _lb_oy]
		return
	var sel := "(none — buy at the Build Shop [P])"
	if not _lb_pal.is_empty():
		sel = "[ ] %s  (%d/%d)" % [str((_lb_pal[_lb_idx] as Dictionary).get("model", "?")), _lb_idx + 1, _lb_pal.size()]
	_lb_lbl.text = "🔨 BUILD    %s    yaw %.0f°  size %.1f  lift %.1f\n  L-click place · G grab/move · X remove · Ctrl+Z undo · , . rotate · - = size · PgUp/Dn lift · F4 exit" % [sel, rad_to_deg(_lb_yaw), _lb_h, _lb_oy]

# per-frame preview at the cursor: the to-place palette prop, OR — while moving — the grabbed prop itself (so you
# see its height/rotation follow the cursor before you drop it). The original placed copy still renders (server
# authority) until the move lands, so there's a brief overlap; that's expected.
func _lb_update_ghost() -> void:
	var model := ""
	if _lb_on and _world_root != null and _lb_del_id == "":   # while confirming a delete, hide the place-preview
		if _lb_grab_id != "":
			model = _lb_grab_model
		elif not _lb_pal.is_empty():
			model = str((_lb_pal[_lb_idx] as Dictionary).get("model", ""))
	if model == "":
		if is_instance_valid(_lb_ghost):
			_lb_ghost.visible = false
		return
	var key := "%s@%.1f" % [model, _lb_h]
	if key != _lb_ghost_key or not is_instance_valid(_lb_ghost):   # model/size changed OR the ghost was freed → rebuild
		if is_instance_valid(_lb_ghost):
			_lb_ghost.queue_free()
		_lb_ghost = null
		_lb_ghost_key = key
		var pe := _prop_entry(model)
		if pe["scene"] != null:
			_lb_ghost = pe["scene"].instantiate()
			var psc: float = _lb_h / float(pe["h"])
			_lb_ghost.scale = Vector3(psc, psc, psc)
			_ghost_tint(_lb_ghost)
			_world_root.add_child(_lb_ghost)
	if not is_instance_valid(_lb_ghost):
		return
	var p := _cursor_sim()
	if p.x < 0.0:
		_lb_ghost.visible = false
		return
	_lb_ghost.visible = true
	var pe2 := _prop_entry(model)
	var psc2: float = _lb_h / float(pe2["h"])
	_lb_ghost.position = Vector3((p.x - _aw() / 2.0) * SCALE, -float(pe2["min_y"]) * psc2 + _lb_oy, (p.y - _ah() / 2.0) * SCALE)
	_lb_ghost.rotation.y = _lb_yaw

# make a ghost instance look like a translucent preview (recursively tint every mesh).
func _ghost_tint(n: Node) -> void:
	if n is MeshInstance3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.6, 0.9, 0.7, 0.45)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		(n as MeshInstance3D).material_override = m
	for c in n.get_children():
		_ghost_tint(c)

# a RED translucent tint for the prop about to be deleted (recursively).
func _del_tint(n: Node) -> void:
	if n is MeshInstance3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.28, 0.28, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		(n as MeshInstance3D).material_override = m
	for c in n.get_children():
		_del_tint(c)

# per-frame: while a delete is pending, overlay a RED pulsing highlight on the exact prop you're about to remove
# (so you can see it's the right one before pressing Y). If the target vanishes, cancel the confirm.
func _lb_update_del_highlight() -> void:
	if not _lb_on or _lb_del_id == "" or _world_root == null:
		if is_instance_valid(_lb_del_ghost):
			_lb_del_ghost.queue_free()
		_lb_del_ghost = null
		_lb_free_del_menu()
		return
	var d := _lb_decal_by_id(_lb_del_id)
	if d.is_empty():                                # target removed/moved out from under us → cancel the confirm
		_lb_del_id = ""
		if is_instance_valid(_lb_del_ghost):
			_lb_del_ghost.queue_free()
		_lb_del_ghost = null
		_lb_free_del_menu()
		_lb_update_lbl()
		return
	var model := str(d.get("model", ""))
	var h := float(d.get("h", 2.0))
	if _lb_del_panel == null or _lb_del_panel_model != model:   # target MODEL changed → rebuild the menu + the red ghost
		_lb_build_del_menu(model)
		if is_instance_valid(_lb_del_ghost):
			_lb_del_ghost.queue_free()
		_lb_del_ghost = null
	if not is_instance_valid(_lb_del_ghost):
		var pe := _prop_entry(model)
		if pe["scene"] != null:
			_lb_del_ghost = pe["scene"].instantiate()
			_del_tint(_lb_del_ghost)
			_world_root.add_child(_lb_del_ghost)
	if not is_instance_valid(_lb_del_ghost):
		return
	var pe2 := _prop_entry(model)
	var psc: float = h / float(pe2["h"]) * (1.04 + 0.05 * sin(float(Time.get_ticks_msec()) * 0.009))   # gentle pulse
	_lb_del_ghost.scale = Vector3(psc, psc, psc)
	_lb_del_ghost.position = Vector3((float(d.get("x", 0.0)) - _aw() / 2.0) * SCALE, -float(pe2["min_y"]) * psc + float(d.get("oy", 0.0)), (float(d.get("y", 0.0)) - _ah() / 2.0) * SCALE)
	_lb_del_ghost.rotation.y = float(d.get("yaw", 0.0))

# the Practice Vendor pad in the home base + the "press V" prompt (mirrors the shop pad, cyan)
func _render_vendor_pad() -> void:
	var v = _state.get("practice")
	var sig := JSON.stringify(v)
	if sig == _vendor_sig:
		return
	_vendor_sig = sig
	if _vendor_root != null:
		_vendor_root.queue_free()
		_vendor_root = null
	if v == null or _world_root == null:
		return
	_vendor_root = Node3D.new()
	_world_root.add_child(_vendor_root)
	var pos := Vector3((float(v["x"]) - _aw() / 2.0) * SCALE, 0.0, (float(v["y"]) - _ah() / 2.0) * SCALE)
	var pillar := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = World.PRACTICE_RADIUS * SCALE * 0.5
	cyl.bottom_radius = World.PRACTICE_RADIUS * SCALE * 0.6
	cyl.height = 2.6
	pillar.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.85, 1.0, 0.34)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.82, 1.0)
	mat.emission_energy_multiplier = 1.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar.material_override = mat
	pillar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pillar.position = pos + Vector3(0.0, 1.3, 0.0)
	_vendor_root.add_child(pillar)
	var lbl := Label3D.new()
	lbl.text = "◈ Practice Vendor"
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = 0.0016
	lbl.font_size = 52
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.modulate = Color(0.5, 0.9, 1.0)
	lbl.position = pos + Vector3(0.0, 3.4, 0.0)
	_vendor_root.add_child(lbl)

func _update_vendor_proximity() -> void:
	if _vendor_hint == null:
		_vendor_hint = Label.new()
		_vendor_hint.add_theme_font_size_override("font_size", 18)
		_vendor_hint.modulate = Color(0.5, 0.9, 1.0)
		_vendor_hint.visible = false
		_hud.add_child(_vendor_hint)
	var v = _state.get("practice")
	var pf = _find_fighter(_player_id)
	_near_vendor = false
	if v != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(v["x"]), float(pf["y"]) - float(v["y"])).length()
		_near_vendor = d <= World.PRACTICE_RADIUS
	if _near_vendor and (_vendor_panel == null or not _vendor_panel.visible):
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
		_vendor_hint.text = "Press [V] for the Practice Vendor"
		_vendor_hint.position = Vector2(vp.x / 2.0 - 110.0, vp.y - 178.0)
		_vendor_hint.visible = true
	else:
		_vendor_hint.visible = false
	if not _near_vendor and _vendor_panel != null and _vendor_panel.visible:
		_vendor_panel.visible = false                # walked away → close the vendor

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
		["→ Home", "goto", {"map": "home"}], ["→ Arena", "goto", {"map": "arena"}],
		["→ GY1", "goto", {"map": "glitchyard_1"}], ["→ GY2", "goto", {"map": "glitchyard_2"}], ["→ GY3", "goto", {"map": "glitchyard_3"}],
		["→ GY4", "goto", {"map": "glitchyard_4"}], ["→ GY5", "goto", {"map": "glitchyard_5"}], ["→ BOSS", "goto", {"map": "glitchyard_boss"}],
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
	# P4: a rarity-accented loot toast (top-right) + keep the chat-log line as history
	_toast("[color=#ffd24d]★ Looted[/color]  [color=%s]%s[/color]\n[color=#7f93a8]%s · %s%s[/color]" % [col, _esc(item), rarity, slot, bonus], Color.html(col))
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
	_move_send_t += _delta                           # rate-limit movement to ~30 Hz (server tick) — sending every
	if _move_send_t >= MOVE_SEND_INTERVAL:           # 60 Hz physics frame doubled the packet rate + overflowed
		_move_send_t = 0.0                           # the UDP send buffer ("Buffer full, dropping packets")
		_send_movement()                             # unreliable, latest-wins
	if not _chatting and _player.intent["ability"] != "":
		_send_ability(_player.intent["ability"])     # reliable, de-duplicated (event-driven — NOT rate-limited)
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
		_party_panel.position = Vector2(12.0, 250.0)   # below the P1 vitals frame + currency tray
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
		fr["fill"].color = WorldUI.hp_color(frac) if bool(m["alive"]) else Color(0.5, 0.5, 0.55)   # shared ramp
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

# §4a meter: party scope + row highlight read the live roster (self always counts)
func _meter_is_party(id: String) -> bool:
	if id == _player_id:
		return true
	for m in _party:
		if str(m.get("fid", "")) == id:
			return true
	return false

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

func _invite_box(accent: Color, border_w: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(Palette.BG_PANEL, 0.98)
	sb.set_border_width_all(border_w)
	sb.border_color = accent
	sb.set_corner_radius_all(9)
	sb.set_content_margin_all(18)
	p.add_theme_stylebox_override("panel", sb)
	return p

func _show_invite_popup(fid: String, nm: String) -> void:
	if _invite_popup != null:
		_invite_popup.queue_free()
	_invite_popup = _invite_box(Palette.ACCENT2, 1)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_invite_popup.add_child(vb)
	var lbl := Label.new()
	lbl.text = "Invite %s to your party?" % nm
	lbl.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	lbl.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var btn := Button.new()
	btn.text = "👥  Invite"
	btn.custom_minimum_size = Vector2(150, 40)
	btn.add_theme_color_override("font_color", Palette.ACCENT2)
	btn.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_invite.rpc_id(1, fid)
		if _invite_popup != null: _invite_popup.queue_free()
		_invite_popup = null)
	row.add_child(btn)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(110, 40)
	cancel.pressed.connect(func() -> void:
		if _invite_popup != null: _invite_popup.queue_free()
		_invite_popup = null)
	row.add_child(cancel)
	_hud.add_child(_invite_popup)
	_invite_popup.reset_size()
	var mp: Vector2 = _hud.get_viewport().get_mouse_position()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_invite_popup.position = Vector2(clampf(mp.x + 12.0, 8.0, vp.x - _invite_popup.size.x - 8.0),
		clampf(mp.y + 12.0, 8.0, vp.y - _invite_popup.size.y - 8.0))

# an incoming invite → accept/decline prompt
func recv_party_invite(inviter_name: String, inviter_fid: String) -> void:
	if autowalk:                                     # test bots auto-accept (skip the UI)
		if net != null and _connected:
			net.party_accept.rpc_id(1, inviter_fid)
		return
	_invite_from_fid = inviter_fid
	if _invite_prompt != null:
		_invite_prompt.queue_free()
	_invite_prompt = _invite_box(Palette.ACCENT, 2)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	_invite_prompt.add_child(vb)
	var title := Label.new()
	title.text = "👥  PARTY INVITE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	vb.add_child(title)
	var lbl := Label.new()
	lbl.text = "%s invited you to their party" % inviter_name
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
	lbl.add_theme_color_override("font_color", Palette.TEXT)
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	var yes := Button.new()
	yes.text = "✓ Accept"
	yes.custom_minimum_size = Vector2(150, 46)
	yes.add_theme_color_override("font_color", Palette.XP)
	yes.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_accept.rpc_id(1, _invite_from_fid)
		_close_invite_prompt())
	row.add_child(yes)
	var no := Button.new()
	no.text = "✕ Decline"
	no.custom_minimum_size = Vector2(150, 46)
	no.add_theme_color_override("font_color", Palette.DANGER_SOFT)
	no.pressed.connect(func() -> void:
		if net != null and _connected:
			net.party_decline.rpc_id(1)
		_close_invite_prompt())
	row.add_child(no)
	_hud.add_child(_invite_prompt)
	_invite_prompt.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_invite_prompt.position = Vector2((vp.x - _invite_prompt.size.x) / 2.0, 110.0)

func _close_invite_prompt() -> void:
	if _invite_prompt != null:
		_invite_prompt.queue_free()
		_invite_prompt = null

# ---- party loot: want/need/pass roll ----
func recv_loot_roll(drop_id: int, info: Dictionary, ms: int) -> void:
	_loot_roll_queue.append({"drop_id": drop_id, "info": info, "ms": ms})
	if _loot_roll_panel == null:
		_show_next_loot_roll()

func _show_next_loot_roll() -> void:
	if _loot_roll_panel != null or _loot_roll_queue.is_empty():
		return
	var e: Dictionary = _loot_roll_queue.pop_front()
	var info: Dictionary = e["info"]
	_loot_roll_cur = int(e["drop_id"])
	_loot_roll_deadline = float(e["ms"]) / 1000.0
	_loot_roll_panel = _invite_box(Palette.ACCENT, 2)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_loot_roll_panel.add_child(vb)
	var title := Label.new()
	title.text = "🎲  PARTY LOOT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	vb.add_child(title)
	var rar := str(info.get("rarity", "common"))
	var rcol: String = Palette.UNIQUE_HEX if bool(info.get("unique", false)) else RARITY_COLORS.get(rar, "#cfd6df")
	var item := RichTextLabel.new()
	item.bbcode_enabled = true
	item.fit_content = true
	item.scroll_active = false
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.custom_minimum_size = Vector2(300, 0)
	var statline := ("  [color=%s]+%d %s[/color]" % [Palette.hex(Palette.XP), int(info.get("amt", 0)), str(info.get("stat", ""))]) if int(info.get("amt", 0)) != 0 else ""
	item.text = "[center][b][color=%s]%s[/color][/b]\n[color=%s]%s · %s · i%d[/color]%s[/center]" % [
		rcol, _esc(str(info.get("name", "?"))), Palette.hex(Palette.TEXT_FAINT), rar, str(info.get("slot", "")), int(info.get("ilvl", 1)), statline]
	vb.add_child(item)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	var did := _loot_roll_cur
	row.add_child(_loot_roll_btn("Need", Palette.XP, func() -> void: _loot_roll_choose(did, "need")))
	row.add_child(_loot_roll_btn("Want", Palette.ACCENT, func() -> void: _loot_roll_choose(did, "want")))
	row.add_child(_loot_roll_btn("Pass", Palette.TEXT_DIM, func() -> void: _loot_roll_choose(did, "pass")))
	_loot_roll_timer_lbl = Label.new()
	_loot_roll_timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loot_roll_timer_lbl.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_loot_roll_timer_lbl.add_theme_color_override("font_color", Palette.TEXT_DIM)
	vb.add_child(_loot_roll_timer_lbl)
	_hud.add_child(_loot_roll_panel)
	_loot_roll_panel.reset_size()
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_loot_roll_panel.position = Vector2((vp.x - _loot_roll_panel.size.x) / 2.0, vp.y * 0.34)

func _loot_roll_btn(text: String, col: Color, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(96, 44)
	b.add_theme_color_override("font_color", col)
	b.pressed.connect(cb)
	return b

func _loot_roll_choose(drop_id: int, choice: String) -> void:
	if net != null and _connected:
		net.loot_roll.rpc_id(1, drop_id, choice)
	_close_loot_roll()
	_show_next_loot_roll()

func _close_loot_roll() -> void:
	if _loot_roll_panel != null:
		_loot_roll_panel.queue_free()
		_loot_roll_panel = null
	_loot_roll_cur = -1
	_loot_roll_timer_lbl = null

# auto-pass on timeout (driven from _process)
func _update_loot_roll(delta: float) -> void:
	if _loot_roll_panel == null:
		return
	_loot_roll_deadline -= delta
	if _loot_roll_deadline <= 0.0:
		_loot_roll_choose(_loot_roll_cur, "pass")     # ran out → auto-pass, show the next
	elif _loot_roll_timer_lbl != null:
		_loot_roll_timer_lbl.text = "auto-pass in %ds" % int(ceil(_loot_roll_deadline))

# the outcome (winner + rolls) — a toast; and close the prompt if the server resolved it early
func recv_loot_roll_result(drop_id: int, result: Dictionary) -> void:
	if _loot_roll_cur == drop_id:
		_close_loot_roll()
		_show_next_loot_roll()
	var info: Dictionary = result.get("item", {})
	var rar := str(info.get("rarity", "common"))
	var rcol: String = Palette.UNIQUE_HEX if bool(info.get("unique", false)) else RARITY_COLORS.get(rar, "#cfd6df")
	var winner := str(result.get("winner", "nobody"))
	var rolls: Dictionary = result.get("rolls", {})
	var roll_txt := ""
	if not rolls.is_empty():                          # show each roller's 1-100 (highest won)
		var parts := []
		for fid in rolls:
			parts.append("%s %d" % [_roster_name(str(fid)), int(rolls[fid])])
		roll_txt = "\n[color=%s]%s[/color]" % [Palette.hex(Palette.TEXT_FAINT), "  ·  ".join(parts)]
	_toast("[b]🎲 %s[/b] won [color=%s]%s[/color]%s" % [_esc(winner), rcol, _esc(str(info.get("name", "?"))), roll_txt], Palette.ACCENT)

func _roster_name(fid: String) -> String:         # party-member display name from the roster (fallback to the fid)
	for m in _party:
		if str(m.get("fid", "")) == fid:
			return str(m.get("name", fid))
	return fid

func _send_ability(key: String) -> void:
	if _can_press(key):              # off-cd + alive as far as the client knows → show the predicted tell
		_play_cast_sound(key)
		_predict_cast(key)           # instant swing + hotbar depress + predicted cooldown (self-correcting)
	_aseq += 1
	if server != null:
		server.submit_ability_local(1, key, _aseq)
	elif net != null and _connected:
		net.submit_ability.rpc_id(1, key, _aseq)

var _cast_sound_t := {}          # ability key → last press-sound tick (msec)

# the local player's cast sound on the exact press frame (class-signature sound, role fallback).
# _can_press gates presses on cooldown; the per-key throttle keeps a mash inside the confirm window
# (server cds not yet visible) from machine-gunning, while any deliberate re-press still sounds.
func _play_cast_sound(key: String) -> void:
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	var now := Time.get_ticks_msec()
	if now - int(_cast_sound_t.get(key, -10000)) < 250:
		return
	_cast_sound_t[key] = now
	AudioManager.play_sfx(_cast_sfx_name(str(pf["classId"]), key), _world(pf))

# render only — the server owns the sim
var _ult_tint: ColorRect = null
var _ult_banner: Label = null

# Full-screen telegraph while the boss is casting Full Camp Reset — a red tint that intensifies toward
# impact + a "BREAK LINE OF SIGHT" banner, so players learn the ult is arena-wide and cover is the answer.
func _update_boss_telegraph() -> void:
	var uc := 0.0
	for f in _state.get("fighters", []):
		var c := float(f.get("ultCast", 0.0))
		if c > uc: uc = c
	if uc <= 0.0:
		if _ult_tint != null: _ult_tint.visible = false
		if _ult_banner != null: _ult_banner.visible = false
		return
	if _ult_tint == null:
		_ult_tint = ColorRect.new()
		_ult_tint.color = Color(0.85, 0.06, 0.06, 0.0)
		_ult_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ult_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
		_hud.add_child(_ult_tint)
		_ult_banner = Label.new()
		_ult_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ult_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_ult_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_ult_banner.anchor_left = 0.0; _ult_banner.anchor_right = 1.0
		_ult_banner.offset_top = 90.0
		_ult_banner.add_theme_font_size_override("font_size", 40)
		_ult_banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		_ult_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		_ult_banner.add_theme_constant_override("outline_size", 14)
		_hud.add_child(_ult_banner)
	_ult_tint.visible = true
	_ult_banner.visible = true
	_ult_tint.color.a = lerpf(0.10, 0.40, clampf(1.0 - uc / 3.0, 0.0, 1.0))   # intensify as impact nears
	_ult_banner.text = "⚠  FULL CAMP RESET  %d  ⚠\nBREAK LINE OF SIGHT — GET BEHIND COVER" % int(ceil(uc))

# P4: suppress the shared vignette/death juice while the session isn't live (connection error /
# pre-first-snapshot). _state is never cleared on a drop, so _render_world keeps running — without
# this the vignette/death would freeze on stale state under the disconnect overlay.
func _juice_suppressed() -> bool:
	return _net_msg != "" or _player_id == "" or _player == null

# P4 online-only juice: a gold level-up flash (z=160) + a zone-transition card (z=110). The shared
# vignette/death/toast layer is built by Client._build_hud; these two ride online-only events.
var _level_flash: ColorRect = null
var _flash_t := -1.0                         # ≥0 while a level-up flash plays
var _zone_card: ColorRect = null
var _zone_card_label: Label = null
var _zone_card_t := -1.0                      # ≥0 while a zone card plays

func _build_juice_online() -> void:
	_level_flash = ColorRect.new()
	_level_flash.color = Color(1.0, 0.84, 0.32, 0.0)
	_level_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_level_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_flash.z_index = 160
	_level_flash.visible = false
	_hud.add_child(_level_flash)
	_zone_card = ColorRect.new()
	_zone_card.color = Color(0.03, 0.04, 0.06, 0.0)
	_zone_card.set_anchors_preset(Control.PRESET_FULL_RECT)
	_zone_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zone_card.z_index = 110
	_zone_card.visible = false
	_hud.add_child(_zone_card)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_zone_card.add_child(cc)
	_zone_card_label = Label.new()
	_zone_card_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_card_label.add_theme_font_size_override("font_size", 40)
	_zone_card_label.add_theme_color_override("font_color", Palette.ACCENT2)
	_zone_card_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_zone_card_label.add_theme_constant_override("outline_size", 10)
	cc.add_child(_zone_card_label)

func _trigger_level_flash() -> void:
	if reduce_fx or _level_flash == null:        # a bright full-screen pulse is a motion trigger → skip
		return
	_flash_t = 0.0

func _trigger_zone_card(map: String) -> void:
	if _zone_card == null:
		return
	_zone_card_label.text = _zone_name(map)
	_zone_card_t = 0.0

# per-frame one-shots (level flash fade + zone card fade in/hold/out). Called from _process.
func _update_juice_online(dt: float) -> void:
	if _flash_t >= 0.0 and _level_flash != null:
		_flash_t += dt
		if _flash_t >= 0.5:
			_flash_t = -1.0
			_level_flash.visible = false
		else:
			_level_flash.visible = true
			_level_flash.color.a = (1.0 - _flash_t / 0.5) * 0.4
	if _zone_card_t >= 0.0 and _zone_card != null:
		_zone_card_t += dt
		var fin := 0.3
		var hold := 1.1
		var fout := 0.6
		if _zone_card_t >= fin + hold + fout:
			_zone_card_t = -1.0
			_zone_card.visible = false
		else:
			_zone_card.visible = true
			var a := 1.0
			if _zone_card_t < fin:
				a = _zone_card_t / fin
			elif _zone_card_t > fin + hold:
				a = 1.0 - (_zone_card_t - fin - hold) / fout
			if reduce_fx:                          # no motion fade — steady then cut
				a = 0.0 if _zone_card_t > fin + hold else 1.0
			_zone_card.color.a = a * 0.5
			_zone_card_label.modulate.a = a

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
	_update_boss_telegraph()
	_update_focus()
	_update_party()
	_render_shop_pad()
	_update_shop_proximity()
	_render_build_shop_pad()
	_update_build_shop_proximity()
	_update_locker_portal_proximity()
	if _lb_on:                                    # Builder Mode: the in-locker build editor (ghost preview; auto-exit on leaving)
		if not _locker_build_available():
			_lb_set_on(false)
		else:
			_lb_update_ghost()
			_lb_update_del_highlight()            # red pulsing highlight on a prop pending [Y]/[N] deletion
	_update_locker_help_hint()                    # the "[H] build help" reminder while in the Locker Room
	_render_forge_pad()
	_update_forge_proximity()
	_render_questgiver_pad()
	_update_questgiver_proximity()
	_render_vendor_pad()
	_update_vendor_proximity()
	_update_camp_proximity()
	_update_drill_banner()
	_update_juice_online(delta)     # P4: level-up flash + zone-transition card one-shots
	_update_loot_roll(delta)        # party loot want/need/pass countdown → auto-pass
	if _locker_panel != null and _locker_panel.visible and _locker_model_holder != null:
		_locker_model_holder.rotation.y += delta * 0.5   # slow turntable on the locker figure

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
	if _locker_panel != null and _locker_panel.visible:  # keep the locker's model + header + stats live
		_update_locker_model()
		_update_locker_header()
		_update_locker_stats()                           # sig-guarded → rebuilds only when a value actually changed
	if _player != null and _player_id != "":
		var pf = _find_fighter(_player_id)
		if pf != null and _player.class_id != pf["classId"]:
			_player.class_id = pf["classId"]
	var map := str(snap.get("map", ""))          # zone change → portal whoosh + music crossfade + P4 zone card
	if map != _last_map:
		if _last_map != "":
			AudioManager.play_sfx("portal")
			_trigger_zone_card(map)              # P4: "Now Entering <Zone>" card (not on the first login zone-in)
		_last_map = map
		AudioManager.play_music(map)
		if map == World.LOCKER:                  # Builder Mode: onboarding "how to build" popup on entering your Locker Room
			_on_enter_locker()
	var lpf = _find_fighter(_player_id)           # level-up fanfare + P4 flash/toast
	if lpf != null:
		var lvl := int(lpf.get("level", 1))
		if _last_level > 0 and lvl > _last_level:
			AudioManager.play_sfx("level_up")
			_trigger_level_flash()
			_toast("[b]⭐ LEVEL UP[/b]\nYou reached [color=%s]Level %d[/color]" % [Palette.hex(Palette.ACCENT), lvl], Palette.ACCENT, true)
		_last_level = lvl
	var unlocked_now := _locker_unlocked()        # Builder Mode: toast the first time you own your Locker Room
	if unlocked_now and not _was_locker_unlocked:
		_toast("[color=#9fe8a0]🔓 Locker Room unlocked![/color]\nWalk through the portal in the home base to enter.", Palette.ACCENT)
	_was_locker_unlocked = unlocked_now
	_handle_events()             # spawn damage-number / hit FX from this snapshot's events
	if _dev_open != "" and _player_id != "" and _find_fighter(_player_id) != null:
		_dev_open_panel()        # dev screenshot hook: open a panel once we have a live fighter
	if _dev_juice and _player_id != "" and _find_fighter(_player_id) != null:
		_dev_juice = false       # dev screenshot hook: fire the P4 juice once (toasts + zone card + flash)
		_toast("[color=#ffd24d]★ Looted[/color]  [color=#c77dff]Epic Cleats[/color]\n[color=#7f93a8]epic · feet  +18 SPD[/color]", Color.html("#c77dff"))
		_toast("[color=#9fe8a0]✔ Quest complete:[/color] Boot Camp", Palette.ACCENT)
		_toast("[b]⭐ LEVEL UP[/b]\nYou reached [color=%s]Level 3[/color]" % Palette.hex(Palette.ACCENT), Palette.ACCENT, true)
		_trigger_zone_card("glitchyard_1")

func assign_fighter(fid: String) -> void:
	_player_id = fid
	print("[netclient] assigned fighter ", fid)

# spawn render nodes for new fighters, free nodes for ones that left, revive on respawn
func _sync_nodes_to_state() -> void:
	var present := {}
	for f in _state["fighters"]:
		present[f["id"]] = true
		var was_absent: bool = _absent.has(f["id"])
		_absent.erase(f["id"])                  # back in interest range
		if not _nodes.has(f["id"]):
			_spawn(f)
		else:
			var n = _nodes[f["id"]]
			if was_absent:                      # cooldowns used while out of interest range are not
				n["pcds"] = f["cds"].duplicate()    # fresh casts — re-prime so they don't phantom-burst
				if n.has("mobanim"):
					n["mobanim"]["pcds"] = f["cds"].duplicate()
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
			elif _locker_panel != null and _locker_panel.visible:
				_locker_panel.visible = false
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
			elif _vendor_panel != null and _vendor_panel.visible:
				_vendor_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _camp_panel != null and _camp_panel.visible:
				_camp_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _wardrobe_panel != null and _wardrobe_panel.visible:
				_wardrobe_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _lb_panel != null and _lb_panel.visible:
				_lb_panel.visible = false
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
		elif e.keycode == KEY_U and not _chatting:
			_toggle_locker()                # the Locker Loadout (gear + stats + 3D figure)
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
		elif e.keycode == KEY_F3 and not _chatting:
			_toggle_coords()                # dev: sim-space (map) coord readout under the cursor for authoring maps
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
		elif e.keycode == KEY_V and not _chatting and (_near_vendor or (_vendor_panel != null and _vendor_panel.visible)):
			_toggle_vendor()                # the Practice Vendor while near it (reward loop)
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_C and not _chatting and (_near_camp or (_camp_panel != null and _camp_panel.visible)):
			_toggle_camp()                  # the Camp Circuit Intensity selector while at the entry portal
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_P and not _chatting and (_near_build_shop or (_build_shop_panel != null and _build_shop_panel.visible)):
			_toggle_build_shop()            # the Build Shop (furniture) while on the home pad
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_Y and not _chatting and _near_locker_portal and not _locker_unlocked():
			_buy_locker_room()              # purchase your Locker Room at the portal (one-time 10,000 credits)
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_H and not _chatting and str(_state.get("map", "")) == World.LOCKER:
			_toggle_build_help()            # Builder Mode: open/close the "how to build" help in your Locker Room
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_N and not _chatting:
			if _locker_panel != null: _locker_panel.visible = false   # meter behind the opaque locker = invisible
			_toggle_meter()                 # the §4a DPS/HPS meter — usable anywhere
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_G and not _chatting:
			_toggle_wardrobe()              # the Wardrobe (cosmetic dyes) — usable anywhere
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_L and not _chatting:
			_toggle_leaderboard()           # the leaderboards — usable anywhere
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
	if _dc_overlay != null:                       # prominent disconnect notice (kept above every panel)
		if _net_msg != "":
			_dc_msg_label.text = _net_msg
			if not _dc_overlay.visible:
				_hud.move_child(_dc_overlay, _hud.get_child_count() - 1)
				_dc_overlay.visible = true
		elif _dc_overlay.visible:
			_dc_overlay.visible = false
	if _net_msg != "" or _player_id == "" or _player == null or _state.is_empty():
		if _hud_left != null:                     # pre-snapshot / dropped: the status banner IS the HUD
			_hud_left.visible = false
		if _zone_banner != null:
			_zone_banner.visible = false
		var det := ("[color=#ff7a7a]%s[/color]" % _net_msg) if _net_msg != "" else "[color=#7f93a8]connecting…[/color]"
		_info.text = "[b]Legends MMO — Online[/b]\n" + det
		_bar.text = ""
		_vit_cache.erase("hints")                 # re-arm the keybind line for the next session
		return
	var pf = _find_fighter(_player_id)
	if pf == null:
		return
	_info.text = ""
	var c: Dictionary = GameData.CLASSES[pf["classId"]]
	_update_vitals(pf, str(pf.get("name", c["name"])), c)
	_vit_set("status", _vit_status, ("respawning…   ·   ONLINE" if not pf["alive"] else "ONLINE"))
	_vit_status.add_theme_color_override("font_color",
		Palette.DANGER_SOFT if not pf["alive"] else Palette.TEXT_DIM)
	_tray.visible = true                          # the currency tray is an online-only strip
	_vit_set("credits", _tray_credits, "◈ %d" % int(pf.get("credits", 0)))
	_vit_set("scrap", _tray_scrap, "%d scrap" % _my_scrap())
	_vit_set("tokens", _tray_tokens, "%d tokens" % _my_tokens())
	_zone_banner.visible = true
	var pvp := bool(_state.get("pvp", false))
	var zone := _zone_name(str(_state.get("map", "")))
	_vit_set("zone", _zone_label, ("⚔ %s · PVP" % zone.to_upper()) if pvp else zone.to_upper())
	if bool(_vit_cache.get("zone_pvp", false)) != pvp:
		_vit_cache["zone_pvp"] = pvp
		_zone_label.add_theme_color_override("font_color", Palette.DANGER if pvp else Palette.ACCENT2)
	var hints := "WASD · 1-8 abilities · LMB basic · RMB camera ([b]right-click a player[/b] = invite) · [b]Tab[/b] enemy · [b]Ctrl+Tab[/b]/frame = ally · [b]I[/b] bag · [b]U[/b] locker · [b]K[/b] sheet · [b]J[/b] journal · [b]N[/b] meter · [b]G[/b] wardrobe · [b]L[/b] boards · [b]O[/b] options"
	if str(_vit_cache.get("hints", "")) != hints:
		_vit_cache["hints"] = hints
		_bar.text = "[color=#7f93a8]%s[/color]" % hints
	_update_hotbar(pf)                           # the visual skill bar (shared with local mode)

func _zone_name(map: String) -> String:
	match map:
		"home": return "Home Base"
		"glitchyard_1": return "Glitchyard · Rookie Intake"
		"glitchyard_2": return "Glitchyard · Agility Grid"
		"glitchyard_3": return "Glitchyard · Impact Lanes"
		"glitchyard_4": return "Glitchyard · Target Court"
		"glitchyard_5": return "Glitchyard · Command Tower"
		"arena": return "Arena"
		"camp": return "Camp Circuit"
		"drill": return "Two-Minute Drill"
		_: return map.capitalize() if map != "" else "—"
