extends Node
## Global audio (autoload). Buses Master→{Music, SFX}; a name→AudioStream "sound bank" loaded from
## res://audio/sfx and res://audio/music (drop a correctly-named file in to enable that sound —
## anything missing is simply SILENT, so the whole system works before any audio exists); pooled
## 3D-positional SFX voices + a 2D UI voice; a two-player music crossfade; and Master/Music/SFX
## volume + mute persisted to user://settings.cfg. Inert on the headless zone server (--server).
##
## To add real audio later: drop files named like the SFX_NAMES / per-zone MUSIC into res://audio/
## (.ogg / .wav / .mp3) and re-export. No code change needed.

const SFX_DIR := "res://audio/sfx/"
const MUSIC_DIR := "res://audio/music/"
const SETTINGS_PATH := "user://settings.cfg"
const SFX_VOICES := 12

# the sound bank — logical names the game asks for; a res://audio/sfx/<name>.{ogg,wav,mp3} enables it.
const SFX_NAMES := [
	"hit", "crit", "death", "respawn",
	"cast_melee", "cast_ranged", "cast_ability", "cast_support", "cast_ult",
	"level_up", "loot", "quest", "ui_click", "portal",
]

var _sfx := {}                       # name -> AudioStream (or null = silent)
var _voices: Array = []              # pooled AudioStreamPlayer3D
var _vi := 0
var _ui: AudioStreamPlayer
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_on_a := true
var _music_cur := ""
var _ready_done := false

var vol := {"Master": 0.9, "Music": 0.6, "SFX": 0.95}   # 0..1 linear, per bus
var muted := false

func _ready() -> void:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	if "--server" in args:               # the dedicated zone server has no audio — stay fully inert
		return
	_ensure_buses()
	for n in SFX_NAMES:
		_sfx[n] = _try_load(SFX_DIR + n)
	for i in SFX_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.max_distance = 70.0
		p.unit_size = 10.0
		add_child(p)
		_voices.append(p)
	_ui = _mk_player("SFX")
	_music_a = _mk_player("Music")
	_music_b = _mk_player("Music")
	_load_settings()
	_apply_volumes()
	_ready_done = true

func _mk_player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p

func _ensure_buses() -> void:
	for b in ["Music", "SFX"]:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, b)
			AudioServer.set_bus_send(idx, "Master")

func _try_load(base: String) -> Variant:
	for ext in [".ogg", ".wav", ".mp3"]:
		if ResourceLoader.exists(base + ext):
			return load(base + ext)
	return null

# play a sound effect. pos = a Vector3 for positional 3D (combat); null for a flat UI sound.
func play_sfx(name: String, pos = null, pitch := 1.0) -> void:
	if not _ready_done:
		return
	var s = _sfx.get(name)
	if s == null:
		return
	if pos == null:
		_ui.stream = s
		_ui.pitch_scale = pitch
		_ui.play()
	else:
		var v: AudioStreamPlayer3D = _voices[_vi]
		_vi = (_vi + 1) % _voices.size()
		v.stream = s
		v.global_position = pos
		v.pitch_scale = pitch
		v.play()

# crossfade to a zone's music track (res://audio/music/<name>.{ogg,..}). Loops; no-op if absent.
func play_music(name: String) -> void:
	if not _ready_done or name == _music_cur:
		return
	var s = _try_load(MUSIC_DIR + name)
	_music_cur = name
	var fade_in: AudioStreamPlayer = _music_b if _music_on_a else _music_a
	var fade_out: AudioStreamPlayer = _music_a if _music_on_a else _music_b
	_music_on_a = not _music_on_a
	var tw := create_tween()
	if is_instance_valid(fade_out) and fade_out.playing:
		tw.parallel().tween_property(fade_out, "volume_db", -40.0, 1.2)
		tw.chain().tween_callback(fade_out.stop)
	if s != null:
		fade_in.stream = s
		fade_in.volume_db = -40.0
		fade_in.play()
		tw.parallel().tween_property(fade_in, "volume_db", 0.0, 1.2)

# ---- volume / mute / settings ----
func set_volume(bus: String, linear: float) -> void:
	vol[bus] = clampf(linear, 0.0, 1.0)
	_apply_volumes()
	_save_settings()

func set_muted(on: bool) -> void:
	muted = on
	_apply_volumes()
	_save_settings()

func _apply_volumes() -> void:
	for b in vol:
		var idx := AudioServer.get_bus_index(b)
		if idx >= 0:
			AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(0.0001, float(vol[b]))))
			AudioServer.set_bus_mute(idx, muted)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	muted = bool(cfg.get_value("audio", "muted", muted))
	for b in vol:
		vol[b] = float(cfg.get_value("audio", b, vol[b]))

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)               # keep any other sections
	for b in vol:
		cfg.set_value("audio", b, vol[b])
	cfg.set_value("audio", "muted", muted)
	cfg.save(SETTINGS_PATH)
