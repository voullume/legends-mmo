extends "res://client/Client.gd"
## NETWORKED CLIENT (Phase 2). Extends the Phase-1 renderer and reuses every rendering helper;
## the only difference is WHERE the world comes from: instead of ticking the sim locally, it
## fills _state from server snapshots and sends its input to the server's controlled seam.
##
## Two transports, identical rendering:
##   ONLINE — a remote client: intents/snapshots via the Net RPC bridge.
##   HOST   — the player who is also hosting: talks to the in-process Server directly.

const NetProtocol := preload("res://shared/Protocol.gd")   # protocol handshake constant (stabilization P5)
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
var _chat_idle := CHAT_FADE_AFTER + 1.0   # seconds since the last chat/loot line — fades after CHAT_FADE_AFTER.
                                          # Starts PAST the threshold: at 0.70 body alpha an empty log at login
                                          # read as a bare dark rectangle; the first line (or typing) pops it up.
const CHAT_FADE_AFTER := 20.0
var _chat_root: Control = null       # P6: the whole chat block (log box + input) as one module
var _chat_box: Control = null        # frame + log — the part that idle-fades
var _chat_frame: Control = null      # UTILITY-tier backing (fades with the log)
var _chat_preview_on := false        # HUD-edit preview: sample lines + no fade
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
var _party_root: Control = null   # P7: the party group's PANEL chassis (one module, not per-member)
var _party_prev := false          # HUD-edit preview: sample member rows while solo
var _party_samples := []          # the temporary preview row nodes
var _tf := {}                     # P7 hostile target frame {root, name, sub, hp, hpt, cache}
var _ff := {}                     # P7 friendly focus frame (same shape)
var _tf_preview := false
var _ff_preview := false
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
var _sheet_rows: VBoxContainer               # sectioned stat CARDS (Attributes / Combat / Sets / Procs)
var _sheet_sig := 0                          # sig-guard: `self` rides the change-detected META → skip the per-snapshot rebuild
var _inv_items := []                          # last-loaded inventory cache (for hover tooltips)
var _gear_count := 0                          # cached count of GEAR rows (category != 'build') → near-cap warning
var _cap_seeded := false                      # one-time seed of _inv_items/_gear_count after login
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
var _near_shop := false
# Builder Mode (P3): the Build Shop pad/panel (buy furniture) + the locked-locker "Purchase" portal prompt
var _build_info := {}              # catalog + caps + unlock cost (from recv_build_info)
var _build_shop_panel: Control = null
var _build_shop_status: Label = null
var _build_shop_grid: GridContainer = null
var _build_shop_root: Node3D = null
var _build_shop_sig := ""
var _near_build_shop := false
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
var _lb_root: Control = null        # P9: the builder panel's chassis (the module node)
var _lb_ghost: Node3D = null        # translucent preview of the to-place / being-moved prop at the cursor
var _lb_ghost_key := ""             # model+"@"+h of the current ghost (rebuild only when it changes)
var _forge_root: Node3D = null   # the 3D forge pad visual (P4)
var _forge_sig := ""
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
var _near_vendor := false
# Camp Circuit (endgame): the Intensity selector at the home entry portal
var _camp_panel: Control = null
var _camp_rows: VBoxContainer = null
var _camp_status: Label = null
var _near_camp := false
# Wardrobe (P4 cosmetics): a key-toggled dye panel (buy with credits + equip)
var _wardrobe_panel: Control = null
var _wardrobe_rows: VBoxContainer = null
var _wardrobe_status: Label = null
# Talent trees (gameplay-length P4): a key-toggled (T) spend/respec panel
var _talent_panel: Control = null
var _talent_rows: VBoxContainer = null
var _talent_status: Label = null
var _talent_sig := ""                             # sig-guard so the open panel only rebuilds when a shown value changed
# Paragon "Overtime" Bench Board (gameplay-length P5): a key-toggled (B) allocate-then-Apply QoL board
var _paragon_panel: Control = null
var _paragon_rows: VBoxContainer = null
var _paragon_status: Label = null
var _paragon_draft := {}                          # local working allocation (perk_id → ranks) until Apply
var _overtime_xp := 0                             # live post-cap odometer (pushed via recv_overtime, not the hashed META)
var _paragon_sig := ""
# Leaderboards + Two-Minute Drill (P5)
var _lb_panel: Control = null
var _lb_rows: VBoxContainer = null
var _lb_status: Label = null
var _lb_cat := "drill"
var _lb_tabs := {}                           # Widgets.tab_row handle (highlight the active board)
var _lb_entries := []
var _lb_season := 0                  # P7d: current season of the active tab (0 = all-time board)
var _lb_reset_unix := 0              # P7d: next-reset epoch for a seasonal tab (0 = no countdown)
var _drill_banner: Control = null            # structural icon+label row (two_minute_drill icon + wave text)
var _drill_banner_lbl: Label = null
var _forge_pending := false
var _shop_sell_cache := {}    # item_id -> {name, rarity, price} for the sell confirmation
var _sell_confirm: Control = null            # PanelContainer (sizes to content + draws the themed box)
var _sell_items := []         # last-loaded inventory (Array[Dictionary]) — re-render toggles without re-fetch
var _sell_selection := {}     # item_id -> true, the multi-select set in the SELL list
var _sell_sort := "rarity"    # rarity | slot | power
var _sell_filter_slot := ""   # "" = all slots, else one of the 10 item-type slots (head…trinket)
var _sell_loading := false    # re-entrancy guard for the SELL list load (mirrors _inv_loading)
var _sell_pending := false    # a reload was requested while one was in flight
var _quests := {}             # quest_id -> {progress, completed} — server-pushed, server-authoritative
var _quest_panel: Control = null
var _quest_rows: VBoxContainer = null        # journal: sectioned quest cards (was one bbcode blob)
var _quest_tracker: VBoxContainer = null    # always-on HUD list of active quests
var _quest_tracker_title: Label = null
var _qt_root: Control = null                # P6: the tracker's PANEL chassis (the module node)
var _qt_count: Label = null                 # body-font "(J) · N" suffix beside the display title
var _qt_variant := "standard"               # standard / compact / collapsed
var _qt_preview := false                    # HUD-edit mode: show placeholder rows when questless
var _qgiver_panel: Control = null           # the home-base quest-giver dialog (accept / turn in)
var _qgiver_rows: VBoxContainer = null       # P: real accept/turn-in/claim BUTTON rows (was bbcode links)
var _qgiver_root: Node3D = null             # the 3D quest-giver marker in the home base
var _qgiver_sig := ""
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
	_build_talents()
	_build_paragon()
	_build_leaderboard()
	_build_questlog()
	_build_qgiver_dialog()
	_build_settings()
	_build_controls()                             # the keybind reference (Settings → Controls)
	_build_locker()
	_build_disconnect_overlay()
	_build_event_banner()
	_build_unit_frames()                          # P7: hostile target + friendly focus modules
	_build_interact_prompt()                      # P8: the ONE proximity prompt module (7 hints unified)
	_build_bottom_nav()                           # P9: clickable panel shortcuts (real keybinds only)
	_build_minimap()                              # minimap: schematic top-down module (snapshot-only)
	_lb_set_on(false)                             # eager: registers the builder-panel module pre-F4
	_update_quest_tracker()                       # eager: registers the tracker module (hidden while
	                                              # questless) so edit mode can place it pre-quests
	_sync_party_panel()                           # eager: registers the party group module (hidden solo)
	var ua := OS.get_cmdline_user_args()
	if "--meter" in ua:                           # dev-only: open the §4a meter on boot (pairs with --shot)
		_toggle_meter()
	if "--minimap" in ua:                         # dev-only: force-show the (off-by-default) minimap + sample content for --shot
		HudLayout.set_field("minimap", "visible", true)
		_mm_module_preview(true)
	if "--hudedit" in ua:                         # dev-only: open HUD edit mode (pairs with --shot)
		_hud_edit_toggle()
	if "--bannertest" in ua:                      # dev-only: fire a demo hero banner (pure client)
		_banner_dev = true                        # bypass the pre-snapshot suppression for the shot
		_show_banner("Boss Event", "Head Coach Awakens", "prepare to compete", Palette.SB_ORANGE)
	var oi := ua.find("--open")                   # dev-only: open a named panel after the first snapshot
	if oi >= 0 and oi + 1 < ua.size():
		_dev_open = str(ua[oi + 1])
	var wi := ua.find("--walkto")                 # dev-only: auto-walk to sim "x,y" (screenshot loop —
	if wi >= 0 and wi + 1 < ua.size():            # proximity windows like the shop need you AT the pad)
		var wparts := str(ua[wi + 1]).split(",")
		if wparts.size() == 2:
			_dev_walkto = Vector2(float(wparts[0]), float(wparts[1]))
	var oni := ua.find("--opennow")               # dev-only: open a named panel IMMEDIATELY (pre-connect
	if oni >= 0 and oni + 1 < ua.size():          # window-chrome screenshots — panels exist at build)
		_dev_open = str(ua[oni + 1])
		_dev_open_panel()
	if "--juicetest" in ua:                       # dev-only: fire demo P4 juice once connected (for --shot)
		_dev_juice = true
	print("[netclient] ready — awaiting server fighter assignment")

var _dev_juice := false

var _dev_open := ""                               # dev-only screenshot hook: panel to open once connected
var _dev_walkto := Vector2.INF                    # dev-only --walkto target (sim coords); INF = inactive
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
		"talents": _toggle_talents()
		"paragon": _toggle_paragon()
		"shop": _toggle_shop()
		"forge": _toggle_forge()
		"vendor": _toggle_vendor()
		"qgiver": _toggle_qgiver()
		"locker": _toggle_locker()
		"controls": _toggle_controls()
		"settings2": _toggle_settings()
	if which == "locker" and "--sel" in OS.get_cmdline_user_args():
		await get_tree().create_timer(1.5).timeout   # dev: select main_hand to show the detail panel
		_select_locker_slot("main_hand", 0)
	if which == "inventory" and "--equipbest" in OS.get_cmdline_user_args():
		await get_tree().create_timer(2.0).timeout   # dev: run Equip Best once the inventory has loaded
		_equip_best()

func _build_chat() -> void:
	# P6: log + input travel as ONE "chat" module. The log rides a low-alpha UTILITY frame that
	# idle-fades with it; the input keeps the readable body font + the exact focus/submit flow.
	_chat_root = Control.new()
	_chat_box = Control.new()
	_chat_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_box.clip_contents = true       # a full 9-line ring in a compact box clips instead of bleeding
	_chat_root.add_child(_chat_box)
	# body 0.70 (was 0.45 — unreadable over bright grass); the idle fade still clears it entirely
	_chat_frame = HudFrame.make(HudFrame.Tier.UTILITY, {"stripe": true, "accent": Palette.ACCENT2, "body_alpha": 0.70})
	_chat_box.add_child(_chat_frame)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_active = false
	_chat_log.fit_content = true
	_chat_box.add_child(_chat_log)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "say something…  (Enter sends · Esc cancels)"
	_chat_input.max_length = 120
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submit)
	_chat_input.focus_exited.connect(_close_chat)
	_chat_root.add_child(_chat_input)
	_hud.add_child(_chat_root)
	_chat_box.modulate.a = 0.0                # born faded (empty log) — no boot-time dark box
	_chat_apply_variant("standard")
	HudLayout.register("chat", _chat_root, {"label": "Chat",
		"defaults": {"anchor": "bottom_left", "ox": 16.0, "oy": -12.0},
		"ref_size": Vector2(620, 276), "min_scale": 0.7, "max_scale": 1.4,
		"variants": ["standard", "compact", "wide", "collapsed"],
		"on_variant": _chat_apply_variant, "preview": _chat_preview})

# P6: variant = the log's footprint (width/height per the spec's chat options); "collapsed"
# keeps chat fully functional with zero permanent screen use (input appears on Enter).
func _chat_apply_variant(v: String) -> void:
	var sizes := {"standard": Vector2(620, 230), "compact": Vector2(460, 150),
		"wide": Vector2(800, 300), "collapsed": Vector2(620, 0)}
	var ls: Vector2 = sizes.get(v, sizes["standard"])
	var collapsed := v == "collapsed"
	_chat_box.visible = not collapsed
	_chat_box.position = Vector2.ZERO
	_chat_box.size = ls
	_chat_frame.position = Vector2.ZERO
	_chat_frame.size = ls
	_chat_log.position = Vector2(12, 6)
	# minimum FIRST, from the computed target — Control.set_size clamps to the combined minimum
	# synchronously, so writing size first then reading it back pins the old (larger) footprint
	var lg := Vector2(maxf(0.0, ls.x - 24.0), maxf(0.0, ls.y - 12.0))
	_chat_log.custom_minimum_size = lg
	_chat_log.size = lg
	var iy := 0.0 if collapsed else ls.y + 6.0
	_chat_input.position = Vector2(0, iy)
	_chat_input.custom_minimum_size = Vector2(ls.x, 34)
	_chat_input.size = Vector2(ls.x, 34)
	_chat_root.custom_minimum_size = Vector2(ls.x, iy + 34.0)
	_chat_root.size = _chat_root.custom_minimum_size

# HUD-edit preview: sample lines when the log is empty + hold full alpha while editing.
func _chat_preview(on: bool) -> void:
	_chat_preview_on = on
	if _chat_log == null:
		return
	if on:
		if _chat_lines.is_empty():
			_chat_log.text = "[color=#9fd0ff][b]Blitz-7[/b][/color]  gg nice pull\n[color=#9fd0ff][b]Coach[/b][/color]  rotate to the Camp Circuit"
		_chat_box.modulate.a = 1.0
	elif _chat_lines.is_empty():
		_chat_log.text = ""

func _open_chat() -> void:
	if _chat_root != null and not _chat_root.is_visible_in_tree():
		# the player hid the chat module — opening an invisible input would freeze movement
		# (_chatting zeroes intent) with no on-screen feedback
		_toast("[color=#8ad6ff]Chat is hidden[/color] — press F2, select Chat, re-enable Visible", Palette.ACCENT2)
		return
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

# the chat/loot log fades out after CHAT_FADE_AFTER seconds of no new line (and while not
# typing) — P6: the whole log box (frame + text) fades together; edit-preview pins it visible
func _update_chat_fade(delta: float) -> void:
	if _chat_box == null:
		return
	if _chatting:
		_chat_idle = 0.0
	else:
		_chat_idle += delta
	var target := 0.0 if (_chat_idle > CHAT_FADE_AFTER and not _chat_preview_on) else 1.0
	_chat_box.modulate.a = lerpf(_chat_box.modulate.a, target, clampf(delta * 2.5, 0.0, 1.0))

# UI-consistency pass (clutter): the online world adds five service pads to the label-fade set
func _world_fade_roots() -> Array:
	return [_portal_root, _qgiver_root, _shop_root, _build_shop_root, _vendor_root, _forge_root]

func recv_chat(sender: String, text: String) -> void:
	print("[chat] %s: %s" % [sender, text])
	# escape user-supplied brackets so they can't inject BBCode into the log
	_chat_lines.append("[color=#9fd0ff][b]%s[/b][/color]  %s" % [_esc(sender), _esc(text)])
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0                              # new line → pop the log back up
	_chat_box.modulate.a = 1.0

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
	return "[color=#7f8a99]i%d · IP %d[/color]" % [int(it.get("ilvl", 1)), int(it.get("item_power", 0))]

func _build_inventory() -> void:
	var p := Widgets.panel("Inventory", "I / Esc", 760.0, _toggle_inventory, true, {"icon": "inventory", "persist": "inventory", "legacy": "Inventory"})   # phase B: marquee chrome
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
	var p := Widgets.panel("Character", "K / Esc", 440.0, _toggle_charsheet, true, {"icon": "character", "persist": "character", "legacy": "Character"})   # phase B: marquee chrome
	_sheet_panel = p["root"]
	_hud.add_child(_sheet_panel)
	var vb: VBoxContainer = p["body"]
	var sc := ScrollContainer.new()                        # bounded region (journal/inventory pattern): a fully
	sc.custom_minimum_size = Vector2(404, 440)             # decked build (sets + procs) scrolls instead of
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED   # clipping off-screen unreachable
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL      # fill a larger (persisted) window — no dead space
	vb.add_child(sc)
	_sheet_rows = VBoxContainer.new()
	_sheet_rows.add_theme_constant_override("separation", 8)
	_sheet_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_sheet_rows)

# One stat CARD: cyan/gold-rail tile + optional display-font section header + tokenized bbcode body.
func _sheet_card(title: String, bb: String, rail: Color = Palette.SB_CYAN) -> void:
	var c := PanelContainer.new()
	c.add_theme_stylebox_override("panel", Widgets.tile_box(rail, false))
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	c.add_child(box)
	if title != "":
		box.add_child(Widgets.section(title))
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.custom_minimum_size = Vector2(360, 0)
	l.text = bb
	box.add_child(l)
	_sheet_rows.add_child(c)

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
	if _sheet_rows == null:
		return
	var si: Dictionary = _state.get("self", {})
	var sig := str(si).hash()                     # self changes rarely (rides the META) → skip the redundant per-snapshot rebuild
	if sig == _sheet_sig and _sheet_rows.get_child_count() > 0:
		return
	_sheet_sig = sig
	for c in _sheet_rows.get_children():
		c.queue_free()
	var dim := Palette.hex(Palette.TEXT_DIM)
	var body := Palette.hex(Palette.TEXT)
	var gear := Palette.hex(Palette.XP)
	var gold := Palette.hex(Palette.ACCENT)
	var pf = _find_fighter(_player_id)
	var cls_id: String = str(si.get("classId", "")) if si.has("classId") else (str(pf.get("classId", "")) if pf != null else "")
	if cls_id == "" or not GameData.CLASSES.has(cls_id):
		_sheet_card("", "[color=%s]loading…[/color]" % dim)
		return
	var base: Dictionary = GameData.CLASSES[cls_id]["stats"]
	var bonus: Dictionary = si.get("equip_bonus", {})
	var fin: Dictionary = si if not si.is_empty() else (pf if pf != null else {})
	# header card (gold rail): level + item power
	_sheet_card("", "[color=%s]Level %d[/color]    [color=%s]Item Power %d[/color]" % [
		dim, int(si.get("level", 0)), gold, int(si.get("item_power", 0))], Palette.ACCENT)
	# attributes card
	var arows := ["[color=%s](base [color=%s]+gear[/color])[/color]" % [dim, gear]]
	for st in STAT_KEYS:
		var b: int = int(base.get(st, 0))
		var g: int = int(bonus.get(st, 0))
		var gtxt: String = "  [color=%s]+%d[/color]" % [gear, g] if g > 0 else ""
		arows.append("[color=%s]%s[/color]  [color=%s]%d[/color]%s" % [dim, str(STAT_NAMES.get(st, st)), body, b + g, gtxt])
	_sheet_card("Attributes", "\n".join(arows))
	# combat card
	var crows := []
	crows.append("Max HP  [color=%s]%d[/color]" % [body, int(fin.get("maxHP", 0))])
	crows.append("Damage  [color=%s]+%d%%[/color]" % [body, int(round((float(fin.get("dmgMult", 1.0)) - 1.0) * 100.0))])
	crows.append("Crit  [color=%s]%d%%[/color] [color=%s]×%.2f[/color]" % [body, int(round(float(fin.get("crit", 0.0)) * 100.0)), dim, float(fin.get("critMult", 1.6))])
	crows.append("Move Speed  [color=%s]%d[/color]" % [body, int(round(float(fin.get("ms", 0.0))))])
	crows.append("Cooldown Reduction  [color=%s]%d%%[/color]" % [body, int(round(float(fin.get("cdr", 0.0)) * 100.0))])
	crows.append("Clutch (low HP)  [color=%s]+%d%% dmg[/color] · [color=%s]%d%% DR[/color]" % [
		body, int(round(float(fin.get("clutchDmg", 0.0)) * 100.0)), body, int(round(float(fin.get("clutchDR", 0.0)) * 100.0))])
	_sheet_card("Combat", "\n".join(crows))
	# active set bonuses (P5) — from equipped EPIC+ pieces, stacking above the 60 cap
	var sets: Dictionary = si.get("set_bonus", {})
	var active := []
	for sid in sets:
		var sb: Dictionary = sets[sid]
		if int(sb.get("bonus", 0)) > 0:
			var sdef: Dictionary = GameData.SET_DEFS.get(sid, {})
			active.append("[color=%s]%s[/color] (%d pc) [color=%s]+%d %s[/color]" % [
				Palette.hex(Palette.LAVENDER), str(sdef.get("name", sid)), int(sb.get("count", 0)), gear, int(sb["bonus"]), str(sb.get("stat", ""))])
	if not active.is_empty():
		_sheet_card("Set Bonuses", "[color=%s](epic+ pieces)[/color]\n" % dim + "\n".join(active), Palette.LAVENDER)
	# procs from equipped uniques (P6)
	var myprocs = si.get("procs", [])
	if myprocs is Array and not myprocs.is_empty():
		var prows := ["[color=%s](from uniques)[/color]" % dim]
		for pr in myprocs:
			var nm: String = str(GameData.PROC_CATALOG.get(str(pr.get("id", "")), {}).get("name", str(pr.get("id", ""))))
			var trig: String = str(pr.get("trigger", "")).replace("on_", "on ")
			var amt: float = float(pr.get("amt", 0.0))
			var desc := ""
			match str(pr.get("effect", "")):
				"DOT": desc = "%d dmg/s for %.0fs" % [int(round(amt)), float(pr.get("dur", 3.0))]
				"FLAT": desc = "+%d burst" % int(round(amt))
				"LIFESTEAL": desc = "heal %d%% of dmg" % int(round(amt * 100.0))
				"SHIELD": desc = "%d shield for %.0fs" % [int(round(amt)), float(pr.get("dur", 3.0))]
				"HEAL": desc = "heal %d HP" % int(round(amt))
				"HASTE": desc = "+%d%% move speed for %.0fs" % [int(round(amt * 100.0)), float(pr.get("dur", 3.0))]
				"GUARD": desc = "-%d%% dmg taken for %.0fs" % [int(round(amt * 100.0)), float(pr.get("dur", 3.0))]
			prows.append("[color=%s]• %s[/color] [color=%s](%s)[/color] %s" % [gold, nm, dim, trig, desc])
		_sheet_card("Procs", "\n".join(prows), Palette.ACCENT)

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
		for pnl in [_inv_panel, _sheet_panel, _quest_panel, _shop_panel, _forge_panel, _vendor_panel, _camp_panel, _wardrobe_panel, _talent_panel, _paragon_panel, _lb_panel, _qgiver_panel, _settings_panel, _meter_panel]:
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
		info.text = "[b][color=%s]%s[/color][/b]  [color=%s]EQUIPPED[/color]\n[color=%s]%s · %s · i%d · IP %d[/color]%s" % [
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
			b.text = "%s   IP %d" % [str(it.get("name", "?")), int(it.get("item_power", 0))]
			if is_up:                                 # a strict upgrade over what it would replace → the Upgrade icon
				b.icon = IconRegistry.texture("upgrade")
				b.expand_icon = false
				b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				b.add_theme_constant_override("icon_max_width", 14)
				b.add_theme_color_override("icon_normal_color", Palette.SUCCESS)
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
	L.append("[color=#7f8a99]%s · %s · i%d · IP %d[/color]" % [rar, slot, int(it.get("ilvl", 1)), int(it.get("item_power", 0))])
	if bool(it.get("locked", false)):                              # the corner lock badge's readable hover cue (the icon is IGNORE)
		L.append("[color=#ffb454]Locked — protected from sell / salvage[/color]")
	var sid := str(it.get("set_id", ""))
	if sid != "":
		L.append("[color=#cdbcff]%s set[/color]" % str(GameData.SET_DEFS.get(sid, {}).get("name", sid)))
	var pidv = it.get("proc_id")                                    # P6: proc description
	var pid: String = "" if pidv == null else str(pidv)
	if pid != "":
		L.append("[color=#ffb454]• %s[/color]" % _proc_desc(pid, int(it.get("proc_tier", 0))))
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
		if not _inv_items.is_empty():                # instant open from the cached rows (no network wait) —
			_rebuild_paperdoll(_inv_items)           # the GET below refreshes the grid in the background
			_render_inv_tiles()
		_load_inventory()

# gear count (category != 'build') + the near-cap warning. The 50-item cap is a DB trigger; this is the
# heads-up so a player can sell before new loot silently stops dropping.
func _recount_gear() -> void:
	var n := 0
	for it in _inv_items:
		if str((it as Dictionary).get("category", "gear")) != "build":
			n += 1
	_gear_count = n
	_update_cap_warning()

func _update_cap_warning() -> void:
	if _cap_row == null:
		return
	var cap := 50 + _my_gear_bag()               # P5: paragon gear-bag milestones raise the real cap (server trigger matches)
	if _gear_count >= cap:
		_set_cap_icon("inventory_full")          # capacity exhausted → the suitcase-with-X
		_cap_warn.text = "INVENTORY FULL  ·  %d / %d\nnew gear won't drop — sell items to make room" % [cap, cap]
		_cap_row.visible = true
	elif _gear_count >= cap - 5:
		_set_cap_icon("warning")                 # nearly full → a warning, NOT the full-state X
		_cap_warn.text = "BAG NEARLY FULL  ·  %d / %d\nsell items — new gear stops dropping at %d" % [_gear_count, cap, cap]
		_cap_row.visible = true
	else:
		_cap_row.visible = false

func _set_cap_icon(icon_id: String) -> void:
	if _cap_icon == null:
		return
	_cap_icon.texture = IconRegistry.texture(icon_id)
	_cap_icon.modulate = IconRegistry.color(icon_id)

# one-time after login: fetch the inventory so _gear_count (and the instant-open cache) is right immediately
func _seed_gear_count() -> void:
	if supa == null:
		return
	var r = await supa.get_inventory()
	if r.get("ok"):
		_inv_items = r.get("items", [])
		_recount_gear()

func _load_inventory() -> void:
	if supa == null or _inv_grid == null:
		return
	if _inv_loading:                         # coalesce concurrent loads → always show the latest result
		_inv_pending = true
		return
	_inv_loading = true
	if _inv_items.is_empty():                     # only show the blocking "loading…" on a cold first open;
		_inv_status.text = "loading…"             # a warm open already rendered the cache instantly above
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
	_recount_gear()                               # refresh the near-cap warning from the authoritative fetch
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
		_inv_controls.add_child(Widgets.toggle_btn(key.capitalize(), _inv_sort_mode == key, func() -> void:
			_inv_sort_mode = k_l
			_render_inv_tiles()))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_controls.add_child(spacer)
	var best := IconWidget.icon_button("power_action", "Equip Best", Palette.ACCENT, _equip_best)
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
		if ch is Button and (ch as Button).text == "Equip Best":
			(ch as Button).disabled = true
	for i in actions.size():
		var a = actions[i]
		_inv_status.text = "equipping best gear…  (%d/%d)" % [i + 1, actions.size()]
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
# the shared tile stylebox — now the ONE pattern-language factory (SB_NAVY body + rarity/cyan rail)
func _rarity_box(border: Color, hover: bool) -> StyleBoxFlat:
	return Widgets.tile_box(border, hover)

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
		p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND   # affordance: the card is clickable
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
	l.add_theme_color_override("font_color", Palette.TEXT_DIM)
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
	# state icons: Equipped / Upgrade ride the native Button.icon (left of the name); the Locked flag
	# is an INDEPENDENT top-right corner badge, so both can show at once (handoff §7).
	var state_icon := ""
	var state_col := col
	if bool(it.get("equipped", false)):
		state_icon = "equipped"
		state_col = Palette.SUCCESS
	elif _is_upgrade(it):                        # a bag item that beats what it'd replace → at-a-glance
		state_icon = "upgrade"
		state_col = Palette.SUCCESS
	if state_icon != "":
		b.icon = IconRegistry.texture(state_icon)
		b.expand_icon = false
		b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		b.add_theme_constant_override("icon_max_width", 16)
		b.add_theme_color_override("icon_normal_color", state_col)
		b.add_theme_color_override("icon_hover_color", state_col.lightened(0.2))
	b.text = str(it.get("name", "?"))
	if bool(it.get("locked", false)):
		var lk := IconWidget.make("locked", {"px": 13, "color": Palette.SB_ORANGE})   # decorative badge; lock cue is in the tile tooltip
		b.add_child(lk)
		lk.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 3)
	# common items were near-white on grey (low contrast) — lift the common tier to bright text
	var txt: Color = Palette.TEXT_BRIGHT if str(it.get("rarity", "common")) == "common" else col
	b.add_theme_color_override("font_color", txt)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.add_theme_color_override("font_pressed_color", txt)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND   # affordance: tiles are clickable
	b.add_theme_stylebox_override("normal", Widgets.tile_box(col, false))
	var sbh := Widgets.tile_box(col, true)
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
	b.custom_minimum_size = Vector2(190, 34)       # 28 was a sub-standard hit target
	b.clip_text = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if it == null:
		b.text = "%s:  —" % label
		b.disabled = true
		b.add_theme_color_override("font_disabled_color", Palette.TEXT_FAINT)
		return b
	b.text = "%s:  %s" % [label, str(it.get("name", "?"))]
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var rc: Color = _item_color(it)
	b.add_theme_color_override("font_color", Palette.TEXT_BRIGHT if str(it.get("rarity", "common")) == "common" else rc)
	b.add_theme_stylebox_override("normal", Widgets.tile_box(rc, false))   # rarity border, matching the bag
	b.add_theme_stylebox_override("hover", Widgets.tile_box(rc, true))
	b.add_theme_stylebox_override("pressed", Widgets.tile_box(rc, true))
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
func _quest_toast(line: String, icon := "") -> void:
	_toast(line, Palette.ACCENT, false, icon)
	_chat_lines.append(line)
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0
	_chat_box.modulate.a = 1.0

func _refresh_quests() -> void:
	_update_quest_tracker()

# P6b: server → client bounty nudge (a slot became claimable, or a claim resolved). Optimistically patch the
# cached META array so the giver panel reflects it instantly, toast, and re-render the panel if it's open.
func recv_bounty_update(bounty_id: String, progress: int, claimed: bool) -> void:
	var arr = _state.get("bounties", [])
	if arr is Array:
		for b in arr:
			if b is Dictionary and str(b.get("id", "")) == bounty_id:
				b["progress"] = progress
				b["claimed"] = claimed
				break
	if claimed:
		_quest_toast("[color=#ffd24d]Bounty claimed![/color]", "bounty")
	elif progress > 0:
		_quest_toast("[color=#9fe8a0]Bounty complete —[/color] ready to claim [color=#7f93a8](see the Quest Giver)[/color]", "bounty")
	if _qgiver_panel != null and _qgiver_panel.visible:
		_render_qgiver()
	if _quest_panel != null and _quest_panel.visible:
		_render_questlog()
	if _qgiver_panel != null and _qgiver_panel.visible:
		_render_qgiver()

# the always-on HUD tracker (active quests + progress). Rebuilt only on a quest event, not per
# frame. P6: rides a PANEL-tier chassis (the module node) with variants — standard (full rows),
# compact (smaller, max 4 + "+N more"), collapsed (title + count only).
func _update_quest_tracker() -> void:
	if _quest_tracker == null:
		var qf: Dictionary = HudFrame.fitted(HudFrame.Tier.PANEL, {"header": true, "body_alpha": 0.8})
		_qt_root = qf["root"]
		_hud.add_child(_qt_root)
		_quest_tracker = VBoxContainer.new()
		_quest_tracker.add_theme_constant_override("separation", 2)
		(qf["body"] as MarginContainer).add_child(_quest_tracker)
		var trow := HBoxContainer.new()
		trow.add_theme_constant_override("separation", 6)
		_quest_tracker.add_child(trow)
		_quest_tracker_title = HudFonts.display_label("Quests", 13, Palette.SB_CYAN, 0.18)
		_quest_tracker_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		trow.add_child(_quest_tracker_title)
		_qt_count = Label.new()                      # "(J)" and punctuation live in the body font
		_qt_count.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
		_qt_count.add_theme_color_override("font_color", Palette.TEXT_DIM)
		_qt_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		trow.add_child(_qt_count)
		# module registration LAST — on_variant fires inside register (re-entering this function),
		# so the title row must already exist. Anchored top-right: the list grows leftward.
		HudLayout.register("quest_tracker", _qt_root, {"label": "Quest Tracker",
			"defaults": {"anchor": "top_right", "ox": -20.0, "oy": 150.0},   # unchanged (minimap is off by default)
			"ref_size": Vector2(240, 110), "preview": _quest_tracker_preview,
			"variants": ["standard", "compact", "collapsed"], "on_variant": _qt_set_variant})
	var trow_node := _quest_tracker_title.get_parent()
	for c in _quest_tracker.get_children():          # clear the per-quest lines, keep the title row
		if c != trow_node:
			c.queue_free()
	var compact := _qt_variant == "compact"
	var collapsed := _qt_variant == "collapsed"
	var rows := 0
	var total := 0
	var overflow := 0
	for qid in Quests.display_order():
		if not _quests.has(qid):
			continue
		var st = _quests[qid]
		if bool(st.get("completed", false)):
			continue
		var q = Quests.get_quest(qid)
		if q == null:
			continue
		total += 1
		if collapsed:
			continue
		if compact and rows >= 4:
			overflow += 1
			continue
		rows += 1
		var cnt := int(q["objective"]["count"])
		var prog := int(st.get("progress", 0))
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 11 if compact else 12)
		if prog >= cnt:
			lbl.text = "✓ %s  (ready)" % str(q["name"])
			lbl.modulate = Color(0.62, 0.9, 0.55)
		else:
			lbl.text = "• %s  %d/%d" % [str(q["name"]), prog, cnt]
			lbl.modulate = Color(0.85, 0.88, 0.95)
		_quest_tracker.add_child(lbl)
	if overflow > 0:
		var more := Label.new()
		more.text = "+%d more  (J)" % overflow
		more.add_theme_font_size_override("font_size", 11)
		more.modulate = Color(0.6, 0.68, 0.78)
		_quest_tracker.add_child(more)
	if _qt_preview and total == 0 and not collapsed:   # HUD-edit placeholder: keep it placeable
		for txt in ["• Sample quest  2/5", "✓ Sample quest  (ready)"]:
			var pl := Label.new()
			pl.add_theme_font_size_override("font_size", 11 if compact else 12)
			pl.modulate = Color(0.7, 0.78, 0.9, 0.85)
			pl.text = txt
			_quest_tracker.add_child(pl)
		total = 2
	elif _qt_preview and total == 0:
		total = 2                                    # collapsed preview: title + count chip
	_qt_count.text = ("(J) · %d" % total) if collapsed else "(J)"
	_qt_root.visible = total > 0

# module variant hook — re-render the rows in the new density
func _qt_set_variant(v: String) -> void:
	_qt_variant = v
	if _quest_tracker != null and _quest_tracker_title != null:
		_update_quest_tracker()

# HUD-edit preview hook (HudLayout.set_preview): materialize the tracker with sample rows so an
# empty quest list doesn't leave the module invisible/unplaceable in the editor.
func _quest_tracker_preview(on: bool) -> void:
	_qt_preview = on
	_update_quest_tracker()

func _build_questlog() -> void:
	var p := Widgets.panel("Quest Journal", "J / Esc", 560.0, _toggle_questlog, true, {"icon": "quest", "persist": "quest_journal", "legacy": "Quest Journal"})   # phase B: marquee chrome
	_quest_panel = p["root"]
	_hud.add_child(_quest_panel)
	var vb: VBoxContainer = p["body"]
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(520, 440)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(sc)
	_quest_rows = VBoxContainer.new()
	_quest_rows.add_theme_constant_override("separation", 5)
	_quest_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_quest_rows)

# a read-only journal card: a rail-colored tile framing a rich quest line (name/progress/desc)
func _journal_card(bb: String, rail: Color) -> PanelContainer:
	var c := PanelContainer.new()
	c.add_theme_stylebox_override("panel", Widgets.tile_box(rail, false))
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.custom_minimum_size = Vector2(476, 0)
	l.text = bb
	c.add_child(l)
	return c

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
	if _quest_rows == null:
		return
	for c in _quest_rows.get_children():
		c.queue_free()
	var dim := Palette.hex(Palette.TEXT_DIM)
	var faint := Palette.hex(Palette.TEXT_FAINT)
	var body := Palette.hex(Palette.TEXT)
	var pf = _find_fighter(_player_id)
	var lvl := int(pf.get("level", 1)) if pf != null else 1
	var active := []      # [{bb, ready}]
	var avail := []
	var locked := []
	var done := []
	for qid in Quests.display_order():
		var q = Quests.get_quest(qid)
		if q == null:
			continue
		var cnt := int(q["objective"]["count"])
		var nm: String = _esc(str(q["name"]))
		var desc: String = _esc(str(q.get("desc", "")))
		if _quests.has(qid):
			var st = _quests[qid]
			if bool(st.get("completed", false)):
				done.append("[color=%s]✓ %s[/color]" % [dim, nm])
			else:
				var prog := int(st.get("progress", 0))
				if prog >= cnt:
					active.append({"bb": "[b][color=%s]%s[/color][/b]  [color=%s](ready — turn in at the Quest Giver)[/color]\n[color=%s]%s[/color]" % [Palette.hex(Palette.SUCCESS), nm, Palette.hex(Palette.SUCCESS), dim, desc], "ready": true})
				else:
					active.append({"bb": "[b][color=%s]%s[/color][/b]  [color=%s]%d/%d[/color]\n[color=%s]%s[/color]" % [body, nm, Palette.hex(Palette.ACCENT2), prog, cnt, dim, desc], "ready": false})
		else:
			var prereq := str(q.get("prereq", ""))
			var minl := int(q.get("min_level", 1))
			var prereq_ok: bool = prereq == "" or (_quests.has(prereq) and bool(_quests[prereq].get("completed", false)))
			if lvl >= minl and prereq_ok:
				avail.append("[b][color=%s]%s[/color][/b]\n[color=%s]%s[/color]  [color=%s](reward: %s)[/color]" % [body, nm, dim, desc, faint, _reward_text(q)])
			else:
				var reason: String = ("needs lvl %d" % minl) if lvl < minl else ("requires: %s" % _esc(_prereq_name(prereq)))
				locked.append("[color=%s]%s  (%s)[/color]" % [faint, nm, reason])
	_quest_rows.add_child(_qg_info("[color=%s]Accept & turn in quests at the [color=%s]Quest Giver[/color] in the Home Base (press E near it).[/color]" % [dim, Palette.hex(Palette.ACCENT)]))
	var teaser := _secret_teaser()
	if teaser != "":
		_quest_rows.add_child(_qg_info(teaser))
	if not active.is_empty():
		_quest_rows.add_child(Widgets.section("Active"))
		for a in active:
			_quest_rows.add_child(_journal_card(a["bb"], Palette.SB_LIME if a["ready"] else Palette.SB_CYAN))
	if not avail.is_empty():
		_quest_rows.add_child(Widgets.section("Available"))
		for a in avail:
			_quest_rows.add_child(_journal_card(a, Palette.SUCCESS))
	if not locked.is_empty():
		_quest_rows.add_child(Widgets.section("Locked"))
		_quest_rows.add_child(_qg_info("\n".join(locked)))
	if not done.is_empty():
		_quest_rows.add_child(Widgets.section("Completed"))
		_quest_rows.add_child(_qg_info("\n".join(done)))
	if active.is_empty() and avail.is_empty() and locked.is_empty() and done.is_empty():
		_quest_rows.add_child(_qg_info("[color=%s]No quests available yet.[/color]" % dim))

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
		return "\n[color=#ffd24d]• The Final Lesson is open — seek what waits past the Head Coach Arena.[/color]"
	var key_txt: String = "[color=#9fe8a0]Master Key forged[/color]" if _has_key() else "[color=#7f93a8]forge the Master Key (Camp Circuit)[/color]"
	return "\n[color=#8a7fb0]• A hidden challenge stirs —[/color] [color=#cdbcff]%d/%d quests done[/color] · %s" % [ndone, total, key_txt]

func _reward_text(q: Dictionary) -> String:
	var rw: Dictionary = q.get("rewards", {})
	var parts := []
	if int(rw.get("xp", 0)) > 0:
		parts.append("[color=#9fe8a0]%d XP[/color]" % int(rw["xp"]))
	if int(rw.get("credits", 0)) > 0:
		parts.append("[color=#ffd24d]%d credits[/color]" % int(rw["credits"]))
	if int(rw.get("tokens", 0)) > 0:                       # P6a: Practice Tokens
		parts.append("[color=#8ad6ff]%d Tokens[/color]" % int(rw["tokens"]))
	if int(rw.get("pages", 0)) > 0:                        # P6a: Playbook Pages (attunement)
		parts.append("[color=#cdbcff]%d Pages[/color]" % int(rw["pages"]))
	if rw.has("item"):
		var rar := str((rw["item"] as Dictionary).get("rarity", ""))
		parts.append("[color=%s]◆ %s item[/color]" % [RARITY_COLORS.get(rar, "#cfd6df"), rar])
	if rw.has("dye") and str(rw["dye"]) != "":            # P6a: cosmetic dye
		parts.append("[color=#ff9fd0]+dye[/color]")
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
	elif p.size() >= 2 and p[0] == "bounty_claim":   # P6b: claim a completed bounty (co-located at the same giver)
		net.bounty_action.rpc_id(1, "claim", p[1])

# ---- quest giver (home-base NPC: the ONLY place to accept / turn in; J is a read-only journal) ----
func _build_qgiver_dialog() -> void:
	var p := Widgets.panel("Quest Giver", "E / Esc", 560.0, _toggle_qgiver, true, {"icon": "quest_giver", "persist": "quest_giver", "legacy": "📜 Quest Giver"})   # phase B: marquee chrome
	_qgiver_panel = p["root"]
	_hud.add_child(_qgiver_panel)
	var vb: VBoxContainer = p["body"]
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(520, 440)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(sc)
	_qgiver_rows = VBoxContainer.new()               # rows: section headers, action rows, info lines
	_qgiver_rows.add_theme_constant_override("separation", 5)
	_qgiver_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(_qgiver_rows)

# an action row: a REAL button (Accept / Turn In / Claim) + a rich description — replaces the
# old bbcode [url] text links (glyph-only hit targets with no button affordance)
func _qg_action_row(label: String, accent: Color, on_press: Callable, desc_bb: String) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(92, 32)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_color_override("font_color", accent)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	if on_press.is_valid():
		b.pressed.connect(on_press)
	hb.add_child(b)
	var d := RichTextLabel.new()
	d.bbcode_enabled = true
	d.fit_content = true
	d.scroll_active = false
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	d.custom_minimum_size = Vector2(400, 0)
	d.text = desc_bb
	hb.add_child(d)
	return hb

func _qg_info(bb: String) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.scroll_active = false
	l.custom_minimum_size = Vector2(500, 0)
	l.text = bb
	return l

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
	if _qgiver_rows == null:
		return
	for c in _qgiver_rows.get_children():
		c.queue_free()
	var faint := Palette.hex(Palette.TEXT_FAINT)
	var body := Palette.hex(Palette.TEXT)
	var pf = _find_fighter(_player_id)
	var lvl := int(pf.get("level", 1)) if pf != null else 1
	var ready := []      # {qid, nm, reward}
	var avail := []      # {qid, nm, desc, reward}
	var active := []     # bbcode strings (info-only)
	for qid in Quests.display_order():
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
				ready.append({"qid": qid, "nm": nm, "reward": _reward_text(q)})
			else:
				active.append("[color=%s]%s[/color]  [color=%s]%d/%d[/color]" % [body, nm, Palette.hex(Palette.ACCENT2), prog, cnt])
		else:
			var prereq := str(q.get("prereq", ""))
			var minl := int(q.get("min_level", 1))
			var prereq_ok: bool = prereq == "" or (_quests.has(prereq) and bool(_quests[prereq].get("completed", false)))
			if lvl >= minl and prereq_ok:
				avail.append({"qid": qid, "nm": nm, "desc": desc, "reward": _reward_text(q)})
	var any := false
	if not ready.is_empty():
		_qgiver_rows.add_child(Widgets.section("Ready to turn in"))
		for r in ready:
			var rid := str(r["qid"])
			_qgiver_rows.add_child(_qg_action_row("Turn In", Palette.SUCCESS,
				func() -> void: _on_quest_meta("turnin|" + rid),
				"[color=%s]%s[/color]  [color=%s](reward: %s)[/color]" % [Palette.hex(Palette.SUCCESS), r["nm"], faint, r["reward"]]))
		any = true
	if not avail.is_empty():
		_qgiver_rows.add_child(Widgets.section("Available"))
		for a in avail:
			var aid := str(a["qid"])
			_qgiver_rows.add_child(_qg_action_row("Accept", Palette.SB_CYAN,
				func() -> void: _on_quest_meta("accept|" + aid),
				"[color=%s]%s[/color]\n[color=%s]%s[/color]  [color=%s](reward: %s)[/color]" % [body, a["nm"], Palette.hex(Palette.TEXT_DIM), a["desc"], faint, a["reward"]]))
		any = true
	if not active.is_empty():
		_qgiver_rows.add_child(Widgets.section("In progress"))
		_qgiver_rows.add_child(_qg_info("\n".join(active)))
		any = true
	# P6b: daily/weekly bounties — server-pushed via the HOME snapshot META, claimed here.
	var bounties = _state.get("bounties", [])
	if bounties is Array and not (bounties as Array).is_empty():
		var drows := []
		var wrows := []
		var dend := 0
		var wend := 0
		for b in bounties:
			if not (b is Dictionary):
				continue
			var bid := str(b.get("id", ""))
			var bnm: String = _esc(str(b.get("name", "")))
			var bcnt := int(b.get("count", 1))
			var bprog := int(b.get("progress", 0))
			var row: Control
			if bool(b.get("claimed", false)):
				row = _qg_info("[color=%s]✓ %s — claimed[/color]" % [faint, bnm])
			elif bprog >= bcnt:
				var cid := bid
				row = _qg_action_row("Claim", Palette.ACCENT,
					func() -> void: _on_quest_meta("bounty_claim|" + cid),
					"[color=%s]%s[/color]  [color=%s](%s)[/color]" % [Palette.hex(Palette.SUCCESS), bnm, faint, _reward_text(b)])
			else:
				row = _qg_info("[color=%s]%s[/color]  [color=%s]%d/%d[/color]\n[color=%s]%s[/color]  [color=%s](%s)[/color]" % [body, bnm, Palette.hex(Palette.ACCENT2), bprog, bcnt, Palette.hex(Palette.TEXT_DIM), _esc(str(b.get("desc", ""))), faint, _reward_text(b)])
			if bool(b.get("weekly", false)):
				wrows.append(row)
				wend = int(b.get("period_end", 0))
			else:
				drows.append(row)
				dend = int(b.get("period_end", 0))
		if not drows.is_empty():
			_qgiver_rows.add_child(Widgets.section("Daily Bounties  (resets in %s)" % _bounty_countdown(dend)))
			for r in drows:
				_qgiver_rows.add_child(r)
			any = true
		if not wrows.is_empty():
			_qgiver_rows.add_child(Widgets.section("Weekly Bounty  (resets in %s)" % _bounty_countdown(wend)))
			for r in wrows:
				_qgiver_rows.add_child(r)
			any = true
	if not any:
		_qgiver_rows.add_child(_qg_info("[color=%s]Nothing for you right now — come back after you level up or finish a quest.[/color]" % Palette.hex(Palette.TEXT_DIM)))

# P6b: a display-only countdown to the next UTC reset, from the server-pushed period_end epoch (never fed to the sim).
func _bounty_countdown(period_end: int) -> String:
	var rem := int(period_end) - int(Time.get_unix_time_from_system())
	if rem < 0:
		rem = 0
	var d := rem / 86400
	var h := (rem % 86400) / 3600
	var m := (rem % 3600) / 60
	if d > 0:
		return "%dd %dh" % [d, h]
	return "%dh %dm" % [h, m]

# home-only pads (shop/forge/questgiver/practice/build_shop/locker_portal) ride the change-detected snapshot
# META cache. Gate every read on the per-tick `map` — not the mere presence of the cached key — so a META held
# across a zone exit (if that one packet drops) can't leave a phantom pad pillar + interact prompt in the new
# zone. Returns null off-home, which each render/proximity fn already treats as "tear the pad down".
func _home_pad(key: String):
	return _state.get(key) if str(_state.get("map", "")) == World.HOME else null

# the blue quest-giver marker in the home base + the "press E" proximity prompt (mirrors the shop pad)
func _render_questgiver_pad() -> void:
	var qg = _home_pad("questgiver")
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
	_qgiver_root.add_child(WorldUI.pad_marker("quest_giver", "Quest Giver",
		Color(0.72, 0.85, 1.0), pos + Vector3(0.0, 3.4, 0.0)))

func _update_questgiver_proximity() -> void:
	var qg = _home_pad("questgiver")
	var pf = _find_fighter(_player_id)
	_near_qgiver = false
	if qg != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(qg["x"]), float(pf["y"]) - float(qg["y"])).length()
		_near_qgiver = d <= World.QUESTGIVER_RADIUS
	if _near_qgiver and (_qgiver_panel == null or not _qgiver_panel.visible):
		_interact_offer("questgiver", "E", "Talk to the Quest Giver")
	else:
		_interact_clear("questgiver")
	if not _near_qgiver and _qgiver_panel != null and _qgiver_panel.visible:
		_qgiver_panel.visible = false                  # walked away → close the dialog

# ---- settings (audio volumes + mute; persisted by AudioManager to user://settings.cfg) ----
func _build_settings() -> void:
	var p := Widgets.panel("Settings", "O / Esc", 400.0, _toggle_settings, false, {"icon": "settings", "persist": "settings", "legacy": "Settings"})
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
	rfx.tooltip_text = "Softens camera shake; turns off hit camera-kick, zoom-punch, hitstop — and HUD motion (banner fades, toast slides, frame glow)"
	rfx.button_pressed = reduce_fx
	rfx.toggled.connect(func(on: bool) -> void:
		set_reduce_fx(on)
		HudFrame.reduced = on)                   # pattern chrome drops its glow layers with the rest
	vb.add_child(rfx)
	# --- HUD: layout profile + edit mode + resets. (The old global "UI scale" slider was
	# removed — it rescaled the whole viewport and fought the per-module F2 sizing; ALL sizing is
	# now done per-module in F2 edit mode, which is cleaner and doesn't "go crazy".)
	vb.add_child(Widgets.section("HUD"))
	# P11: layout profile + bulk opacity + fit-to-screen live here too (per-module fine-tuning
	# stays in F2 edit mode — settings holds only the whole-HUD knobs)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	var plbl := Label.new()
	plbl.text = "Layout"
	plbl.custom_minimum_size = Vector2(70, 0)
	prow.add_child(plbl)
	var popt := OptionButton.new()
	popt.focus_mode = Control.FOCUS_NONE
	for pn in HudLayout.profile_names():
		popt.add_item(str(pn).capitalize())
	var pidx: int = HudLayout.profile_names().find(HudLayout.profile())
	if pidx >= 0:
		popt.select(pidx)
	popt.item_selected.connect(func(idx: int) -> void:
		HudLayout.apply_profile(str(HudLayout.profile_names()[idx]))
		HudLayout.save()
		_settings_status("HUD profile applied"))
	prow.add_child(popt)
	vb.add_child(prow)
	var orow := HBoxContainer.new()
	orow.add_theme_constant_override("separation", 10)
	var olbl := Label.new()
	olbl.text = "HUD opacity"
	olbl.custom_minimum_size = Vector2(70, 0)
	orow.add_child(olbl)
	var osl := HSlider.new()
	osl.min_value = HudLayout.OPACITY_MIN
	osl.max_value = 1.0
	osl.step = 0.05
	osl.value = 1.0
	osl.custom_minimum_size = Vector2(240, 0)
	osl.tooltip_text = "Bulk opacity for every HUD module (fine-tune per module in F2)"
	osl.value_changed.connect(func(v: float) -> void: HudLayout.set_all_opacity(v))
	osl.drag_ended.connect(func(_ch: bool) -> void:
		HudLayout.save()
		_settings_status("HUD opacity saved"))
	orow.add_child(osl)
	vb.add_child(orow)
	var edit_hud := Button.new()
	edit_hud.text = "Edit HUD Layout  (F2)"
	edit_hud.tooltip_text = "Move, scale, hide and re-anchor HUD modules"
	edit_hud.pressed.connect(func() -> void:
		_settings_panel.visible = false
		_hud_edit_toggle())
	vb.add_child(edit_hud)
	var fit_hud := Button.new()
	fit_hud.text = "Fit Layout to Screen"
	fit_hud.tooltip_text = "Pull any module that ended up outside the window back into view"
	fit_hud.pressed.connect(func() -> void:
		HudLayout.fit_all_to_screen()
		HudLayout.save()
		_settings_status("Layout fitted to screen"))
	vb.add_child(fit_hud)
	var reset_hud := Button.new()
	reset_hud.text = "Reset HUD Layout"
	reset_hud.tooltip_text = "Restore every HUD module to its default position/scale (audio + window settings untouched)"
	reset_hud.pressed.connect(func() -> void:
		HudLayout.erase_saved()
		_settings_status("HUD layout reset"))
	vb.add_child(reset_hud)
	var reset_ui := Button.new()                 # recover from a window dragged/resized off-screen
	reset_ui.text = "Reset Window Positions"
	reset_ui.tooltip_text = "Re-center every panel window and clear saved window positions/sizes"
	reset_ui.pressed.connect(func() -> void:
		Widgets.reset_all_windows()
		_settings_status("Window positions reset"))
	vb.add_child(reset_ui)
	_settings_reset_note = Label.new()
	_settings_reset_note.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	_settings_reset_note.add_theme_color_override("font_color", Palette.XP)
	vb.add_child(_settings_reset_note)
	var sep := HSeparator.new()
	vb.add_child(sep)
	var controls_btn := Button.new()             # the full keybind reference (retired from the always-on HUD line)
	controls_btn.text = "Controls"
	controls_btn.tooltip_text = "See every keyboard + mouse control"
	controls_btn.pressed.connect(_toggle_controls)
	vb.add_child(controls_btn)
	var logout := Button.new()                   # log out → back to the login screen (no more quit-and-relaunch)
	logout.text = "Log Out"
	logout.pressed.connect(func() -> void: logout_requested.emit())
	vb.add_child(logout)

# The full control reference — grouped keycap rows. Replaces the always-on bottom keybind line;
# reachable from Settings → Controls. Static content (no per-frame work); built once, lazily.
const CONTROLS := [
	["Movement & Combat", [["W A S D", "Move (camera-relative)"], ["1 – 8", "Use abilities"], ["LMB", "Basic attack"]]],
	["Camera", [["RMB drag", "Rotate camera"], ["Mouse wheel", "Zoom in / out"]]],
	["Targeting", [["Tab", "Target nearest enemy"], ["Ctrl + Tab", "Target an ally"], ["Click party frame", "Target that ally"], ["Esc", "Clear target"]]],
	["Party", [["RMB a player", "Invite to your party"]]],
	["Panels", [["I", "Inventory"], ["K", "Character sheet"], ["J", "Quest journal"], ["U", "Locker loadout"], ["G", "Wardrobe (dyes)"], ["T", "Talents"], ["B", "Bench (paragon)"], ["L", "Leaderboards"], ["N", "DPS / HPS meter"], ["O", "Settings"]]],
	["At a home-base pad", [["B", "Shop"], ["F", "Forge"], ["E", "Quest giver"], ["V", "Practice vendor"], ["C", "Camp circuit"], ["P", "Build shop"], ["Y", "Buy your locker room"]]],
	["HUD & Chat", [["F2", "Edit HUD layout"], ["Enter", "Open / send chat"], ["Esc", "Close panel / cancel"], ["F4", "Build mode (in your locker)"], ["H", "Build help (in your locker)"]]],
]
var _controls_panel: Control = null

func _build_controls() -> void:
	var p := Widgets.panel("Controls", "Esc", 460.0, _toggle_controls, false, {"icon": "controls", "persist": "controls", "legacy": "Controls"})
	_controls_panel = p["root"]
	_hud.add_child(_controls_panel)
	var vb: VBoxContainer = p["body"]
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(420, 480)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(sc)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 4)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(rows)
	for grp in CONTROLS:
		rows.add_child(Widgets.section(str(grp[0])))
		for entry in grp[1]:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 12)
			var cap := PanelContainer.new()      # keycap chip (matches the hotbar / interact prompt)
			var csb := StyleBoxFlat.new()
			csb.bg_color = Color(Palette.SB_INK, 0.9)
			csb.set_border_width_all(1)
			csb.border_color = Color(Palette.SB_CYAN, 0.4)
			csb.set_corner_radius_all(3)
			csb.content_margin_left = 7.0
			csb.content_margin_right = 7.0
			csb.content_margin_top = 2.0
			csb.content_margin_bottom = 2.0
			cap.add_theme_stylebox_override("panel", csb)
			cap.custom_minimum_size = Vector2(128, 0)
			var kl := Label.new()
			kl.text = str(entry[0])
			kl.add_theme_color_override("font_color", Palette.SB_CYAN)
			cap.add_child(kl)
			row.add_child(cap)
			var dl := Label.new()
			dl.text = str(entry[1])
			dl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			dl.add_theme_color_override("font_color", Palette.TEXT)
			row.add_child(dl)
			rows.add_child(row)

func _toggle_controls() -> void:
	if _controls_panel == null:
		return
	_controls_panel.visible = not _controls_panel.visible

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
	var p := Widgets.panel("Shop", "B / Esc", 1010.0, _toggle_shop, true, {"icon": "shop", "persist": "shop", "legacy": "Shop"})   # phase B: marquee chrome
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
	# UI-consistency pass: the four stacked control rows (mode/select/sort/slot) sit on an inset
	# backdrop so they group as one block against the opaque window body instead of four loose lines
	var ctrlwrap := PanelContainer.new()
	var cwsb := StyleBoxFlat.new()
	cwsb.bg_color = Color(Palette.SB_INK, 0.55)
	cwsb.set_border_width_all(1)
	cwsb.border_color = Color(Palette.SB_CYAN, 0.14)
	cwsb.set_corner_radius_all(5)
	cwsb.set_content_margin_all(7)
	ctrlwrap.add_theme_stylebox_override("panel", cwsb)
	sellcol.add_child(ctrlwrap)
	_shop_sell_controls = VBoxContainer.new()
	_shop_sell_controls.add_theme_constant_override("separation", 3)
	ctrlwrap.add_child(_shop_sell_controls)
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
	var p := Widgets.panel("Practice Vendor", "V / Esc", 580.0, _toggle_vendor, true, {"icon": "practice_vendor", "persist": "practice_vendor", "legacy": "◈ Practice Vendor — Rookie Camp Set"})   # phase B: marquee chrome
	_vendor_panel = p["root"]
	_hud.add_child(_vendor_panel)
	var vb: VBoxContainer = p["body"]
	vb.add_child(Widgets.section("ROOKIE CAMP SET"))   # subtitle moved out of the window title (handoff §6)
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
	var p := Widgets.panel("Camp Circuit", "C / Esc", 560.0, _toggle_camp, true, {"icon": "camp_circuit", "persist": "camp_circuit", "legacy": "⚔ Camp Circuit — Select Intensity"})   # phase B: marquee chrome
	_camp_panel = p["root"]
	_hud.add_child(_camp_panel)
	var vb: VBoxContainer = p["body"]
	vb.add_child(Widgets.section("SELECT INTENSITY"))   # subtitle moved out of the window title (handoff §6)
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
		var top := tier == mx
		var card := PanelContainer.new()                   # each tier is a selectable difficulty card
		card.add_theme_stylebox_override("panel", Widgets.tile_box(Palette.SB_LIME if top else Palette.SB_CYAN, false))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var lbl := Label.new()
		lbl.text = "Intensity %d" % tier
		lbl.add_theme_font_size_override("font_size", Palette.SIZE_SECTION)
		lbl.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lbl)
		if top:
			var chip := Widgets.chip("NEW — clear to advance", Palette.SB_LIME)
			chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(chip)
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)
		var btn := Button.new()
		btn.text = "Enter"
		btn.pressed.connect(_on_enter_camp.bind(tier))
		row.add_child(btn)
		_camp_rows.add_child(card)
	# --- attunement (P2): Playbook Pages + the Master Key forge ---
	var sep := HSeparator.new()
	_camp_rows.add_child(sep)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	var plbl := Label.new()
	plbl.text = "Playbook Pages:  %d / %d" % [_my_pages(), _key_cost()]
	plbl.add_theme_color_override("font_color", Palette.TOKENS)
	plbl.custom_minimum_size = Vector2(360, 0)
	prow.add_child(plbl)
	if _has_key():
		prow.add_child(IconWidget.row("attunement_key", "Master Key forged",
			{"px": 18, "color": Palette.ACCENT, "text_color": Palette.ACCENT}))
	else:
		var kbtn := IconWidget.icon_button("attunement_key", "Forge Master Key", Palette.TEXT_BRIGHT, _on_craft_key)
		kbtn.disabled = _my_pages() < _key_cost()
		prow.add_child(kbtn)
	_camp_rows.add_child(prow)
	var khint := Label.new()
	khint.text = "The Master Key + every quest done opens the secret boss. Earn Pages from Circuit clears (more at higher Intensity) + the Head Coach."
	khint.add_theme_color_override("font_color", Palette.TEXT_DIM)
	khint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camp_rows.add_child(khint)
	# --- Audibles (P5): the repeatable Pages sink — per-run consumables for your NEXT Camp run ---
	_camp_rows.add_child(HSeparator.new())
	_camp_rows.add_child(Widgets.section("Audibles — spend Pages on your next Camp run"))
	var pend := _my_pending_audible()
	var queued := []
	if str(pend.get("affix", "")) != "":
		queued.append("Affix: %s" % str(GameData.AUDIBLE_CATALOG.get("affix_%s" % str(pend["affix"]), {}).get("name", pend["affix"])).replace("Call: ", ""))
	if bool(pend.get("bonus", false)):
		queued.append("Extra Scouting")
	var qlbl := Label.new()
	qlbl.text = ("✓ Queued for next run: %s" % ", ".join(queued)) if not queued.is_empty() else "Nothing queued. Buy an Audible, then Enter a Camp run."
	qlbl.add_theme_color_override("font_color", Palette.SUCCESS if not queued.is_empty() else Palette.TEXT_FAINT)
	qlbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_camp_rows.add_child(qlbl)
	for aid in GameData.AUDIBLE_CATALOG:
		var ad: Dictionary = GameData.AUDIBLE_CATALOG[aid]
		var arow := HBoxContainer.new()
		arow.add_theme_constant_override("separation", 10)
		var albl := Label.new()
		albl.text = "%s — %s" % [str(ad["name"]).replace("Call: ", ""), str(ad["desc"])]
		albl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		albl.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
		albl.add_theme_color_override("font_color", Palette.TEXT_DIM)
		arow.add_child(albl)
		var already := (str(ad.get("type", "")) == "affix" and str(pend.get("affix", "")) == str(ad.get("affix", ""))) or (str(ad.get("type", "")) == "bonus" and bool(pend.get("bonus", false)))
		var abtn: Button
		if already:
			abtn = _tile_btn("✓ Queued", Palette.SUCCESS, false, Callable())   # ✓ stays code-native
		else:                                                                  # cost is in Playbook Pages, not credits
			abtn = IconWidget.icon_button("playbook_pages", "%d" % int(ad["cost"]), Palette.TEXT_BRIGHT,
				_on_buy_audible.bind(str(aid)), {"px": 16, "icon_color": Palette.LAVENDER})
		abtn.disabled = already or _my_pages() < int(ad["cost"])
		arow.add_child(abtn)
		_camp_rows.add_child(arow)

func _my_pending_audible() -> Dictionary:
	var p = _state.get("self", {}).get("pending_audible", {})
	return (p if p is Dictionary else {})

func _on_buy_audible(id: String) -> void:
	if net != null:
		net.buy_audible.rpc_id(1, id)

# server → client: an Audible was bought (pending set, Pages spent) — refresh the camp panel live
func recv_audible(pending: Dictionary, pages: int) -> void:
	if _state.has("self"):
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["pending_audible"] = pending
		me["pages"] = pages
		_meta["self"] = me
		_state["self"] = me
	_quest_toast("[color=#8ad6ff]Audible queued for your next Camp run.[/color]", "objectives")
	if _camp_panel != null and _camp_panel.visible:
		_render_camp()

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
	_show_banner("Victory", "Circuit Clear", "Intensity %d" % intensity)   # P8 hero banner
	_quest_toast("[color=#ffd24d]Circuit Cleared — Intensity %d![/color]  Bonus loot + Pages awarded." % intensity, "camp_circuit")
	if max_intensity > intensity:
		_quest_toast("[color=#9fe8a0]Intensity %d unlocked![/color]" % max_intensity, "unlocked")
	if _camp_panel != null and _camp_panel.visible:
		_render_camp()                            # refresh the Pages counter live

# server → client: the Master Key was forged
func recv_key_crafted(ok: bool) -> void:
	if ok:
		_quest_toast("[color=#ffd24d]Master Key forged![/color]  The Final Lesson awaits past the Head Coach Arena.", "attunement_key")
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
	var p := Widgets.panel("Wardrobe", "G / Esc", 600.0, _toggle_wardrobe, true, {"icon": "wardrobe", "persist": "wardrobe", "legacy": "🎨 Wardrobe — Dyes"})   # phase B: marquee chrome
	_wardrobe_panel = p["root"]
	_hud.add_child(_wardrobe_panel)
	var vb: VBoxContainer = p["body"]
	vb.add_child(Widgets.section("DYES"))   # subtitle moved out of the window title (handoff §6)
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
	_wardrobe_status.text = "Credits:  %d       Equipped:  %s" % [_my_credits_val(), (str(GameData.DYE_CATALOG.get(equipped, {}).get("name", "—")) if equipped != "" else "Default")]
	for c in _wardrobe_rows.get_children():
		c.queue_free()
	# a "Default (no dye)" row first
	_wardrobe_rows.add_child(_dye_row("", "Default (no dye)", "#8a8f98", owned, equipped))
	for id in GameData.DYE_IDS:
		var d: Dictionary = GameData.DYE_CATALOG[id]
		_wardrobe_rows.add_child(_dye_row(str(id), str(d["name"]), str(d["color"]), owned, equipped))
	for oid in owned:                                # P7d: grant-only cosmetics (the Season Champion tint) aren't in DYE_IDS → an Equip-only row (owned never hits the Buy branch, so no missing-price crash)
		if not (str(oid) in GameData.DYE_IDS) and GameData.DYE_CATALOG.has(str(oid)):
			var sd: Dictionary = GameData.DYE_CATALOG[str(oid)]
			_wardrobe_rows.add_child(_dye_row(str(oid), str(sd.get("name", oid)), str(sd.get("color", "#ffffff")), owned, equipped))

func _dye_row(id: String, dye_name: String, color_hex: String, owned: Array, equipped: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var swatch := PanelContainer.new()           # framed so dark/navy dyes still read against the panel
	var ssb := StyleBoxFlat.new()
	ssb.bg_color = Color(color_hex)
	ssb.set_border_width_all(1)
	ssb.border_color = Color(1, 1, 1, 0.35)
	ssb.set_corner_radius_all(4)
	swatch.add_theme_stylebox_override("panel", ssb)
	swatch.custom_minimum_size = Vector2(26, 26)
	row.add_child(swatch)
	var lbl := Label.new()
	lbl.text = dye_name
	lbl.custom_minimum_size = Vector2(300, 0)
	row.add_child(lbl)
	if id == equipped:
		var eq := Label.new()
		eq.text = "✓ Equipped"
		eq.add_theme_color_override("font_color", Palette.SUCCESS)
		row.add_child(eq)
	elif id == "" or id in owned:
		var btn := Button.new()
		btn.text = "Equip"
		btn.pressed.connect(_on_equip_dye.bind(id))
		row.add_child(btn)
	else:
		var price := int(GameData.DYE_CATALOG[id]["price"])
		var btn := IconWidget.icon_button("credits", "Buy  %d" % price, Palette.TEXT_BRIGHT,
			_on_buy_dye.bind(id), {"px": 16, "icon_color": Palette.CREDITS})
		btn.disabled = _my_credits_val() < price
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
		# _state["self"] aliases the cached _meta["self"] — copy-on-write into a fresh dict and store it in BOTH,
		# else the next meta-less tick's overlay (snap["self"] = _meta["self"]) would restore the OLD cosmetics.
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["cos_owned"] = owned
		me["cos_dye"] = equipped
		_meta["self"] = me
		_state["self"] = me
	if _wardrobe_panel != null and _wardrobe_panel.visible:
		_render_wardrobe()
	_quest_toast("[color=#8ad6ff]Wardrobe updated.[/color]", "wardrobe")

# ---- Talent trees (gameplay-length P4): spend 1 point/level into a class-symmetric 3-branch stat tree ----
const _TALENT_STAT_LABEL := {
	"PWR": "Power (damage)", "PRE": "Precision (crit chance)", "END": "Endurance (max HP)",
	"CLU": "Clutch (comeback edge)", "SPD": "Speed (movement)", "INS": "Insight (cooldowns)"}

func _my_class() -> String:
	return str(_state.get("self", {}).get("classId", ""))
func _my_level_val() -> int:
	return int(_state.get("self", {}).get("level", 1))
func _my_talents() -> Dictionary:
	var t = _state.get("self", {}).get("talents", {})
	return (t if t is Dictionary else {})
func _my_talent_spent() -> int:
	return int(_state.get("self", {}).get("talent_spent", 0))
func _my_talent_avail() -> int:   # derived from level + spent (never trust a stale META field)
	return GameData.talent_points_available(_my_level_val(), _my_talent_spent())

func _build_talents() -> void:
	var p := Widgets.panel("Talents", "T / Esc", 600.0, _toggle_talents, true, {"icon": "talents", "persist": "talents", "legacy": "🌳 Talents"})   # phase B: marquee chrome
	_talent_panel = p["root"]
	_hud.add_child(_talent_panel)
	var vb: VBoxContainer = p["body"]
	_talent_status = Widgets.status(Palette.ACCENT2)
	vb.add_child(_talent_status)
	vb.add_child(Widgets.hint("Earn 1 point per level. Spend freely into any of the nine nodes — nothing is gated, so mix branches and nodes into your own concept build; each stat is a permanent boost that stacks on your gear. Respec wipes everything for a heavy fee, so commit."))
	_talent_rows = VBoxContainer.new()
	_talent_rows.add_theme_constant_override("separation", 4)
	vb.add_child(_talent_rows)

func _toggle_talents() -> void:
	if _talent_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_talent_panel.visible = not _talent_panel.visible
	if _talent_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_render_talents()

func _render_talents() -> void:
	if _talent_panel == null or not _talent_panel.visible or _talent_rows == null:
		return
	var cls := _my_class()
	if cls == "" or not GameData.TALENT_FLAVOR.has(cls):
		return
	var talents := _my_talents()
	var avail := _my_talent_avail()
	var flavor: Dictionary = GameData.TALENT_FLAVOR[cls]
	var credits := _my_credits_val()
	_talent_status.text = "%s   —   %d point%s available   (Lv %d · %d spent)   %d credits" % [
		str(flavor.get("tree", "Talents")), avail, ("" if avail == 1 else "s"), _my_level_val(), _my_talent_spent(), credits]
	for c in _talent_rows.get_children():
		c.queue_free()
	for br in GameData.TALENT_BRANCH_ORDER:
		var bflavor: Dictionary = flavor.get(br, {})
		var invested := GameData.talent_branch_ranks(talents, cls, br)
		_talent_rows.add_child(Widgets.section("%s   ·   %d invested" % [str(bflavor.get("name", br)), invested]))
		for n in GameData.TALENT_SHAPE[br]["nodes"]:
			_talent_rows.add_child(_talent_row(cls, br, n, bflavor, talents, invested, avail))
	_talent_rows.add_child(HSeparator.new())
	var rrow := HBoxContainer.new()
	rrow.add_theme_constant_override("separation", 10)
	var rbtn := IconWidget.icon_button("credits", "Respec all  %d" % GameData.TALENT_RESPEC_CREDITS,
		Palette.TEXT_BRIGHT, _on_respec_talents, {"px": 16, "icon_color": Palette.CREDITS})
	rbtn.disabled = _my_talent_spent() <= 0 or credits < GameData.TALENT_RESPEC_CREDITS
	rrow.add_child(rbtn)
	var rhint := Label.new()
	rhint.text = "Refund every point to re-spend."
	rhint.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	rhint.add_theme_color_override("font_color", Palette.TEXT_FAINT)
	rrow.add_child(rhint)
	_talent_rows.add_child(rrow)

func _talent_row(cls: String, br: String, n: Dictionary, bflavor: Dictionary, talents: Dictionary, invested: int, avail: int) -> HBoxContainer:
	var node_id := "%s_%s_%s" % [cls, br, str(n["slot"])]
	var cur := int(talents.get(node_id, 0))
	var nmax := int(n["max"])
	var per := int(n["per"])
	var stat := str(n["stat"])
	var req := int(n["req"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var nm := Label.new()
	nm.text = "%s%s" % [str(bflavor.get(str(n["slot"]), stat)), ("  (capstone)" if n.get("capstone", false) else "")]
	nm.custom_minimum_size = Vector2(150, 0)
	nm.add_theme_color_override("font_color", Palette.TEXT_BRIGHT if cur > 0 else Palette.TEXT)
	row.add_child(nm)
	var rank := Label.new()
	rank.text = "%d / %d" % [cur, nmax]
	rank.custom_minimum_size = Vector2(50, 0)
	rank.add_theme_color_override("font_color", Palette.ACCENT if cur >= nmax else Palette.TEXT_DIM)
	row.add_child(rank)
	var desc := Label.new()
	desc.text = "+%d %s / rank   (now +%d)" % [per, str(_TALENT_STAT_LABEL.get(stat, stat)), cur * per]
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	desc.add_theme_color_override("font_color", Palette.TEXT_DIM)
	row.add_child(desc)
	if invested < req:                              # branch prerequisite not met
		var lock := Label.new()
		lock.text = "needs %d" % req
		lock.add_theme_color_override("font_color", Palette.TEXT_FAINT)
		row.add_child(lock)
	elif cur >= nmax:
		var done := Label.new()
		done.text = "✓ maxed"
		done.add_theme_color_override("font_color", Palette.SUCCESS)
		row.add_child(done)
	else:
		var btn := Button.new()
		btn.text = "＋"
		btn.disabled = avail <= 0
		btn.pressed.connect(_on_spend_talent.bind(node_id))
		row.add_child(btn)
	return row

func _on_spend_talent(node_id: String) -> void:
	if net != null:
		net.spend_talent.rpc_id(1, node_id, 1)

func _on_respec_talents() -> void:
	if net != null:
		net.respec_talents.rpc_id(1)

# server → client: authoritative talent state after a spend/respec (mirror the wardrobe copy-on-write so the panel
# is accurate immediately, not one ~30 Hz snapshot late, and the next meta-less tick's overlay can't restore the old).
func recv_talents(talents: Dictionary, spent: int) -> void:
	if _state.has("self"):
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["talents"] = talents
		me["talent_spent"] = spent
		_meta["self"] = me
		_state["self"] = me
	if _talent_panel != null and _talent_panel.visible:
		_render_talents()

# server → client: leveled up → a talent point is available (points are derived from level; this is just the nudge).
# Fold the fresh level into self NOW (copy-on-write) so an open panel counts the new point immediately, not a tick late.
func recv_talent_point(level: int) -> void:
	if _state.has("self"):
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["level"] = level
		_meta["self"] = me
		_state["self"] = me
	_quest_toast("[color=#9fe8a0]Talent point earned (Lv %d)![/color]  Press [b]T[/b] to spend it." % level, "talents")
	if _talent_panel != null and _talent_panel.visible:
		_render_talents()

# ---- Paragon "Overtime" Bench Board (gameplay-length P5): post-cap QoL-only progression (allocate → Apply) ----
func _my_paragon_perks() -> Dictionary:
	var pp = _state.get("self", {}).get("paragon_perks", {})
	return (pp if pp is Dictionary else {})
func _my_paragon_spent() -> int:
	return int(_state.get("self", {}).get("paragon_spent", 0))
func _my_paragon_level() -> int:
	return GameData.paragon_level(_overtime_xp)
func _my_gear_bag() -> int:
	return int(_state.get("self", {}).get("gear_bag_bonus", 0))
func _draft_spent() -> int:
	var t := 0
	for k in _paragon_draft:
		t += int(_paragon_draft[k])
	return t
func _paragon_dirty() -> bool:
	var applied := _my_paragon_perks()
	for perk_id in GameData.PARAGON_CATALOG:
		if int(_paragon_draft.get(perk_id, 0)) != int(applied.get(perk_id, 0)):
			return true
	return false

func _build_paragon() -> void:
	var p := Widgets.panel("Paragon", "B / Esc", 640.0, _toggle_paragon, true, {"icon": "paragon", "persist": "paragon", "legacy": "⭐ Paragon — Bench Board"})   # phase B: marquee chrome
	_paragon_panel = p["root"]
	_hud.add_child(_paragon_panel)
	var vb: VBoxContainer = p["body"]
	vb.add_child(Widgets.section("BENCH BOARD"))   # subtitle moved out of the window title (handoff §6)
	_paragon_status = Widgets.status(Palette.ACCENT2)
	vb.add_child(_paragon_status)
	vb.add_child(Widgets.hint("Past level 30, XP becomes Overtime — 1 Bench Board point per Paragon level. Pure quality-of-life (more loot / credits / Pages / scrap / tokens), never combat power. Reallocate freely, then Apply. Every 5 Paragon levels also grants +2 gear-inventory slots."))
	_paragon_rows = VBoxContainer.new()
	_paragon_rows.add_theme_constant_override("separation", 4)
	vb.add_child(_paragon_rows)

func _toggle_paragon() -> void:
	if _paragon_panel == null:
		return
	if _tooltip != null: _tooltip.visible = false
	_paragon_panel.visible = not _paragon_panel.visible
	if _paragon_panel.visible:
		if _locker_panel != null: _locker_panel.visible = false
		_paragon_draft = _my_paragon_perks().duplicate()   # seed the draft from the applied board
		_render_paragon()

# just the header line (cheap) — called per-kill by recv_overtime so the live Overtime bar updates without a full row rebuild
func _set_paragon_status() -> void:
	if _paragon_status == null:
		return
	var level := _my_paragon_level()
	var spent := _draft_spent()
	_paragon_status.text = "Paragon %d   —   %d / %d points   (%d left)   ·   Overtime %d / %d to next   ·   +%d gear slots" % [
		level, spent, level, maxi(0, level - spent), GameData.paragon_prog(_overtime_xp), GameData.PARAGON_OT_PER_LEVEL, _my_gear_bag()]

func _render_paragon() -> void:
	if _paragon_panel == null or not _paragon_panel.visible or _paragon_rows == null:
		return
	var level := _my_paragon_level()
	var avail := level - _draft_spent()
	_set_paragon_status()
	for c in _paragon_rows.get_children():
		c.queue_free()
	for br in GameData.PARAGON_BRANCH_ORDER:
		_paragon_rows.add_child(Widgets.section(str(GameData.PARAGON_BRANCH_NAMES.get(br, br))))
		for perk_id in GameData.PARAGON_CATALOG:
			var def: Dictionary = GameData.PARAGON_CATALOG[perk_id]
			if str(def["branch"]) != br:
				continue
			_paragon_rows.add_child(_paragon_row(str(perk_id), def, avail))
	_paragon_rows.add_child(HSeparator.new())
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 10)
	var apply := Button.new()
	apply.text = "Apply"
	apply.disabled = not _paragon_dirty()
	apply.pressed.connect(_on_paragon_apply)
	arow.add_child(apply)
	var reset := Button.new()
	reset.text = "Reset"
	reset.disabled = not _paragon_dirty()
	reset.pressed.connect(_on_paragon_reset)
	arow.add_child(reset)
	if level <= 0:
		var none := Label.new()
		none.text = "Reach level 30, then keep earning XP to gain Paragon levels."
		none.add_theme_color_override("font_color", Palette.TEXT_FAINT)
		arow.add_child(none)
	_paragon_rows.add_child(arow)

func _paragon_row(perk_id: String, def: Dictionary, avail: int) -> HBoxContainer:
	var cur := int(_paragon_draft.get(perk_id, 0))
	var cap := int(def["cap"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var nm := Label.new()
	nm.text = str(def["name"])
	nm.custom_minimum_size = Vector2(140, 0)
	nm.add_theme_color_override("font_color", Palette.TEXT_BRIGHT if cur > 0 else Palette.TEXT)
	row.add_child(nm)
	var rank := Label.new()
	rank.text = "%d / %d" % [cur, cap]
	rank.custom_minimum_size = Vector2(44, 0)
	rank.add_theme_color_override("font_color", Palette.ACCENT if cur >= cap else Palette.TEXT_DIM)
	row.add_child(rank)
	var desc := Label.new()
	desc.text = str(def["desc"])
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION + 1)
	desc.add_theme_color_override("font_color", Palette.TEXT_DIM)
	row.add_child(desc)
	var minus := Button.new()
	minus.text = "−"
	minus.disabled = cur <= 0
	minus.pressed.connect(_on_paragon_step.bind(perk_id, -1))
	row.add_child(minus)
	var plus := Button.new()
	plus.text = "＋"
	plus.disabled = cur >= cap or avail <= 0
	plus.pressed.connect(_on_paragon_step.bind(perk_id, 1))
	row.add_child(plus)
	return row

func _on_paragon_step(perk_id: String, delta: int) -> void:
	if not GameData.PARAGON_CATALOG.has(perk_id):
		return
	var cap := int(GameData.PARAGON_CATALOG[perk_id]["cap"])
	if delta > 0 and _draft_spent() >= _my_paragon_level():
		return                                    # no points left to allocate
	var next := clampi(int(_paragon_draft.get(perk_id, 0)) + delta, 0, cap)
	if next <= 0:
		_paragon_draft.erase(perk_id)
	else:
		_paragon_draft[perk_id] = next
	_render_paragon()

func _on_paragon_apply() -> void:
	if net != null:
		net.set_paragon.rpc_id(1, _paragon_draft.duplicate())

func _on_paragon_reset() -> void:
	_paragon_draft = _my_paragon_perks().duplicate()
	_render_paragon()

# server → client: live post-cap Overtime odometer (its own RPC, kept out of the hashed META)
func recv_overtime(overtime_xp: int) -> void:
	var crossed := GameData.paragon_level(overtime_xp) != GameData.paragon_level(_overtime_xp)
	_overtime_xp = overtime_xp
	if _paragon_panel != null and _paragon_panel.visible:
		if crossed:
			_render_paragon()                     # a level crossing changes available points → rebuild rows (rare)
		else:
			_set_paragon_status()                 # normal kill: just refresh the live Overtime header (no per-kill row churn)

# server → client: the authoritative Bench Board after an Apply (copy-on-write into self like recv_talents)
func recv_paragon(perks: Dictionary, spent: int) -> void:
	if _state.has("self"):
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["paragon_perks"] = perks
		me["paragon_spent"] = spent
		_meta["self"] = me
		_state["self"] = me
	_paragon_draft = perks.duplicate()            # re-sync the draft to what actually applied
	_quest_toast("[color=#8ad6ff]Bench Board updated.[/color]", "paragon")
	if _paragon_panel != null and _paragon_panel.visible:
		_render_paragon()

# server → client: crossed a Paragon level (points/milestone)
func recv_paragon_level(level: int, available: int, bag_bonus: int) -> void:
	if _state.has("self"):                         # fold the milestone gear-bag into self immediately
		var me: Dictionary = (_state["self"] as Dictionary).duplicate()
		me["gear_bag_bonus"] = bag_bonus
		_meta["self"] = me
		_state["self"] = me
	if available > 0:
		_quest_toast("[color=#ffd24d]Paragon %d![/color]  A Bench Board point is ready — press [b]B[/b]." % level, "paragon")
	if _paragon_panel != null and _paragon_panel.visible:
		_render_paragon()

# ---- Leaderboards (P5) ----
const LB_CATS := [["drill", "Two-Minute Drill (wave)"], ["circuit_time", "Circuit — Fastest Clear"], ["boss_time", "Head Coach — Fastest Kill"], ["gear", "Gear Score"], ["intensity", "Camp Intensity"]]
const LB_CLEAR_CAP_MS := 3600000                 # P7d: MUST equal server CLEAR_CAP_MS — clear-time boards store CAP-elapsed; render CAP-score back to mm:ss
const LB_TIME_CATS := ["circuit_time", "boss_time"]              # rendered as time, not a raw number
const LB_SEASONAL_CATS := ["drill", "circuit_time", "boss_time"] # show the season + reset countdown (gear/intensity are all-time)
func _build_leaderboard() -> void:
	var p := Widgets.panel("Leaderboards", "L / Esc", 560.0, _toggle_leaderboard, true, {"icon": "leaderboards", "persist": "leaderboards", "legacy": "🏆 Leaderboards"})   # phase B: marquee chrome
	_lb_panel = p["root"]
	_hud.add_child(_lb_panel)
	var vb: VBoxContainer = p["body"]
	var short := ["2-Min Drill", "Fastest Clear", "Fastest Kill", "Gear Score", "Intensity"]  # tab labels fit the header
	_lb_tabs = Widgets.tab_row(short, func(i: int) -> void: _on_lb_category(str(LB_CATS[i][0])))
	vb.add_child(_lb_tabs["root"])
	_lb_status = Label.new()
	_lb_status.add_theme_font_size_override("font_size", 15)
	_lb_status.add_theme_color_override("font_color", Palette.TEXT_DIM)
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
		for i in LB_CATS.size():                   # sync the tab highlight to the current board
			if str(LB_CATS[i][0]) == _lb_cat and _lb_tabs.has("select"):
				(_lb_tabs["select"] as Callable).call(i)
		_on_lb_category(_lb_cat)                   # fetch the current tab on open

func _on_lb_category(cat: String) -> void:
	_lb_cat = cat
	if net != null:
		net.fetch_leaderboard.rpc_id(1, cat)      # server returns recv_leaderboard
	if _lb_status != null:
		_lb_status.text = "Loading %s…" % cat

func recv_leaderboard(category: String, entries: Array, season: int, reset_unix: int) -> void:
	if category != _lb_cat:
		return
	_lb_entries = entries
	_lb_season = season
	_lb_reset_unix = reset_unix
	_render_leaderboard()

func _fmt_ms(ms: int) -> String:                 # P7d: clear-time boards render as mm:ss
	var s := int(max(0, ms) / 1000.0)
	return "%d:%02d" % [s / 60, s % 60]

func _render_leaderboard() -> void:
	if _lb_panel == null or not _lb_panel.visible or _lb_rows == null:
		return
	if LB_SEASONAL_CATS.has(_lb_cat) and _lb_reset_unix > 0:
		_lb_status.text = "Season %d — resets in %s   ·   Top %d" % [_lb_season, _bounty_countdown(_lb_reset_unix), _lb_entries.size()]
	else:
		_lb_status.text = "All-time — Top %d" % _lb_entries.size()
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
		var raw := int((e as Dictionary).get("score", 0))
		sc.text = _fmt_ms(LB_CLEAR_CAP_MS - raw) if LB_TIME_CATS.has(_lb_cat) else str(raw)   # P7d: clear-time boards store CAP-elapsed → show the time
		sc.add_theme_color_override("font_color", Palette.SUCCESS)
		row.add_child(sc)
		_lb_rows.add_child(row)

func recv_drill_end(wave: int) -> void:
	_show_banner("Drill Complete", "Wave %d" % wave, "score submitted")    # P8 hero banner
	_quest_toast("[color=#ffd24d]Two-Minute Drill — reached WAVE %d![/color]  Score submitted to the leaderboard." % wave, "two_minute_drill")

# a big centered wave counter while inside the Drill (driven by the snapshot's drillWave)
func _update_drill_banner() -> void:
	if _drill_banner == null:
		var row := HBoxContainer.new()               # structural: two_minute_drill icon + wave Label (§8)
		row.add_theme_constant_override("separation", 8)
		row.visible = false
		var ic := IconWidget.make("two_minute_drill", {"px": 26, "color": Color(1.0, 0.7, 0.25)})
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(ic)
		_drill_banner_lbl = Label.new()
		_drill_banner_lbl.add_theme_font_size_override("font_size", 26)
		_drill_banner_lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.25))
		row.add_child(_drill_banner_lbl)
		_drill_banner = row
		_hud.add_child(_drill_banner)
	if str(_state.get("map", "")) == World.DRILL and _state.has("drillWave"):   # gate on the DRILL map, not just the
		var vp: Vector2 = _hud.get_viewport().get_visible_rect().size           # cached META key (stale-safe across zones)
		_drill_banner_lbl.text = "TWO-MINUTE DRILL  ·  WAVE %d" % int(_state["drillWave"])
		_drill_banner.position = Vector2(vp.x / 2.0 - 200.0, 24.0)
		_drill_banner.visible = true
		if _zone_banner != null:                  # the drill banner already names the zone top-center —
			_zone_banner.visible = false          # suppress the redundant, overlapping zone chip
	else:
		_drill_banner.visible = false

func _update_camp_proximity() -> void:
	var portal = _camp_portal()
	var pf = _find_fighter(_player_id)
	_near_camp = false
	if portal != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(portal["x"]), float(pf["y"]) - float(portal["y"])).length()
		_near_camp = d <= World.PORTAL_RADIUS + 24.0
	if _near_camp and (_camp_panel == null or not _camp_panel.visible):
		_interact_offer("camp", "C", "Run the Camp Circuit")
	else:
		_interact_clear("camp")
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
		"SHIELD": return "%s (%s): gain %d shield for %.0fs" % [nm, trig, int(round(amt)), float(p.get("dur", 3.0))]
		"HEAL": return "%s (%s): heal %d HP" % [nm, trig, int(round(amt))]
		"HASTE": return "%s (%s): +%d%% move speed for %.0fs" % [nm, trig, int(round(amt * 100.0)), float(p.get("dur", 3.0))]
		"GUARD": return "%s (%s): -%d%% damage taken for %.0fs" % [nm, trig, int(round(amt * 100.0)), float(p.get("dur", 3.0))]
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
	var p := Widgets.panel("Forge", "F / Esc", 680.0, _toggle_forge, true, {"icon": "forge", "persist": "forge", "legacy": "Forge"})   # phase B: marquee chrome
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
	_inv_items = _forge_items                      # salvage/craft happen HERE (inv panel closed) → keep the cache + near-cap count authoritative
	_recount_gear()
	_render_forge()

func _render_forge() -> void:
	if _forge_grid == null:
		return
	if _tooltip != null: _tooltip.visible = false
	for ch in _forge_grid.get_children(): ch.queue_free()
	for ch in _forge_craft_grid.get_children(): ch.queue_free()
	_forge_status.text = "%d scrap   %d credits        Upgrade raises an item's stat cap (toward the 60/stat ceiling) + its Item Power." % [_my_scrap(), _my_credits()]
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
		var eq: String = "  [color=#ffd24d](equipped)[/color]" if bool(it.get("equipped", false)) else ""
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
			costline = "[color=%s]Upgrade →+%d: %d credits +%dsc[/color]" % ["#9fe8a0" if can_up else "#ff8a8a", lvl + 1, cc, ucost]
		var has_rf := int(RARITY_RANK.get(rar, 0)) >= 1          # uncommon+ has affixes to reroll
		var can_rf := false
		if has_rf:
			var rcc: int = _reforge_credit_cost(rar, rc)
			var rsc: int = _reforge_scrap_cost(rar, rc)
			can_rf = _my_credits() >= rcc and _my_scrap() >= rsc
			costline += "    [color=%s]Reforge: %d credits +%dsc[/color]" % ["#cdbcff" if can_rf else "#ff8a8a", rcc, rsc]
		var header := "[color=%s]%s[/color]%s%s [color=#7f8a99](%s · i%d · IP %d)[/color]\n%s" % [
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
		_shop_buy_status.text = "BUY    %d credits" % _my_credits()
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
		var header := "[color=%s]%s[/color] [color=#7f8a99](%s · %s)[/color]\n%s%s[color=%s]%d credits[/color]" % [
			RARITY_COLORS.get(rr, "#cfd6df"), _esc(str(e.get("name", ""))), rr, slot,
			stats, ("   " if stats != "" else ""), pcol, price]
		_shop_buy_grid.add_child(_grid_tile(Color.html(RARITY_COLORS.get(rr, "#cfd6df")), header, e, _sell_items, null,
			func() -> void:
				if net != null and _connected: net.shop_buy.rpc_id(1, slot, rr)))
	var roll: Dictionary = _shop_info.get("roll", {})
	for rar in ["common", "uncommon", "rare", "epic"]:
		if roll.has(rar):
			var rprice: int = int(roll[rar])
			_shop_roll_row.add_child(IconWidget.icon_button("credits", "Roll %s  %d" % [rar.capitalize(), rprice],
				Color.html(RARITY_COLORS.get(rar, "#cfd6df")),
				func() -> void:
					if net != null and _connected: net.shop_roll.rpc_id(1, rar),
				{"px": 16, "icon_color": Palette.CREDITS, "disabled": _my_credits() < rprice}))

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
	_inv_items = _sell_items                       # sell/salvage happen HERE (inv panel closed) → keep the cache + near-cap count authoritative
	_recount_gear()
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
# on every toggle — no network. Selecting is multi-select; equipped and locked items are unselectable.
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
	_shop_sell_status.text = "%s   %s" % ["SALVAGE" if _sell_salvage else "SELL", ("%d scrap" % _my_scrap()) if _sell_salvage else ("%d credits" % _my_credits())]
	for ch in _shop_sell_controls.get_children(): ch.queue_free()
	for ch in _shop_sell_grid.get_children(): ch.queue_free()
	for ch in _shop_sell_footer.get_children(): ch.queue_free()
	var dim := Color(0.5, 0.58, 0.66)
	# mode row: Sell (credits) ↔ Salvage (scrap)
	var moderow := HBoxContainer.new()
	moderow.add_theme_constant_override("separation", 8)
	moderow.add_child(_ctrl_label("mode:"))
	moderow.add_child(_ctrl_btn(("● Sell" if not _sell_salvage else "○ Sell"), (Color.html("#bdf5c0") if not _sell_salvage else dim), func() -> void:
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
	# per-rarity select-all (top tier flagged protected → opt in explicitly)
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
		var prot: String = "  (protected)" if rar == top_rar else ""
		selrow.add_child(_ctrl_btn("%s %s%s" % [("✓" if all_sel else "○"), rar.capitalize(), prot], Color.html(RARITY_COLORS.get(rar, "#cfd6df")), func() -> void:
			_toggle_sell_rarity(rar_l)))
	_shop_sell_controls.add_child(selrow)
	if top_rar != "":
		_shop_sell_controls.add_child(IconWidget.row("top_tier_protected", "your top tier — protected; click to opt in",
			{"px": 16, "color": Palette.SB_CYAN, "text_color": Palette.TEXT_DIM}))
	# sort row (client-side)
	var sortrow := HBoxContainer.new()
	sortrow.add_theme_constant_override("separation", 8)
	sortrow.add_child(_ctrl_label("sort:"))
	for key in ["rarity", "slot", "power"]:
		var k_l: String = key
		sortrow.add_child(Widgets.toggle_btn(key.capitalize(), _sell_sort == key, func() -> void:
			_sell_sort = k_l
			_render_shop_sell()))
	_shop_sell_controls.add_child(sortrow)
	# slot-filter row (client-side)
	var slotrow := HFlowContainer.new()
	slotrow.add_child(_ctrl_label("slot:"))
	for sl in ["", "head", "chest", "legs", "hands", "feet", "main_hand", "off_hand", "neck", "ring", "trinket"]:
		var sl_l: String = sl
		var lbl2: String = "All" if sl == "" else sl.capitalize()
		slotrow.add_child(Widgets.toggle_btn(lbl2, _sell_filter_slot == sl, func() -> void:
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
		var valtxt: String = ("[color=#c9a36a]%d scrap[/color]" % val) if _sell_salvage else ("[color=#ffd24d]%d credits[/color]" % val)
		var marks: String = ""
		if equipped: marks += "[color=#ffd24d](equipped)[/color] "
		marks += ("[color=#ffb454]locked[/color] " if locked else "[color=#5a6472]unlocked[/color] ")   # lock state, always shown
		if selected: marks += "[color=#9fe8a0]✓[/color] "
		var status: String = ""
		if equipped: status = " [color=#7f93a8](equipped)[/color]"
		elif locked: status = " [color=#7f93a8](locked · right-click to unlock)[/color]"
		var stats := _item_stats_str(it)
		var header := "%s[color=%s]%s[/color]%s\n[color=#7f8a99](%s · IP %d)[/color]%s — %s" % [
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
		var unit: String = ("%d scrap" % total) if _sell_salvage else ("%d credits" % total)
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
		_show_sell_confirm("Sell %d item%s for %d credits?" % [ids.size(), plural, total], func() -> void:
			if net != null and _connected:
				net.shop_sell_many.rpc_id(1, ids)
			_sell_selection.clear())

# generic confirm modal (reused by the bulk-sell flow). on_yes runs if the player confirms.
func _show_sell_confirm(prompt: String, on_yes: Callable) -> void:
	_close_sell_confirm()
	_sell_confirm = PanelContainer.new()          # Container → sizes to content + actually draws the themed box
	var mg := MarginContainer.new()               # breathing room (was jammed to the 4px theme margin)
	for s in ["left", "right", "top", "bottom"]:
		mg.add_theme_constant_override("margin_" + s, 16)
	_sell_confirm.add_child(mg)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	mg.add_child(vb)
	var head := HudFonts.display_label("Confirm", Palette.SIZE_SECTION, Palette.SB_ORANGE, 0.16)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vb.add_child(head)
	var lbl := Label.new()
	lbl.text = prompt
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(300, 0)
	vb.add_child(lbl)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var yes := Button.new()                        # destructive → orange-lit, distinct from Cancel
	yes.text = "Confirm"
	yes.add_theme_color_override("font_color", Palette.SB_ORANGE)
	yes.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	var ysb := StyleBoxFlat.new()
	ysb.bg_color = Color(Palette.SB_ORANGE, 0.16)
	ysb.set_border_width_all(1)
	ysb.border_color = Color(Palette.SB_ORANGE, 0.8)
	ysb.set_corner_radius_all(5)
	ysb.content_margin_left = 13.0
	ysb.content_margin_right = 13.0
	ysb.content_margin_top = 5.0
	ysb.content_margin_bottom = 5.0
	yes.add_theme_stylebox_override("normal", ysb)
	var yhv: StyleBoxFlat = ysb.duplicate()
	yhv.bg_color = Color(Palette.SB_ORANGE, 0.28)
	yes.add_theme_stylebox_override("hover", yhv)
	yes.add_theme_stylebox_override("pressed", yhv)
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
	var shop = _home_pad("shop")
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
	_shop_root.add_child(WorldUI.pad_marker("shop", "Shop",
		Color(1.0, 0.88, 0.5), pos + Vector3(0.0, 3.4, 0.0)))

func _update_shop_proximity() -> void:
	var shop = _home_pad("shop")
	var pf = _find_fighter(_player_id)
	_near_shop = false
	if shop != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(shop["x"]), float(pf["y"]) - float(shop["y"])).length()
		_near_shop = d <= World.SHOP_RADIUS
	if _near_shop and (_shop_panel == null or not _shop_panel.visible):
		_interact_offer("shop", "B", "Shop — buy & sell gear")
	else:
		_interact_clear("shop")
	if not _near_shop and _shop_panel != null and _shop_panel.visible:
		_shop_panel.visible = false                  # walked away → close the shop
		_close_sell_confirm()

# ---- Builder Mode (P3): the Build Shop pad + panel (buy furniture) + the locked-locker "Purchase" prompt ----
func _build_build_shop_panel() -> void:
	var p := Widgets.panel("Build Shop", "P / Esc", 560.0, _toggle_build_shop, true, {"icon": "build_shop", "persist": "build_shop", "legacy": "Build Shop"})   # phase B: marquee chrome
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
		_build_shop_status.text = "%d credits    ·    %d/%d furniture owned%s" % [_my_credits(), owned, cap, fulltag]
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
		var header := "[color=%s]%s[/color] [color=#7f8a99](%s)[/color]\n[color=%s]%d credits[/color]   [color=%s]%d/%d[/color]%s" % \
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
					_toast("[color=#ff8a8a]Not enough credits for %s (%d credits)[/color]" % [_esc(m), pr], Color.html("#ff8a8a"))
				elif net != null and _connected:
					net.build_buy.rpc_id(1, m)))

func _render_build_shop_pad() -> void:
	var pad = _home_pad("build_shop")
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
	_build_shop_root.add_child(WorldUI.pad_marker("build_shop", "Build Shop",
		Color(0.7, 0.85, 1.0), pos + Vector3(0.0, 3.4, 0.0)))

func _update_build_shop_proximity() -> void:
	var pad = _home_pad("build_shop")
	var pf = _find_fighter(_player_id)
	_near_build_shop = false
	if pad != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(pad["x"]), float(pf["y"]) - float(pad["y"])).length()
		_near_build_shop = d <= World.BUILD_SHOP_RADIUS
	if _near_build_shop and (_build_shop_panel == null or not _build_shop_panel.visible):
		_interact_offer("build_shop", "P", "Shop for furniture")
	else:
		_interact_clear("build_shop")
	if not _near_build_shop and _build_shop_panel != null and _build_shop_panel.visible:
		_build_shop_panel.visible = false            # walked away → close

# the Locker Room portal, when you don't own it yet, shows a "press [Y] to Purchase" prompt (buy_locker_room).
# Once unlocked, walking onto the pad auto-enters (server-side), so this prompt just disappears.
func _update_locker_portal_proximity() -> void:
	var pad = _home_pad("locker_portal")
	var pf = _find_fighter(_player_id)
	_near_locker_portal = false
	if pad != null and pf != null and not _locker_unlocked():
		var d := Vector2(float(pf["x"]) - float(pad["x"]), float(pf["y"]) - float(pad["y"])).length()
		_near_locker_portal = d <= World.PORTAL_RADIUS + 26.0
	if _near_locker_portal:
		_interact_offer("locker_portal", "Y",
			"Unlock your Locker Room  (%d credits)" % int(_build_info.get("unlock_cost", 10000)))
	else:
		_interact_clear("locker_portal")

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
	var col: Color = Palette.SUCCESS if placed else Palette.TEXT_BRIGHT
	var rail: Color = Palette.SB_LIME if placed else Palette.SB_CYAN   # placed=lime, unplaced=cyan rail
	b.text = ("✔ " if placed else "") + str(it.get("model", it.get("name", "?")))
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	b.tooltip_text = str(it.get("model", "?")) + ("  · placed in your Locker Room" if placed else "  · in your Build tab (place it in your Locker Room)")
	b.add_theme_stylebox_override("normal", Widgets.tile_box(rail, false))   # now with a real hover state
	b.add_theme_stylebox_override("hover", Widgets.tile_box(rail, true))
	b.add_theme_stylebox_override("pressed", Widgets.tile_box(rail, true))
	return b

# ---- Builder Mode P3b: the Locker Room build editor (F4 in your own unlocked room) ----------------------------
# Reuses the F4-decorator feel (cursor place / grab-move / rotate / lift), but every action is a SERVER RPC
# (build_place/move/remove) and the room renders from the server's snapshot decals — the client never touches
# local JSON here and never trusts its own coords (the server clamps). F4 routes here (not the admin decorator)
# only when _locker_build_available() — i.e. you're standing in your own unlocked locker_room instance.
func _locker_build_available() -> bool:
	return str(_state.get("map", "")) == World.LOCKER and _locker_unlocked()

# HUD edit mode may not stack on either _input-phase build editor (see Client._hud_edit_blocked)
func _hud_edit_blocked() -> bool:
	return _lb_on or _deco_on

# the WORLD/map decorator (F4 outside your Locker Room) is GAME-MASTER ONLY on the live server (recv_admin, gated
# by the service-role admins table). Non-admins pressing F4 in the world get nothing; their Locker Room build
# editor still works (that's _locker_build_available, above). Overrides Client._world_build_allowed().
func _world_build_allowed() -> bool:
	return _is_admin

# enable local-player prediction only while networked (offline sandbox already renders the sim instantly)
func _prediction_enabled() -> bool:
	return net != null and _connected

# online, the cosmetic hop is also frozen while chatting (and the grace frame after) — same suppression the
# intent-zeroing applies to movement/abilities in _physics_process, so Space can't hop while typing/HUD-editing
func _hop_suppressed() -> bool:
	return hud_edit_on or _chatting or _chat_grace > 0

# Phase 0.5: a local hop started → tell the server so OTHER players see it (reliable one-shot; the server
# re-validates alive + rate-limits). Cosmetic only — never an ability/intent, so it can't affect the sim.
func _on_local_hop() -> void:
	if server != null:
		server.submit_hop_local(1)
	elif net != null and _connected:
		net.submit_hop.rpc_id(1)

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
	if _lb_root == null and _hud != null:
		# P9: the builder status line rides a PANEL chassis with a BUILDER badge — a configurable
		# module (position/scale/opacity) instead of the old _pin_topright dev label
		var bfd: Dictionary = HudFrame.fitted(HudFrame.Tier.PANEL, {"header": true, "accent": Palette.SB_LIME, "body_alpha": 0.85})
		_lb_root = bfd["root"]
		_lb_root.visible = false
		_hud.add_child(_lb_root)
		var bvb := VBoxContainer.new()
		bvb.add_theme_constant_override("separation", 3)
		(bfd["body"] as MarginContainer).add_child(bvb)
		var badge := HudFonts.display_label("Builder", 12, Palette.SB_LIME, 0.2)
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		bvb.add_child(badge)
		_lb_lbl = Label.new()
		_lb_lbl.custom_minimum_size = Vector2(300, 0)
		_lb_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_lb_lbl.add_theme_font_size_override("font_size", 13)
		_lb_lbl.add_theme_color_override("font_color", Color(0.78, 0.95, 0.8))
		bvb.add_child(_lb_lbl)
		HudLayout.register("builder_panel", _lb_root, {"label": "Builder Panel",
			"defaults": {"anchor": "top_right", "ox": -12.0, "oy": 44.0},   # unchanged
			"ref_size": Vector2(330, 84), "preview": _lb_panel_preview})
	if _lb_root != null:
		_lb_root.visible = on
	if not on:
		if is_instance_valid(_lb_ghost):
			_lb_ghost.queue_free()
		_lb_ghost = null
		_lb_ghost_key = ""
		return
	if not _coords_on:
		_toggle_coords()                            # the coord readout pairs naturally with placing
	_lb_refresh_palette()
	_toast("[color=#9fe8a0]Build mode[/color]\n[color=#cfd6df]LMB place · [ ] pick · , . rotate · - = size · PgUp/Dn lift · G grab/move · X remove · F4 exit[/color]", Palette.ACCENT, false, "build_shop")

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
	_toast("[color=#9fe8a0]Undo[/color]", Palette.ACCENT)
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
	var titlerow := HBoxContainer.new()
	titlerow.alignment = BoxContainer.ALIGNMENT_CENTER
	titlerow.add_theme_constant_override("separation", 8)
	titlerow.add_child(IconWidget.make("delete", {"px": 22, "color": Palette.DANGER}))
	var title := Label.new()
	title.text = "Delete this %s?" % model
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Palette.DANGER)
	titlerow.add_child(title)
	vb.add_child(titlerow)
	var sub := Label.new()
	sub.text = "It goes back to your Build tab · Ctrl+Z undoes it"
	sub.add_theme_color_override("font_color", Palette.TEXT_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	row.add_child(IconWidget.icon_button("delete", "Delete  (Y)", Palette.DANGER, _lb_confirm_delete, {"px": 18}))
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
	var titlerow := HBoxContainer.new()
	titlerow.add_theme_constant_override("separation", 9)
	titlerow.add_child(IconWidget.make("build_shop", {"px": 24, "color": Palette.ACCENT}))
	var title := Label.new()
	title.text = "Welcome to your Locker Room"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	titlerow.add_child(title)
	vb.add_child(titlerow)
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
		_build_help_hint.text = "Press  [ H ]  for build help"
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
		_lb_lbl.text = "DELETE  %s ?  (highlighted red)\n  [Y] yes, remove it   ·   [N] no, keep it   ·   [X] target a different prop   ·   F4 exit" % dm
		return
	_lb_lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))   # normal green
	# ALWAYS show the controls (even with no furniture) so the player never loses the reference.
	if _lb_grab_id != "":                           # moving: name the prop prominently so it's clear what will move
		var gm := _lb_grab_model if _lb_grab_model != "" else "prop"
		_lb_lbl.text = "BUILD — ▶ MOVING  %s ◀    yaw %.0f°  size %.1f  lift %.1f\n  the preview follows your cursor · , . rotate · - = size · PgUp/Dn lift · click or G to drop it here · Ctrl+Z undo · F4 exit" % [gm, rad_to_deg(_lb_yaw), _lb_h, _lb_oy]
		return
	var sel := "(none — buy at the Build Shop [P])"
	if not _lb_pal.is_empty():
		sel = "[ ] %s  (%d/%d)" % [str((_lb_pal[_lb_idx] as Dictionary).get("model", "?")), _lb_idx + 1, _lb_pal.size()]
	_lb_lbl.text = "BUILD    %s    yaw %.0f°  size %.1f  lift %.1f\n  L-click place · G grab/move · X remove · Ctrl+Z undo · , . rotate · - = size · PgUp/Dn lift · F4 exit" % [sel, rad_to_deg(_lb_yaw), _lb_h, _lb_oy]

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
	var v = _home_pad("practice")
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
	_vendor_root.add_child(WorldUI.pad_marker("practice_vendor", "Practice Vendor",
		Color(0.5, 0.9, 1.0), pos + Vector3(0.0, 3.4, 0.0)))

func _update_vendor_proximity() -> void:
	var v = _home_pad("practice")
	var pf = _find_fighter(_player_id)
	_near_vendor = false
	if v != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(v["x"]), float(pf["y"]) - float(v["y"])).length()
		_near_vendor = d <= World.PRACTICE_RADIUS
	if _near_vendor and (_vendor_panel == null or not _vendor_panel.visible):
		_interact_offer("vendor", "V", "Browse the Practice Vendor")
	else:
		_interact_clear("vendor")
	if not _near_vendor and _vendor_panel != null and _vendor_panel.visible:
		_vendor_panel.visible = false                # walked away → close the vendor

# the forge pad in the home base + the "press F" proximity prompt (mirrors the shop pad)
func _render_forge_pad() -> void:
	var forge = _home_pad("forge")
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
	_forge_root.add_child(WorldUI.pad_marker("forge", "Forge",
		Color(1.0, 0.6, 0.4), pos + Vector3(0.0, 3.4, 0.0)))

func _update_forge_proximity() -> void:
	var forge = _home_pad("forge")
	var pf = _find_fighter(_player_id)
	_near_forge = false
	if forge != null and pf != null:
		var d := Vector2(float(pf["x"]) - float(forge["x"]), float(pf["y"]) - float(forge["y"])).length()
		_near_forge = d <= World.FORGE_RADIUS
	if _near_forge and (_forge_panel == null or not _forge_panel.visible):
		_interact_offer("forge", "F", "Forge — upgrade & reforge gear")
	else:
		_interact_clear("forge")
	if not _near_forge and _forge_panel != null and _forge_panel.visible:
		_forge_panel.visible = false                 # walked away → close the forge

# ---- admin tool (only the admin account ever receives recv_admin) ----
func recv_admin(on: bool) -> void:
	_is_admin = on
	if on and _admin_panel == null:
		_build_admin_panel()

func _build_admin_panel() -> void:
	_admin_panel = PanelContainer.new()
	var mg := MarginContainer.new()               # was jammed to the 4px theme margin
	for s in ["left", "right", "top", "bottom"]:
		mg.add_theme_constant_override("margin_" + s, 12)
	_admin_panel.add_child(mg)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	mg.add_child(vb)
	var title := HudFonts.display_label("Admin", Palette.SIZE_SECTION, Palette.SB_ORANGE, 0.16)   # orange = the warn/dev semantic
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	vb.add_child(title)
	# grouped so the 19 commands are scannable (was one undifferentiated tall column); teleports
	# lay out as a grid to cut height
	var groups := [
		["Character", [["Level +", "level_up", {}], ["Level -", "level_down", {}], ["+100 XP", "add_xp", {"amt": 100}], ["+500 Credits", "add_credits", {"amt": 500}]], 2],
		["Items", [["Give Item", "give_item", {}], ["Clear Items", "clear_items", {}]], 2],
		["Survival", [["God Mode", "god", {}], ["Heal", "heal", {}]], 2],
		["Teleport", [["Home", "goto", {"map": "home"}], ["Arena", "goto", {"map": "arena"}], ["GY1", "goto", {"map": "glitchyard_1"}], ["GY2", "goto", {"map": "glitchyard_2"}], ["GY3", "goto", {"map": "glitchyard_3"}], ["GY4", "goto", {"map": "glitchyard_4"}], ["GY5", "goto", {"map": "glitchyard_5"}], ["BOSS", "goto", {"map": "glitchyard_boss"}], ["AW1", "goto", {"map": "away_1"}], ["AW2", "goto", {"map": "away_2"}], ["AW3", "goto", {"map": "away_3"}], ["RIVAL", "goto", {"map": "away_boss"}], ["FIN1", "goto", {"map": "finals_1"}], ["FIN2", "goto", {"map": "finals_2"}]], 4],
		["Mobs", [["Spawn Mob", "spawn_mob", {"level": 3}], ["Clear Mobs", "clear_mobs", {}], ["Reset Mobs", "reset_mobs", {}]], 3],
	]
	for grp in groups:
		vb.add_child(Widgets.section(str(grp[0])))
		var grid := GridContainer.new()
		grid.columns = int(grp[2])
		grid.add_theme_constant_override("h_separation", 4)
		grid.add_theme_constant_override("v_separation", 4)
		for c in grp[1]:
			var b := Button.new()
			b.text = str(c[0])
			b.focus_mode = Control.FOCUS_NONE
			var cmd: String = str(c[1])
			var args: Dictionary = c[2]
			b.pressed.connect(func() -> void: _admin(cmd, args))
			grid.add_child(b)
		vb.add_child(grid)
	_hud.add_child(_admin_panel)
	var vp: Vector2 = _hud.get_viewport().get_visible_rect().size
	_admin_panel.position = Vector2(vp.x - 260.0, 70.0)
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
	_toast("[color=#ffd24d]Looted[/color]  [color=%s]%s[/color]\n[color=#7f93a8]%s · %s%s[/color]" % [col, _esc(item), rarity, slot, bonus], Color.html(col), false, "loot")
	_chat_lines.append("[color=#ffd24d]Looted[/color] [color=%s]%s[/color] [color=#7f93a8](%s · %s)%s[/color]" % [col, _esc(item), rarity, slot, bonus])
	if _chat_lines.size() > 9:
		_chat_lines = _chat_lines.slice(_chat_lines.size() - 9)
	_chat_log.text = "\n".join(_chat_lines)
	_chat_idle = 0.0                              # new line → pop the log back up
	_chat_box.modulate.a = 1.0
	_gear_count += 1                              # a loot drop is always a gear add → track it live for the near-cap warning
	_update_cap_warning()
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
	if _chatting or _chat_grace > 0 or hud_edit_on:
		_player.intent["mx"] = 0.0                   # hold still while typing / editing the HUD (and the
		_player.intent["my"] = 0.0                   # frame after, so the dismissing click can't fire)
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
	if _dev_walkto.x != INF:                         # dev --walkto: steer intent toward the point (server
		var wpf = _find_fighter(_player_id)          # still validates speed — this is normal movement)
		if wpf != null:
			var wd := _dev_walkto - Vector2(float(wpf["x"]), float(wpf["y"]))
			if wd.length() <= 25.0:
				_dev_walkto = Vector2.INF            # arrived — hand control back
			else:
				mv["mx"] = wd.normalized().x
				mv["my"] = wd.normalized().y
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
# ---- P7 unit frames: 2D target/focus panels fed by the SAME authoritative ids the 3D rings
# use (_focus_id / _friend_id). Pure display — Tab/Ctrl+Tab/Esc/death rules are untouched.
func _build_unit_frames() -> void:
	_tf = _make_unit_frame(Palette.DANGER, "target_frame", "Target",
		{"anchor": "top_center", "ox": 150.0, "oy": 56.0}, _target_frame_preview)
	_ff = _make_unit_frame(Palette.HEAL, "focus_frame", "Focus (Ally)",
		{"anchor": "top_center", "ox": -150.0, "oy": 56.0}, _focus_frame_preview)

func _make_unit_frame(accent: Color, id: String, label: String, defs: Dictionary, prev: Callable) -> Dictionary:
	var fd: Dictionary = HudFrame.fitted(HudFrame.Tier.PANEL, {"header": true, "accent": accent, "body_alpha": 0.8})
	var root: Control = fd["root"]
	# stays IGNORE (fitted default): these frames take no clicks, and STOP would starve the
	# RMB-orbit/wheel-zoom _unhandled_input handlers exactly where combat happens
	root.visible = false
	_hud.add_child(root)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 3)
	(fd["body"] as MarginContainer).add_child(vb)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.custom_minimum_size = Vector2(220, 0)   # the name ellipsizes inside this budget
	vb.add_child(head)
	var nm := Label.new()
	nm.add_theme_font_size_override("font_size", 15)
	nm.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(nm)
	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	sub.add_theme_color_override("font_color", Palette.TEXT_DIM)
	sub.size_flags_vertical = Control.SIZE_SHRINK_END
	head.add_child(sub)
	var hp: Dictionary = Widgets.bar(220, 16, Palette.HP)
	var hpt := Label.new()
	hpt.set_anchors_preset(Control.PRESET_FULL_RECT)
	hpt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hpt.add_theme_font_size_override("font_size", Palette.SIZE_CAPTION)
	hpt.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	hpt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	hpt.add_theme_constant_override("outline_size", 4)
	(hp["root"] as Control).add_child(hpt)
	vb.add_child(hp["root"])
	var status := StatusRow.new()                # §3c: buff/debuff chips under the HP bar (cap 5 + "+n")
	status.cap = 5
	status.chip_px = 18
	vb.add_child(status)
	HudLayout.register(id, root, {"label": label, "defaults": defs,
		"ref_size": Vector2(248, 74), "preview": prev})
	return {"root": root, "name": nm, "sub": sub, "hp": hp, "hpt": hpt, "status": status, "cache": {}}

func _update_unit_frames() -> void:
	_drive_unit_frame(_tf, _focus_id, true, _tf_preview)
	_drive_unit_frame(_ff, _friend_id, false, _ff_preview)

func _drive_unit_frame(f: Dictionary, fid: String, hostile: bool, preview: bool) -> void:
	if f.is_empty():
		return
	var root: Control = f["root"]
	var pf = _find_fighter(fid) if fid != "" else null
	if pf == null or not bool(pf.get("alive", true)):
		if preview:                                  # HUD-edit: sample values keep it placeable
			root.visible = true
			_set_unit_frame(f, "Training Dummy" if hostile else "Blitz-7",
				"Lv 5 · DUMMY" if hostile else "Lv 12 · Slugger",
				WorldUI.HOSTILE if hostile else Palette.HEAL,
				1.0 if hostile else 0.72, 825.0 if hostile else 610.0, 825.0)
			(f["status"] as StatusRow).drive({"dr": [25, 20], "slw": [12, 30]} if hostile else {"sh": [120, 30]}, "preview")
		else:
			root.visible = false
			(f["status"] as StatusRow).drive({})     # stale chips must not survive a target swap
		return
	root.visible = true
	(f["status"] as StatusRow).drive(pf.get("st", {}), fid)   # §3c: statuses straight off the snapshot
	# mobs ship mobLevel/mobTier and NO name/level keys (only players carry those) — mirror the
	# world-plate identity rules (Client.gd _update_ui) so the frame reads for every target type
	var nm := str(pf.get("name", ""))
	var lvl := int(pf.get("mobLevel", pf.get("level", 0)))
	var parts := []
	if lvl > 0:
		parts.append("Lv %d" % lvl)
	var ncol: Color = Palette.TEXT_BRIGHT
	if hostile:
		ncol = WorldUI.HOSTILE
		var tier := str(pf.get("mobTier", ""))
		if pf.get("dummy", false):
			nm = "Training Dummy"
		elif pf.get("isCore", false):
			nm = "Power Core"
		elif tier == "boss":
			# S2: per-def plate (title-cased for the frame style); exact old fallback keeps GY bosses byte-identical
			var _bd: Dictionary = GameData.CLASSES.get(str(pf.get("classId", "")), {})
			nm = str(_bd.get("plate", "")).capitalize() if _bd.has("plate") else "Head Coach"
		if nm == "":
			nm = str(pf.get("classId", "")).capitalize()
			if nm == "":
				nm = "Enemy"
		if tier != "":
			parts.append(tier.to_upper())
	else:
		var cdef: Dictionary = GameData.CLASSES.get(str(pf.get("classId", "")), {})
		ncol = WorldUI.friendly_plate(Color.from_string(str(cdef.get("color", "")), Palette.TEXT_BRIGHT))
		if not str(pf.get("classId", "")).is_empty():
			parts.append(str(pf.get("classId", "")).capitalize())
	var mhp: float = maxf(1.0, float(pf.get("maxHP", 1.0)))
	_set_unit_frame(f, nm, " · ".join(parts), ncol,
		clampf(float(pf.get("hp", 0.0)) / mhp, 0.0, 1.0), float(pf.get("hp", 0.0)), mhp)

func _set_unit_frame(f: Dictionary, name: String, sub: String, ncol: Color, frac: float, hp: float, mhp: float) -> void:
	var c: Dictionary = f["cache"]
	if str(c.get("n", "")) != name:
		c["n"] = name
		(f["name"] as Label).text = name
	if c.get("nc") != ncol:
		c["nc"] = ncol
		(f["name"] as Label).add_theme_color_override("font_color", ncol)
	if str(c.get("s", "")) != sub:
		c["s"] = sub
		(f["sub"] as Label).text = sub
	Widgets.set_bar(f["hp"], frac)
	((f["hp"] as Dictionary)["fill"] as ColorRect).color = WorldUI.hp_color(frac)
	var hptxt := "%d / %d" % [int(round(hp)), int(round(mhp))]
	if str(c.get("h", "")) != hptxt:
		c["h"] = hptxt
		(f["hpt"] as Label).text = hptxt

func _target_frame_preview(on: bool) -> void:
	_tf_preview = on
	_drive_unit_frame(_tf, _focus_id, true, on)

func _focus_frame_preview(on: bool) -> void:
	_ff_preview = on
	_drive_unit_frame(_ff, _friend_id, false, on)

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
		# P7: the party group is ONE module (never per-member) riding a PANEL chassis; default
		# spot matches the old hardcoded (12,250) below the vitals stack
		var pfd: Dictionary = HudFrame.fitted(HudFrame.Tier.PANEL, {"header": true, "body_alpha": 0.8})
		_party_root = pfd["root"]
		_party_root.visible = false
		_hud.add_child(_party_root)
		_party_panel = VBoxContainer.new()
		_party_panel.add_theme_constant_override("separation", 4)
		(pfd["body"] as MarginContainer).add_child(_party_panel)
		var pt := HudFonts.display_label("Party", 12, Palette.SB_CYAN, 0.18)
		pt.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_party_panel.add_child(pt)
		_leave_btn = Button.new()
		_leave_btn.text = "Leave Party"
		_leave_btn.pressed.connect(func() -> void:
			if net != null and _connected:
				net.party_leave.rpc_id(1)
			_friend_id = "")
		_party_panel.add_child(_leave_btn)
		HudLayout.register("party_frames", _party_root, {"label": "Party",
			"defaults": {"anchor": "top_left", "ox": 12.0, "oy": 250.0},
			"ref_size": Vector2(184, 120), "preview": _party_frames_preview})
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
	# HUD-edit preview: sample rows while solo, so the group is placeable before any invite
	if _party_prev and _party.is_empty() and _party_samples.is_empty():
		for sample in [["Blitz-7", 0.74], ["Coach-AI", 1.0]]:
			var sp := _make_party_frame("")          # returns the row; only _sync tracks live frames
			sp["name"].text = "%s  610/825" % str(sample[0])
			sp["fill"].size = Vector2(146.0 * float(sample[1]), 14.0)
			sp["fill"].color = WorldUI.hp_color(float(sample[1]))
			# §3c: sample chips so the taller chip-strip rows preview true-to-size in F2
			(sp["status"] as StatusRow).drive({"dot": [2, 23], "dr": [25, 20]} if sample[0] == "Blitz-7" else {"sh": [95, 25]})
			_party_samples.append(sp)
		_party_panel.move_child(_leave_btn, _party_panel.get_child_count() - 1)
	elif (not _party_prev or not _party.is_empty()) and not _party_samples.is_empty():
		for sp in _party_samples:
			(sp["root"] as Control).queue_free()
		_party_samples.clear()
	_party_root.visible = _party.size() > 0 or not _party_samples.is_empty()
	for i in _party_frames.size():
		var m = _party[i]
		var fr = _party_frames[i]
		var frac: float = clampf(float(m["hp"]) / max(float(m["maxHP"]), 1.0), 0.0, 1.0)
		fr["fill"].size = Vector2(146.0 * frac, 14.0)
		fr["fill"].color = WorldUI.hp_color(frac) if bool(m["alive"]) else Color(0.5, 0.5, 0.55)   # shared ramp
		var you: String = "  [you]" if str(m["fid"]) == _player_id else ""
		fr["name"].text = "%s  %d/%d%s" % [str(m["name"]), int(m["hp"]), int(m["maxHP"]), you]
		fr["sel"].visible = (str(m["fid"]) == _friend_id)
		(fr["status"] as StatusRow).drive(m.get("st", {}), str(m["fid"]))   # §3c: roster st (absent = clean/cross-zone)

func _make_party_frame(fid: String) -> Dictionary:
	var root := Panel.new()
	root.custom_minimum_size = Vector2(152.0, 52.0)  # §3c: +16px chip strip under the HP bar
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var psb := StyleBoxFlat.new()                    # P7: member rows speak the pattern language
	psb.bg_color = Color(Palette.SB_NAVY, 0.85)
	psb.set_border_width_all(1)
	psb.border_color = Color(Palette.SB_CYAN, 0.35)
	psb.set_corner_radius_all(4)
	root.add_theme_stylebox_override("panel", psb)
	var sel := ColorRect.new()
	sel.size = Vector2(152.0, 52.0)
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
	var status := StatusRow.new()                    # §3c: member statuses (roster st — works cross-zone)
	status.cap = 5
	status.chip_px = 14
	status.position = Vector2(3.0, 37.0)
	root.add_child(status)
	root.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_select_friend(fid))
	_party_panel.add_child(root)
	return {"root": root, "fid": fid, "fill": fill, "name": nm, "sel": sel, "status": status}

func _party_frames_preview(on: bool) -> void:
	_party_prev = on
	_sync_party_panel()

# HUD-edit preview: builder panel with sample status (it only shows for real while _lb_on)
func _lb_panel_preview(on: bool) -> void:
	if _lb_root == null:
		return
	if on:
		_lb_root.visible = true
		if str(_lb_lbl.text) == "":
			_lb_lbl.text = "▸ locker_bench  ·  yaw 45°  ·  size 1.0\nLMB place · G grab · X remove · F4 exit"
	else:
		_lb_root.visible = _lb_on
		if not _lb_on:
			_lb_lbl.text = ""

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
	btn.text = "Invite"
	btn.icon = IconRegistry.texture("party")          # party invite reuses the Party asset (§4)
	btn.expand_icon = false
	btn.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	btn.add_theme_constant_override("icon_max_width", 18)
	btn.add_theme_color_override("icon_normal_color", Palette.ACCENT2)
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
	if hud_edit_on and _hud_edit != null:            # a live prompt needs its buttons — leave edit mode
		(_hud_edit as HudEdit).close(true)
	_invite_from_fid = inviter_fid
	if _invite_prompt != null:
		_invite_prompt.queue_free()
	_invite_prompt = _invite_box(Palette.ACCENT, 2)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	_invite_prompt.add_child(vb)
	var titlerow := HBoxContainer.new()
	titlerow.alignment = BoxContainer.ALIGNMENT_CENTER
	titlerow.add_theme_constant_override("separation", 9)
	titlerow.add_child(IconWidget.make("party", {"px": 24, "color": Palette.ACCENT}))
	var title := Label.new()
	title.text = "PARTY INVITE"
	title.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	titlerow.add_child(title)
	vb.add_child(titlerow)
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
	if hud_edit_on and _hud_edit != null:            # Need/Want/Pass must be clickable (else auto-pass)
		(_hud_edit as HudEdit).close(true)
	var e: Dictionary = _loot_roll_queue.pop_front()
	var info: Dictionary = e["info"]
	_loot_roll_cur = int(e["drop_id"])
	_loot_roll_deadline = float(e["ms"]) / 1000.0
	_loot_roll_panel = _invite_box(Palette.ACCENT, 2)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_loot_roll_panel.add_child(vb)
	var titlerow := HBoxContainer.new()
	titlerow.alignment = BoxContainer.ALIGNMENT_CENTER
	titlerow.add_theme_constant_override("separation", 9)
	titlerow.add_child(IconWidget.make("random_roll", {"px": 24, "color": Palette.ACCENT}))   # party loot uses Random Roll (§4)
	var title := Label.new()
	title.text = "PARTY LOOT"
	title.add_theme_font_size_override("font_size", Palette.SIZE_TITLE)
	title.add_theme_color_override("font_color", Palette.ACCENT)
	titlerow.add_child(title)
	vb.add_child(titlerow)
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
	_toast("[b]%s[/b] won [color=%s]%s[/color]%s" % [_esc(winner), rcol, _esc(str(info.get("name", "?"))), roll_txt], Palette.ACCENT, false, "random_roll")

func _roster_name(fid: String) -> String:         # party-member display name from the roster (fallback to the fid)
	for m in _party:
		if str(m.get("fid", "")) == fid:
			return str(m.get("name", fid))
	return fid

# gameplay-length P2: the real level gate on the networked client, mirroring the server's submit_ability rule.
# Grandfathered characters (ability_ungated from the self sheet) keep the full kit. Local player only.
func _ability_locked(pf, key: String) -> bool:
	if pf == null:
		return false
	if bool(_state.get("self", {}).get("ability_ungated", false)):
		return false
	return int(pf.get("level", 1)) < GameData.ability_unlock_level(str(pf.get("classId", "")), key)

func _send_ability(key: String) -> void:
	if _ability_locked(_find_fighter(_player_id), key):   # gameplay-length P2: locked → the greyed "Lv N" slot is the feedback; don't send
		return
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
	_ult_banner.text = "FULL CAMP RESET  %d\nBREAK LINE OF SIGHT — GET BEHIND COVER" % int(ceil(uc))   # warning emoji dropped (§9); the red tint + countdown carry it

# P4: suppress the shared vignette/death juice while the session isn't live (connection error /
# pre-first-snapshot). _state is never cleared on a drop, so _render_world keeps running — without
# this the vignette/death would freeze on stale state under the disconnect overlay.
func _juice_suppressed() -> bool:
	return _net_msg != "" or _player_id == "" or _player == null

# P4 online-only juice: a gold level-up flash (z=160) + a zone-transition card (z=110). The shared
# vignette/death/toast layer is built by Client._build_hud; these two ride online-only events.
# ---- P8 event banners: ONE HERO-frame module for real states (zone arrival, level-up,
# respawn, circuit clear, drill complete). Live Godot text over the procedural frame (nothing
# baked); queued one-shots, one visible at a time; reduce_fx = steady-then-cut (no fades).
# Replaces the P4 full-screen zone card + level flash. Movable/scalable/hideable — non-critical
# celebrations only (the boss ult telegraph + disconnect overlay stay un-hideable, by design).
const BANNER_SIZE := Vector2(560, 150)
const BANNER_IN := 0.25
const BANNER_HOLD := 1.7
const BANNER_OUT := 0.45
var _banner_root: Control = null
var _banner_status: Label = null
var _banner_title: Label = null
var _banner_sub: Label = null
var _banner_queue := []
var _banner_t := -1.0                        # ≥0 while a banner plays
var _banner_preview := false
var _banner_dev := false                     # --bannertest: let the demo play pre-snapshot
var _last_alive := true                      # respawn detection (death overlay handles the death side)

func _build_event_banner() -> void:
	_banner_root = Control.new()
	_banner_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_root.custom_minimum_size = BANNER_SIZE
	_banner_root.size = BANNER_SIZE
	_banner_root.visible = false
	_hud.add_child(_banner_root)
	var frame := HudFrame.make(HudFrame.Tier.HERO, {})
	frame.size = BANNER_SIZE
	_banner_root.add_child(frame)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_root.add_child(cc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	cc.add_child(vb)
	_banner_status = HudFonts.display_label("", 15, Palette.SB_LIME, 0.26, Palette.SB_LIME)
	vb.add_child(_banner_status)
	_banner_title = HudFonts.display_label("", 30, Palette.TEXT_BRIGHT, 0.20)
	vb.add_child(_banner_title)
	_banner_sub = HudFonts.display_label("", 13, Color("#CFEFFF"), 0.24)
	vb.add_child(_banner_sub)
	HudLayout.register("event_banner", _banner_root, {"label": "Event Banner",
		"defaults": {"anchor": "top_center", "oy": 170.0}, "ref_size": BANNER_SIZE,
		"min_scale": 0.6, "max_scale": 1.4, "preview": _banner_module_preview})

# queue an event banner (status line color = semantic accent; sub optional)
func _show_banner(status: String, title: String, sub: String = "", col: Color = Palette.SB_LIME) -> void:
	_banner_queue.append({"s": status, "t": title, "b": sub, "c": col})
	if _banner_t < 0.0:
		_banner_next()

func _banner_set(l: Label, text: String, base: int, tracking: float) -> void:
	l.text = text.to_upper()
	l.add_theme_font_size_override("font_size", HudFonts.fit_size(text, base, tracking, 410.0))
	l.visible = text != ""

func _banner_next() -> void:
	if _banner_queue.is_empty():
		return
	var e: Dictionary = _banner_queue.pop_front()
	_banner_set(_banner_status, str(e["s"]), 15, 0.26)
	_banner_status.add_theme_color_override("font_color", e["c"])
	_banner_set(_banner_title, str(e["t"]), 30, 0.20)
	_banner_set(_banner_sub, str(e["b"]), 13, 0.24)
	_banner_t = 0.0

# per-frame one-shot driver (in → hold → out, then the next queued banner). Called from _process.
func _update_event_banner(dt: float) -> void:
	if _banner_root == null:
		return
	if _juice_suppressed() and not _banner_dev:  # disconnect/pre-snapshot: drop pending celebrations
		_banner_queue.clear()
		_banner_t = -1.0
		_banner_root.visible = false
		return
	if _banner_t < 0.0:
		if _banner_preview:                      # HUD-edit: hold a sample banner steady
			_banner_root.visible = true
			_banner_root.modulate.a = 1.0
		else:
			_banner_root.visible = false
		return
	_banner_t += dt
	if _banner_t >= BANNER_IN + BANNER_HOLD + BANNER_OUT:
		_banner_t = -1.0
		_banner_root.visible = false
		_banner_next()
		return
	var a := 1.0
	if _banner_t < BANNER_IN:
		a = _banner_t / BANNER_IN
	elif _banner_t > BANNER_IN + BANNER_HOLD:
		a = 1.0 - (_banner_t - BANNER_IN - BANNER_HOLD) / BANNER_OUT
	if reduce_fx:                                # no motion fade — steady then cut
		a = 0.0 if _banner_t > BANNER_IN + BANNER_HOLD else 1.0
	_banner_root.visible = a > 0.0
	_banner_root.modulate.a = a

func _banner_module_preview(on: bool) -> void:
	_banner_preview = on
	if on and _banner_t < 0.0:
		_banner_set(_banner_status, "Boss Event", 15, 0.26)
		_banner_status.add_theme_color_override("font_color", Palette.SB_ORANGE)
		_banner_set(_banner_title, "Head Coach", 30, 0.20)
		_banner_set(_banner_sub, "Prepare to Compete", 13, 0.24)

# ---- P8 interact prompt: ONE configurable module (keycap + action text in a UTILITY frame)
# replacing the 7 hand-positioned proximity hint labels. Proximity/keybind/panel-close logic
# stays in each _update_*_proximity — they just offer/clear by source name (change-gated).
var _ip_root: Control = null
var _ip_key: Label = null
var _ip_text: Label = null
var _ip_offers := {}                         # source -> {key, text}
var _ip_sig := ""
var _ip_preview := false

func _build_interact_prompt() -> void:
	var fd: Dictionary = HudFrame.fitted(HudFrame.Tier.UTILITY, {"stripe": true, "accent": Palette.SB_LIME, "body_alpha": 0.8})
	_ip_root = fd["root"]
	_ip_root.visible = false
	_hud.add_child(_ip_root)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 9)
	(fd["body"] as MarginContainer).add_child(hb)
	var cap := PanelContainer.new()              # keycap chip (same language as the hotbar keys)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(Palette.SB_INK, 0.9)
	csb.set_border_width_all(1)
	csb.border_color = Color(Palette.SB_CYAN, 0.45)
	csb.set_corner_radius_all(3)
	csb.content_margin_left = 7.0
	csb.content_margin_right = 7.0
	cap.add_theme_stylebox_override("panel", csb)
	_ip_key = Label.new()
	_ip_key.add_theme_font_size_override("font_size", 15)
	_ip_key.add_theme_color_override("font_color", Palette.SB_CYAN)
	cap.add_child(_ip_key)
	hb.add_child(cap)
	_ip_text = Label.new()
	_ip_text.add_theme_font_size_override("font_size", 15)
	_ip_text.add_theme_color_override("font_color", Palette.TEXT_BRIGHT)
	hb.add_child(_ip_text)
	HudLayout.register("interact_prompt", _ip_root, {"label": "Interact Prompt",
		"defaults": {"anchor": "bottom_center", "oy": -140.0}, "ref_size": Vector2(280, 42),
		"min_scale": 0.8, "max_scale": 1.6, "preview": _ip_module_preview})

func _interact_offer(src: String, key: String, text: String) -> void:
	var cur: Dictionary = _ip_offers.get(src, {})
	if str(cur.get("key", "")) == key and str(cur.get("text", "")) == text:
		return
	_ip_offers[src] = {"key": key, "text": text}
	_ip_render()

func _interact_clear(src: String) -> void:
	if _ip_offers.erase(src):
		_ip_render()

func _ip_render() -> void:
	if _ip_root == null:
		return
	var key := ""
	var text := ""
	if not _ip_offers.is_empty():
		var first: Dictionary = _ip_offers[_ip_offers.keys()[0]]
		key = str(first["key"])
		text = str(first["text"])
	elif _ip_preview:
		key = "F"
		text = "Forge — upgrade & reforge gear"
	var sig := key + "|" + text
	if sig != _ip_sig:
		_ip_sig = sig
		_ip_key.text = key
		_ip_text.text = text
	_ip_root.visible = key != ""

func _ip_module_preview(on: bool) -> void:
	_ip_preview = on
	_ip_render()

# ---- Minimap (P9 audit → build): a schematic top-down of EXACTLY what the snapshot carries.
# The server interest-filters fighters before they ever reach the client, so drawing
# `_state.fighters` verbatim reveals NOTHING beyond what nameplates already show — the
# no-hidden-info rule holds by construction. Pure client, zero protocol change. One module;
# custom _draw redrawn on a 10 Hz timer (never per frame), all mouse-transparent.
const MM_SIZE := Vector2(176, 176)
var _mm_root: Control = null
var _mm_canvas: Control = null
var _mm_preview := false

func _build_minimap() -> void:
	var fd: Dictionary = HudFrame.fitted(HudFrame.Tier.PANEL, {"body_alpha": 0.85})
	_mm_root = fd["root"]
	_hud.add_child(_mm_root)
	_mm_canvas = Control.new()
	_mm_canvas.custom_minimum_size = MM_SIZE
	_mm_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(fd["body"] as MarginContainer).add_child(_mm_canvas)
	_mm_canvas.draw.connect(_mm_draw)
	var t := Timer.new()
	t.wait_time = 0.1
	t.autostart = true
	add_child(t)
	t.timeout.connect(func() -> void:
		if _mm_canvas.is_visible_in_tree():
			_mm_canvas.queue_redraw())
	# default HIDDEN: a brand-new always-on module must not land on a returning player's saved
	# layout (default position changes never reach players who already saved) — opt in via F2
	HudLayout.register("minimap", _mm_root, {"label": "Minimap",
		"defaults": {"anchor": "top_right", "ox": -12.0, "oy": 12.0, "visible": false},
		"ref_size": Vector2(204, 204), "min_scale": 0.7, "max_scale": 1.5, "preview": _mm_module_preview})

func _mm_module_preview(on: bool) -> void:
	_mm_preview = on
	if _mm_canvas != null:
		_mm_canvas.queue_redraw()

func _mm_frame(area: Rect2) -> void:                 # play-area outline + a faint quarter grid
	_mm_canvas.draw_rect(area, Color(Palette.SB_CYAN, 0.25), false, 1.0)
	for i in range(1, 4):
		var fx := area.position.x + area.size.x * i / 4.0
		var fy := area.position.y + area.size.y * i / 4.0
		_mm_canvas.draw_line(Vector2(fx, area.position.y), Vector2(fx, area.end.y), Color(Palette.SB_CYAN, 0.06), 1.0)
		_mm_canvas.draw_line(Vector2(area.position.x, fy), Vector2(area.end.x, fy), Color(Palette.SB_CYAN, 0.06), 1.0)

# white camera-forward arrow. Only correct under a UNIFORM (letterbox) scale — with a uniform
# scale the raw fwd vector points the same way the player's blip actually slides (W → tip).
func _mm_arrow(center: Vector2) -> void:
	var fwd := Vector2(-sin(_yaw), -cos(_yaw))
	var side := Vector2(-fwd.y, fwd.x)
	_mm_canvas.draw_colored_polygon(PackedVector2Array([center + fwd * 7.0,
		center - fwd * 3.0 + side * 4.0, center - fwd * 3.0 - side * 4.0]), Color(1, 1, 1, 0.95))

func _mm_draw() -> void:
	var sz: Vector2 = _mm_canvas.size
	if _state.is_empty():
		_mm_frame(Rect2(Vector2.ZERO, sz))
		if _mm_preview:                              # HUD-edit pre-connect: sample content
			_mm_canvas.draw_circle(sz * 0.3, 3.0, WorldUI.HOSTILE)
			_mm_canvas.draw_circle(sz * Vector2(0.7, 0.4), 3.0, Color(0.55, 0.85, 1.0))
			_mm_arrow(sz * 0.5)
		return
	var aw := _aw()
	var ah := _ah()
	if aw <= 0.0 or ah <= 0.0:
		_mm_frame(Rect2(Vector2.ZERO, sz))
		return
	# LETTERBOX: one uniform scale so the map isn't stretched into an ellipse and the heading
	# arrow stays true (a non-uniform x/y scale desyncs the arrow from actual on-map travel)
	var s := minf(sz.x / aw, sz.y / ah)
	var off := (sz - Vector2(aw, ah) * s) * 0.5
	_mm_frame(Rect2(off, Vector2(aw, ah) * s))
	var to_px := func(px: float, py: float) -> Vector2:
		return off + Vector2(clampf(px, 0.0, aw), clampf(py, 0.0, ah)) * s
	# portals: cyan diamonds
	for p in _state.get("portals", []):
		var pp: Vector2 = to_px.call(float(p.get("x", 0.0)), float(p.get("y", 0.0)))
		_mm_canvas.draw_colored_polygon(PackedVector2Array([pp + Vector2(0, -4), pp + Vector2(4, 0),
			pp + Vector2(0, 4), pp + Vector2(-4, 0)]), Color(Palette.SB_CYAN, 0.9))
	# home-base service pads: color-coded squares (null off the home map)
	for entry in [["shop", Palette.CREDITS], ["forge", Palette.SB_ORANGE], ["questgiver", Palette.ACCENT2],
			["practice", Palette.TOKENS], ["build_shop", Palette.LAVENDER], ["locker_portal", Palette.ACCENT]]:
		var pad = _home_pad(str(entry[0]))
		if pad != null:
			var sq: Vector2 = to_px.call(float(pad.get("x", 0.0)), float(pad.get("y", 0.0)))
			_mm_canvas.draw_rect(Rect2(sq - Vector2(3, 3), Vector2(6, 6)), entry[1])
	# fighters + self need a valid self reference — until assign_fighter lands (a reliable RPC that
	# can arrive AFTER an unreliable snapshot), skip them so mobs never miscolor as friendly and
	# the local player never draws as a stray arrow-less dot
	var lpf = _find_fighter(_player_id)
	if _player_id == "" or lpf == null:
		return
	for f in _state.get("fighters", []):
		if not bool(f.get("alive", true)) or str(f.get("id", "")) == _player_id:
			continue
		var fp: Vector2 = to_px.call(float(f.get("x", 0.0)), float(f.get("y", 0.0)))
		var col: Color = WorldUI.DUMMY
		if not bool(f.get("dummy", false)):
			col = WorldUI.HOSTILE if _hostile_pair(lpf, f) else WorldUI.friendly_plate(_class_vfx_color(str(f.get("classId", ""))))
		_mm_canvas.draw_circle(fp, 4.0 if str(f.get("mobTier", "")) != "" else 3.0, col)
	_mm_arrow(to_px.call(float(lpf.get("x", 0.0)), float(lpf.get("y", 0.0))))

# ---- P9 bottom navigation: clickable shortcuts to the REAL panels with their REAL keybinds
# (no invented entries; NetClient-only, so practice mode never shows unavailable items).
# One configurable module — hideable for keyboard-only minimal HUDs.
var _nav_root: Control = null
var _nav_items := []                         # [{btn, panel: Callable, open}]

func _build_bottom_nav() -> void:
	var fd: Dictionary = HudFrame.fitted(HudFrame.Tier.UTILITY, {"body_alpha": 0.75})
	_nav_root = fd["root"]
	_nav_root.visible = false                    # shown once a snapshot arrives
	_hud.add_child(_nav_root)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 3)
	(fd["body"] as MarginContainer).add_child(hb)
	var entries := [
		["Inventory", "I", _toggle_inventory, func(): return _inv_panel],
		["Character", "K", _toggle_charsheet, func(): return _sheet_panel],
		["Quests", "J", _toggle_questlog, func(): return _quest_panel],
		["Locker", "U", _toggle_locker, func(): return _locker_panel],
		["Wardrobe", "G", _toggle_wardrobe, func(): return _wardrobe_panel],
		["Talents", "T", _toggle_talents, func(): return _talent_panel],
		["Bench", "B", _toggle_paragon, func(): return _paragon_panel],
		["Boards", "L", _toggle_leaderboard, func(): return _lb_panel],
		["Meter", "N", _toggle_meter, func(): return _meter_panel],
		["Settings", "O", _toggle_settings, func(): return _settings_panel],
	]
	for e in entries:
		var b := _meter_btn("%s %s" % [str(e[0]), str(e[1])], e[2])
		b.add_theme_color_override("font_color", Palette.TEXT_DIM)
		b.tooltip_text = "%s  (key %s)" % [str(e[0]), str(e[1])]
		hb.add_child(b)
		_nav_items.append({"btn": b, "panel": e[3], "open": false})
	HudLayout.register("bottom_nav", _nav_root, {"label": "Bottom Nav",
		"defaults": {"anchor": "bottom_right", "ox": -12.0, "oy": -10.0},
		"ref_size": Vector2(640, 38), "min_scale": 0.8, "max_scale": 1.3,
		"preview": _nav_preview})

# HUD-edit preview: the nav is hidden pre-snapshot, and hidden Controls never lay out (size 0)
# — show it while editing so it has a real rect to place
func _nav_preview(on: bool) -> void:
	if _nav_root != null:
		_nav_root.visible = on or not _state.is_empty()

# selected-state sync (change-gated recolor; cheap visibility reads once per frame)
func _update_bottom_nav() -> void:
	if _nav_root == null:
		return
	_nav_root.visible = true
	for it in _nav_items:
		var p = (it["panel"] as Callable).call()
		var open: bool = p != null and (p as Control).visible
		if bool(it["open"]) != open:
			it["open"] = open
			(it["btn"] as Button).add_theme_color_override("font_color",
				Palette.ACCENT if open else Palette.TEXT_DIM)

func _process(delta: float) -> void:
	if supa != null and net != null and _connected:
		_reauth_t += delta
		if _reauth_t >= REAUTH_INTERVAL:
			_reauth_t = 0.0
			_do_reauth()
	_update_event_banner(delta)     # P8: pure-client one-shots — must run even pre-snapshot
	if _state.is_empty():
		_update_hud()          # still show the connecting/error banner before any snapshot
		return
	_sync_nodes_to_state()
	_render_world(delta)
	_update_boss_telegraph()
	_update_focus()
	_update_party()          # validates _friend_id BEFORE the frames read it (no one-frame stale row)
	_update_unit_frames()
	_update_bottom_nav()
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
	_update_loot_roll(delta)        # party loot want/need/pass countdown → auto-pass
	if _locker_panel != null and _locker_panel.visible and _locker_model_holder != null:
		_locker_model_holder.rotation.y += delta * 0.5   # slow turntable on the locker figure

# ---- transport callbacks ----
func _on_connected() -> void:
	_connected = true
	_net_msg = ""
	_net_msg_final = false
	print("[netclient] connected — authenticating to the zone (protocol v%d)" % NetProtocol.VERSION)
	if net != null:
		# prefer the LIVE supa token (reauth keeps it fresh) over the boot-time snapshot; the hello
		# carries the protocol version the server validates before any token work (stabilization P5)
		var tok: String = supa.access_token if (supa != null and supa.access_token != "") else access_token
		net.authenticate.rpc_id(1, tok, NetProtocol.hello())

# keep the server's access token fresh without ever sending the refresh token over the wire
func _do_reauth() -> void:
	if supa != null and await supa.refresh_session() and net != null:
		net.reauth.rpc_id(1, supa.access_token)

# server → client: a specific, player-facing refusal reason (single-session refusal, protocol
# mismatch, auth failure), sent reliably just before the server drops us. STICKY: the generic
# "Disconnected from the zone." that follows the transport drop must not overwrite the real cause.
var _net_msg_final := false
func recv_denied(reason: String) -> void:
	_net_msg_final = true
	_net_msg = reason
	push_warning("[netclient] denied: " + reason)

# shown on the HUD when the connection fails or the server goes away
func net_error(msg: String) -> void:
	if _net_msg_final:
		return                        # a server-sent reason already owns the disconnect overlay
	_net_msg = msg
	push_warning("[netclient] " + msg)

func receive_snapshot(snap: Dictionary) -> void:
	# the server ships the quasi-static META (self sheet / portals / zone pads / locker decals) only when it
	# changes; cache it and overlay onto every snapshot so _state always carries the current values.
	if snap.has("meta"):
		_meta = snap["meta"]
	for k in _meta:
		snap[k] = _meta[k]
	_state = snap
	_party = snap.get("party", [])
	if not _cap_seeded and _player_id != "":             # one-time: seed the gear count for the near-cap warning
		_cap_seeded = true
		_seed_gear_count()
	if _sheet_panel != null and _sheet_panel.visible:    # keep the character sheet live while it's open
		_render_charsheet()
	if _locker_panel != null and _locker_panel.visible:  # keep the locker's model + header + stats live
		_update_locker_model()
		_update_locker_header()
		_update_locker_stats()                           # sig-guarded → rebuilds only when a value actually changed
	if _talent_panel != null and _talent_panel.visible:  # keep the Talents panel's credits / points / affordability live
		var tsig := "%d|%d|%d" % [_my_level_val(), _my_talent_spent(), _my_credits_val()]
		if tsig != _talent_sig:
			_talent_sig = tsig
			_render_talents()
	if _paragon_panel != null and _paragon_panel.visible:  # keep the Bench Board live (overtime rides recv_overtime; this catches META-driven spent/gear-bag changes)
		var psig := "%d|%d|%d" % [_overtime_xp, _my_paragon_spent(), _my_gear_bag()]
		if psig != _paragon_sig:
			_paragon_sig = psig
			_render_paragon()
	if _player != null and _player_id != "":
		var pf = _find_fighter(_player_id)
		if pf != null and _player.class_id != pf["classId"]:
			_player.class_id = pf["classId"]
	var map := str(snap.get("map", ""))          # zone change → portal whoosh + music crossfade + P4 zone card
	if map != _last_map:
		if _last_map != "":
			AudioManager.play_sfx("portal")
			# P8: "Now Entering" hero banner (not on the first login zone-in)
			_show_banner("Now Entering", _zone_name(map),
				"open pvp zone" if bool(snap.get("pvp", false)) else "", Palette.SB_CYAN)
		_last_map = map
		_pred_on = false                         # reseed local-player prediction at the new zone's spawn (no cross-zone snap)
		AudioManager.play_music(map)
		if map == World.LOCKER:                  # Builder Mode: onboarding "how to build" popup on entering your Locker Room
			_on_enter_locker()
	var lpf = _find_fighter(_player_id)           # level-up fanfare + P4 flash/toast
	if lpf != null:
		var lvl := int(lpf.get("level", 1))
		if _last_level > 0 and lvl > _last_level:
			AudioManager.play_sfx("level_up")
			_show_banner("Level Up", "Level %d" % lvl)   # P8: replaces the full-screen gold flash
			_toast("[b]LEVEL UP[/b]\nYou reached [color=%s]Level %d[/color]" % [Palette.hex(Palette.ACCENT), lvl], Palette.ACCENT, true)
		_last_level = lvl
		var alive_now := bool(lpf.get("alive", true))    # P8: respawn banner (death side = overlay)
		if alive_now and not _last_alive:
			_show_banner("Respawn", "Back In The Game", "", Palette.SB_CYAN)
		_last_alive = alive_now
	var unlocked_now := _locker_unlocked()        # Builder Mode: toast the first time you own your Locker Room
	if unlocked_now and not _was_locker_unlocked:
		_toast("[color=#9fe8a0]Locker Room unlocked![/color]\nWalk through the portal in the home base to enter.", Palette.ACCENT, false, "unlocked")
	_was_locker_unlocked = unlocked_now
	_handle_events()             # spawn damage-number / hit FX from this snapshot's events
	if _dev_open != "" and _player_id != "" and _find_fighter(_player_id) != null and _dev_walkto.x == INF:
		_dev_open_panel()        # dev screenshot hook: open a panel once we have a live fighter (+ finished any --walkto)
	if _dev_juice and _player_id != "" and _find_fighter(_player_id) != null:
		_dev_juice = false       # dev screenshot hook: fire the P4 juice once (toasts + zone card + flash)
		_toast("[color=#ffd24d]Looted[/color]  [color=#c77dff]Epic Cleats[/color]\n[color=#7f93a8]epic · feet  +18 SPD[/color]", Color.html("#c77dff"), false, "loot")
		_toast("[color=#9fe8a0]✔ Quest complete:[/color] Boot Camp", Palette.ACCENT)
		_toast("[b]LEVEL UP[/b]\nYou reached [color=%s]Level 3[/color]" % Palette.hex(Palette.ACCENT), Palette.ACCENT, true)
		_show_banner("Now Entering", "The Glitchyard", "", Palette.SB_CYAN)

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
		if e.keycode == KEY_F2 and not _chatting:    # configurable-HUD P3: HUD edit mode
			_hud_edit_toggle()
			get_viewport().set_input_as_handled()
			return
		if hud_edit_on:                              # editing: Esc cancels drag → saves + exits;
			if e.keycode == KEY_ESCAPE and _hud_edit != null:   # every other key is swallowed so
				if not (_hud_edit as HudEdit).handle_escape():  # panel toggles can't fire mid-edit
					(_hud_edit as HudEdit).close(true)
			get_viewport().set_input_as_handled()
			return
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
			elif _controls_panel != null and _controls_panel.visible:
				_controls_panel.visible = false
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
			elif _build_shop_panel != null and _build_shop_panel.visible:
				_build_shop_panel.visible = false    # P10: was the ONE window missing from this cascade
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
			elif _talent_panel != null and _talent_panel.visible:
				_talent_panel.visible = false
				get_viewport().set_input_as_handled()
				return
			elif _paragon_panel != null and _paragon_panel.visible:
				_paragon_panel.visible = false
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
		elif e.keycode == KEY_T and not _chatting:
			_toggle_talents()               # the Talent tree (gameplay-length P4) — usable anywhere
			get_viewport().set_input_as_handled()
			return
		elif e.keycode == KEY_B and not _chatting:
			_toggle_paragon()               # the Paragon Bench Board (gameplay-length P5) — usable anywhere
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
	_vit_set("credits", _tray_credits, "%d" % int(pf.get("credits", 0)))   # icon carries identity
	_vit_set("scrap", _tray_scrap, "%d" % _my_scrap())
	_vit_set("tokens", _tray_tokens, "%d" % _my_tokens())
	_zone_banner.visible = true
	var pvp := bool(_state.get("pvp", false))
	var zone := _zone_name(str(_state.get("map", "")))
	_vit_set("zone", _zone_label, ("%s · PVP" % zone.to_upper()) if pvp else zone.to_upper())   # hostile-swords prefix dropped (§9); the red PVP text + tint carry hostility
	if bool(_vit_cache.get("zone_pvp", false)) != pvp:
		_vit_cache["zone_pvp"] = pvp
		_zone_label.add_theme_color_override("font_color", Palette.DANGER if pvp else Palette.ACCENT2)
	_update_hotbar(pf)                           # the visual skill bar (shared with local mode)

func _zone_name(map: String) -> String:
	match map:
		"home": return "Home Base"
		"glitchyard_1": return "Glitchyard · Rookie Intake"
		"glitchyard_2": return "Glitchyard · Agility Grid"
		"glitchyard_3": return "Glitchyard · Impact Lanes"
		"glitchyard_4": return "Glitchyard · Target Court"
		"glitchyard_5": return "Glitchyard · Command Tower"
		"away_1": return "Away Games · Rival Practice Field"
		"away_2": return "Away Games · Visitors' Gauntlet"
		"away_3": return "Away Games · Rival Stadium"
		"away_boss": return "Away Games · Rival Sideline"
		"finals_1": return "The Finals · Contenders' Quarter"
		"finals_2": return "The Finals · Champions' Gate"
		"arena": return "Arena"
		"camp": return "Camp Circuit · Proving Room"
		"camp_b": return "Camp Circuit · The Gauntlet"
		"camp_c": return "Camp Circuit · The Scrimmage"
		"drill": return "Two-Minute Drill"
		_: return map.capitalize() if map != "" else "—"
