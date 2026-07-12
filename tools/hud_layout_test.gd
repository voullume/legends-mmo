extends SceneTree
## Configurable-HUD P2 test harness — exercises HudLayout's registry, placement math,
## persistence (round-trip, unknown ids, missing fields, corrupt entries, foreign-section
## preservation, version tolerance), profiles, clamping and global UI scale. Headless-safe:
##   godot --headless --path . --script res://tools/hud_layout_test.gd
## Exits non-zero on any failure (CI-compatible; greppable "FAIL").

const HudLayoutS := preload("res://client/ui/HudLayout.gd")

const TEST_CFG := "user://hud_layout_test.cfg"

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)
	else:
		print("  ok: %s" % what)

func approx(a: float, b: float, eps := 1.5) -> bool:
	return absf(a - b) <= eps

func _initialize() -> void:
	_run()

func _make_nodes(host: Control) -> Dictionary:
	var a := Control.new()
	a.size = Vector2(260, 120)
	host.add_child(a)
	var b := Control.new()
	b.size = Vector2(480, 60)
	host.add_child(b)
	return {"a": a, "b": b}

func _register_pair(n: Dictionary) -> void:
	HudLayoutS.register("player_frame", n["a"], {"label": "Player Frame",
		"defaults": {"anchor": "top_left", "ox": 12.0, "oy": 10.0}, "ref_size": Vector2(260, 120)})
	HudLayoutS.register("hotbar", n["b"], {"label": "Hotbar",
		"defaults": {"anchor": "bottom_center", "oy": -26.0}, "ref_size": Vector2(480, 60)})

func _run() -> void:
	print("[hud_layout_test] start")
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	HudLayoutS.cfg_path = TEST_CFG
	HudLayoutS.reset_registry()

	var host := Control.new()
	host.size = Vector2(1600, 900)
	root.add_child(host)
	var vp: Vector2 = HudLayoutS._viewport_size()

	# --- registration + default placement
	var n := _make_nodes(host)
	_register_pair(n)
	ok(HudLayoutS.ids() == ["player_frame", "hotbar"], "registration order")
	var w_a: Control = (n["a"] as Control).get_parent()
	ok(w_a != null and w_a.name == "HudMod_player_frame", "node reparented into wrapper")
	ok(w_a.position.is_equal_approx(Vector2(12, 10)), "top_left default placement (12,10) got %s" % w_a.position)
	var r_b: Rect2 = HudLayoutS.rect("hotbar")
	ok(approx(r_b.position.x + r_b.size.x * 0.5, vp.x * 0.5), "hotbar horizontally centered")
	ok(approx(r_b.end.y, vp.y - 26.0), "hotbar bottom edge at vp-26 got %.1f (vp %.0f)" % [r_b.end.y, vp.y])

	# --- field clamps
	HudLayoutS.set_field("player_frame", "scale", 9.0)
	ok(approx(float(HudLayoutS.layout("player_frame")["scale"]), HudLayoutS.SCALE_MAX, 0.001), "scale clamped to max")
	HudLayoutS.set_field("player_frame", "opacity", -2.0)
	ok(approx(float(HudLayoutS.layout("player_frame")["opacity"]), HudLayoutS.OPACITY_MIN, 0.001), "opacity clamped to floor")
	HudLayoutS.set_field("player_frame", "anchor", "not_an_anchor")
	ok(str(HudLayoutS.layout("player_frame")["anchor"]) == "top_left", "bad anchor rejected")
	HudLayoutS.reset_module("player_frame")
	ok(approx(float(HudLayoutS.layout("player_frame")["scale"]), 1.0, 0.001), "reset_module restores defaults")

	# --- scaled anchored placement: scale change keeps the anchored corner pinned
	HudLayoutS.set_field("hotbar", "scale", 1.5)
	var r_b2: Rect2 = HudLayoutS.rect("hotbar")
	ok(approx(r_b2.size.x, 480.0 * 1.5), "scaled rect width")
	ok(approx(r_b2.position.x + r_b2.size.x * 0.5, vp.x * 0.5), "scaled hotbar stays centered")
	ok(approx(r_b2.end.y, vp.y - 26.0), "scaled hotbar bottom edge pinned")

	# --- drag → normalized storage → save/load round-trip
	HudLayoutS.set_position_from_rect("player_frame", Vector2(300, 200))
	var r_a: Rect2 = HudLayoutS.rect("player_frame")
	ok(r_a.position.is_equal_approx(Vector2(300, 200)), "set_position_from_rect lands exactly")
	HudLayoutS.set_field("player_frame", "opacity", 0.7)
	HudLayoutS.mark_custom()
	HudLayoutS.save()

	HudLayoutS.reset_registry()
	HudLayoutS.cfg_path = TEST_CFG
	var host2 := Control.new()
	host2.size = Vector2(1600, 900)
	root.add_child(host2)
	var n2 := _make_nodes(host2)
	_register_pair(n2)
	var r_a2: Rect2 = HudLayoutS.rect("player_frame")
	ok(r_a2.position.is_equal_approx(Vector2(300, 200)), "round-trip position restored got %s" % r_a2.position)
	ok(approx(float(HudLayoutS.layout("player_frame")["opacity"]), 0.7, 0.001), "round-trip opacity restored")
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), 1.5, 0.001), "round-trip scale restored")
	ok(HudLayoutS.profile() == "custom", "round-trip profile restored")

	# --- unknown id kept on disk, missing fields defaulted, corrupt entry dropped
	var cfg := ConfigFile.new()
	cfg.load(TEST_CFG)
	cfg.set_value("hud_modules", "future_module", {"scale": 1.2})
	cfg.set_value("hud_modules", "player_frame", {"scale": 0.3})   # partial: other fields must default; 0.3 < min clamps
	cfg.set_value("hud_modules", "hotbar", "corrupt-not-a-dict")
	cfg.set_value("hud", "layout_version", 99)
	cfg.set_value("audio", "Master", 0.42)
	cfg.save(TEST_CFG)

	HudLayoutS.reset_registry()
	HudLayoutS.cfg_path = TEST_CFG
	var host3 := Control.new()
	host3.size = Vector2(1600, 900)
	root.add_child(host3)
	var n3 := _make_nodes(host3)
	_register_pair(n3)
	ok(approx(float(HudLayoutS.layout("player_frame")["scale"]), HudLayoutS.SCALE_MIN, 0.001), "partial entry: scale clamped to min")
	ok(str(HudLayoutS.layout("player_frame")["anchor"]) == "top_left", "partial entry: missing anchor defaulted")
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), 1.0, 0.001), "corrupt entry falls back to defaults")
	HudLayoutS.save()
	var cfg2 := ConfigFile.new()
	cfg2.load(TEST_CFG)
	ok(cfg2.has_section_key("hud_modules", "future_module"), "unknown module id preserved on save")
	ok(approx(float(cfg2.get_value("audio", "Master", -1.0)), 0.42, 0.001), "foreign [audio] section preserved")
	ok(int(cfg2.get_value("hud", "layout_version", -1)) == HudLayoutS.VERSION, "version rewritten to supported")

	# --- wrong-TYPED fields inside an otherwise-valid dict (bool("true") is a nonexistent
	# constructor — a naive cast crashes _sanitize and nukes the whole entry)
	var cfgt := ConfigFile.new()
	cfgt.load(TEST_CFG)
	cfgt.set_value("hud_modules", "player_frame", {"visible": "true", "locked": 1.0, "scale": "big", "opacity": 0.5})
	cfgt.save(TEST_CFG)
	HudLayoutS.reset_registry()
	HudLayoutS.cfg_path = TEST_CFG
	var host3b := Control.new()
	host3b.size = Vector2(1600, 900)
	root.add_child(host3b)
	var n3b := _make_nodes(host3b)
	_register_pair(n3b)
	ok(bool(HudLayoutS.layout("player_frame")["visible"]) == true, "string-typed visible defaulted, no crash")
	ok(bool(HudLayoutS.layout("player_frame")["locked"]) == true, "numeric locked coerced to bool")
	ok(approx(float(HudLayoutS.layout("player_frame")["scale"]), 1.0, 0.001), "string-typed scale defaulted")
	ok(approx(float(HudLayoutS.layout("player_frame")["opacity"]), 0.5, 0.001), "valid field in the same entry survives")

	# --- snapshot → mutate → restore (the edit-mode Cancel path)
	var snap: Dictionary = HudLayoutS.layout("hotbar")
	HudLayoutS.set_field("hotbar", "scale", 1.4)
	HudLayoutS.set_field("hotbar", "visible", false)
	HudLayoutS.restore_layout("hotbar", snap)
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), float(snap["scale"]), 0.001), "restore_layout reverts scale")
	ok(bool(HudLayoutS.layout("hotbar")["visible"]) == bool(snap["visible"]), "restore_layout reverts visibility")

	# --- profiles
	HudLayoutS.apply_profile("compact")
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), 0.8, 0.001), "compact profile applied")
	ok(HudLayoutS.profile() == "compact", "profile label")
	HudLayoutS.set_field("hotbar", "scale", 1.1)
	HudLayoutS.mark_custom()
	HudLayoutS.apply_profile("custom")
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), 1.1, 0.001), "custom never reseeds")
	ok("custom" in HudLayoutS.profile_names(), "profile_names includes custom")

	# --- clamping (module dragged off-screen comes back)
	HudLayoutS.set_position_from_rect("player_frame", Vector2(-500, 5000))
	HudLayoutS.clamp_module("player_frame")
	var r_cl: Rect2 = HudLayoutS.rect("player_frame")
	ok(r_cl.position.x >= 0.0 and r_cl.end.y <= vp.y + 0.5, "clamp_module pulls module on-screen got %s" % r_cl)
	HudLayoutS.set_position_from_rect("hotbar", Vector2(vp.x + 900, -300))
	HudLayoutS.fit_all_to_screen()
	var r_f: Rect2 = HudLayoutS.rect("hotbar")
	ok(r_f.position.y >= 0.0 and r_f.end.x <= vp.x + 0.5, "fit_all_to_screen")

	# --- global UI scale (window untouched in headless: pass null)
	ok(approx(HudLayoutS.set_ui_scale(9.0, null), HudLayoutS.UI_SCALE_MAX, 0.001), "ui_scale clamped high")
	ok(approx(HudLayoutS.load_ui_scale(), HudLayoutS.UI_SCALE_MAX, 0.001), "ui_scale round-trip")
	ok(approx(HudLayoutS.set_ui_scale(1.02, null), 1.0, 0.001), "ui_scale snapped to 0.05 steps")

	# --- erase_saved: hud wiped, audio kept
	HudLayoutS.erase_saved()
	var cfg3 := ConfigFile.new()
	cfg3.load(TEST_CFG)
	ok(not cfg3.has_section("hud_modules"), "erase_saved wipes hud_modules")
	ok(approx(float(cfg3.get_value("audio", "Master", -1.0)), 0.42, 0.001), "erase_saved keeps [audio]")
	ok(approx(float(HudLayoutS.layout("hotbar")["scale"]), 1.0, 0.001), "erase_saved resets live layouts")

	print("[hud_layout_test] %d checks, %d failures" % [checks, fails])
	if FileAccess.file_exists(TEST_CFG):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_CFG))
	quit(1 if fails > 0 else 0)
