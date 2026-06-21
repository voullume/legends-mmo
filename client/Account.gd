extends CanvasLayer
## ACCOUNT FRONT-END (Phase 3). Log in / sign up, then create-or-load this account's ONE
## character. The class is chosen once at creation and is immutable (enforced by the DB) — the
## UI never offers a way to change it. On "Enter World" it hands the character to the game.

signal entered(supa, character)

const Supa := preload("res://client/Supabase.gd")
const GameData := preload("res://shared/GameData.gd")
const PLAYABLE := ["striker", "batter", "spiker", "linebacker", "pitcher", "quarterback", "setter", "goalkeeper"]

var supa
var _email: LineEdit
var _pass: LineEdit
var _cname: LineEdit
var _status: Label
var _auth: Control
var _create: Control
var _enter: Control
var _enter_label: RichTextLabel
var _class_desc: RichTextLabel
var _picked := ""
var _class_btns := {}
var _character = null
var _busy := false           # one in-flight async op at a time (no double-click re-entrancy)
var _entered_once := false   # entered() may fire only once (guards double-boot)

func _ready() -> void:
	supa = Supa.new()
	add_child(supa)
	_build()
	_goto(_auth)

# ---------- UI construction ----------
func _bg() -> void:
	var cr := ColorRect.new()
	cr.color = Color(0.05, 0.06, 0.09)
	cr.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(cr)

func _panel(title: String) -> CenterContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var pc := PanelContainer.new()
	pc.custom_minimum_size = Vector2(460, 0)
	center.add_child(pc)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 24)
	pc.add_child(m)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	m.add_child(vb)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 26)
	vb.add_child(t)
	center.set_meta("vb", vb)
	return center

func _edit(placeholder: String, secret := false) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.secret = secret
	le.custom_minimum_size = Vector2(0, 36)
	return le

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(cb)
	return b

func _build() -> void:
	_bg()
	# --- auth panel ---
	_auth = _panel("Legends MMO — Sign In")
	var avb: VBoxContainer = _auth.get_meta("vb")
	_email = _edit("email")
	_pass = _edit("password", true)
	avb.add_child(_email)
	avb.add_child(_pass)
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 10)
	arow.add_child(_button("Log In", _on_login))
	arow.add_child(_button("Sign Up", _on_signup))
	avb.add_child(arow)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(412, 0)
	_status.add_theme_color_override("font_color", Color(0.7, 0.78, 0.9))
	avb.add_child(_status)

	# --- create-character panel ---
	_create = _panel("Create Your Character")
	var cvb: VBoxContainer = _create.get_meta("vb")
	cvb.add_child(_label("Your class is permanent — choose once."))
	_cname = _edit("character name")
	cvb.add_child(_cname)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	for cid in PLAYABLE:
		var c: Dictionary = GameData.CLASSES[cid]
		var b := Button.new()
		b.text = "%s (%s)" % [c["name"], c["sport"]]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(210, 34)
		b.pressed.connect(_on_pick.bind(cid))
		_class_btns[cid] = b
		grid.add_child(b)
	cvb.add_child(grid)
	_class_desc = RichTextLabel.new()
	_class_desc.bbcode_enabled = true
	_class_desc.fit_content = true
	_class_desc.custom_minimum_size = Vector2(412, 44)
	cvb.add_child(_class_desc)
	cvb.add_child(_button("Create & Enter World", _on_create))

	# --- returning-player panel ---
	_enter = _panel("Welcome Back")
	var evb: VBoxContainer = _enter.get_meta("vb")
	_enter_label = RichTextLabel.new()
	_enter_label.bbcode_enabled = true
	_enter_label.fit_content = true
	_enter_label.custom_minimum_size = Vector2(412, 60)
	evb.add_child(_enter_label)
	evb.add_child(_button("Enter World", _on_enter))

func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color(0.62, 0.7, 0.82))
	return l

func _goto(panel: Control) -> void:
	_auth.visible = panel == _auth
	_create.visible = panel == _create
	_enter.visible = panel == _enter

# ---------- flow ----------
func _on_login() -> void:
	if _busy:
		return
	_busy = true
	_status.text = "Signing in…"
	var r = await supa.sign_in(_email.text.strip_edges(), _pass.text)
	if not r.get("ok"):
		_status.text = "Login failed: " + str(r.get("error", ""))
		_busy = false
		return
	await _load_or_create()
	_busy = false

func _on_signup() -> void:
	if _busy:
		return
	_busy = true
	_status.text = "Creating account…"
	var r = await supa.sign_up(_email.text.strip_edges(), _pass.text)
	if not r.get("ok"):
		_status.text = "Sign-up failed: " + str(r.get("error", ""))
		_busy = false
		return
	if r.get("needs_confirm"):
		_status.text = "Account created. Confirm via the email we sent, then Log In."
		_busy = false
		return
	await _load_or_create()
	_busy = false

func _load_or_create() -> void:
	var c = await supa.get_character()
	if not c.get("ok"):
		_status.text = "Could not load character: " + str(c.get("error", ""))
		return
	_character = c.get("character")
	if _character != null:
		var cl: Dictionary = GameData.CLASSES.get(_character["class"], {})
		_enter_label.text = "[b]%s[/b]\n[color=#9fb4c8]%s · %s · level %d[/color]" % [
			_character.get("name", "?"), cl.get("name", _character["class"]), cl.get("role", ""), int(_character.get("level", 1))]
		_goto(_enter)
	else:
		_goto(_create)

func _on_pick(cid: String) -> void:
	_picked = cid
	for k in _class_btns:
		_class_btns[k].button_pressed = (k == cid)
	var c: Dictionary = GameData.CLASSES[cid]
	_class_desc.text = "[b]%s[/b] — [color=#9fb4c8]%s · %s[/color]\n%s" % [c["name"], c["sport"], c["role"], _kit_line(c)]

func _kit_line(c: Dictionary) -> String:
	var s: Dictionary = c["stats"]
	return "[color=#7f93a8]PWR %d · END %d · SPD %d[/color]" % [s["PWR"], s["END"], s["SPD"]]

func _on_create() -> void:
	if _busy:
		return
	var nm := _cname.text.strip_edges()
	if nm.length() < 1 or nm.length() > 24:
		_class_desc.text = "[color=#ff8a8a]Enter a name (1–24 characters).[/color]"
		return
	if _picked == "":
		_class_desc.text = "[color=#ff8a8a]Pick a class — it's permanent.[/color]"
		return
	_busy = true
	_class_desc.text = "Creating…"
	var r = await supa.create_character(nm, _picked)
	if not r.get("ok"):
		_class_desc.text = "[color=#ff8a8a]Create failed: " + str(r.get("error", "")) + "[/color]"
		_busy = false
		return
	_character = r.get("character")
	_enter_world()

func _on_enter() -> void:
	_enter_world()

func _enter_world() -> void:
	if _entered_once:
		return
	_entered_once = true
	entered.emit(supa, _character)
