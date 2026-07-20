extends SceneTree
## Full-color ability-art test (too_add_models/ABILITY_ICON_IMPLEMENTATION_HANDOFF.md §9).
## Section A sweeps the AbilityIcons registry against the LIVE GameData kits: the eight playable
## classes each expose exactly eight abilities, the registry holds exactly those 64 class/key ids
## (no missing, no stale extras), every preload is a real 256×256 square Texture2D, the two
## class-scoped Tackle sources are byte-identical on disk, every import keeps mipmaps on, and an
## unknown id degrades to null instead of crashing.
## The §9.2 hotbar-construction assertions live in tools/hotbar_icons_test.gd — run as a SCENE
## (not --script), because Client.gd references the AudioManager autoload and script mode has no
## autoloads (pre-existing; nothing to do with the art change). Headless-safe; exits non-zero on
## any failure.
##   ~/.local/bin/godot --headless --path . --script res://tools/ability_icons_test.gd

const GameData := preload("res://shared/GameData.gd")
const AbilityIconsS := preload("res://client/ui/AbilityIcons.gd")

# §9.1: player hotbars exist only for these eight — mob/boss classes never render one
const PLAYABLE := ["pitcher", "batter", "quarterback", "linebacker", "setter", "spiker", "striker", "goalkeeper"]

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)

func _init() -> void:
	print("[ability_icons_test] running")

	# ---- A1. the hardcoded playable list still matches live GameData ----
	var live: Array = GameData.playable_ids()
	live.sort()
	var expected_cls := PLAYABLE.duplicate()
	expected_cls.sort()
	ok(live == expected_cls, "playable classes match GameData.playable_ids() (got %s)" % [live])

	# ---- A2. eight abilities per class; expected id set built from live data ----
	var expected_ids := []
	for cls in PLAYABLE:
		var abs_: Array = GameData.CLASSES[cls]["abilities"]
		ok(abs_.size() == 8, "%s has exactly 8 abilities (got %d)" % [cls, abs_.size()])
		for ab in abs_:
			expected_ids.append(AbilityIconsS.id_for(cls, str(ab["key"])))

	# ---- A3. registry == expected, both directions ----
	var reg_ids: Array = AbilityIconsS.ids()
	ok(reg_ids.size() == 64, "registry holds exactly 64 ids (got %d)" % reg_ids.size())
	for id in expected_ids:
		ok(id in reg_ids, "registry has '%s'" % id)
	for id in reg_ids:
		ok(id in expected_ids, "registry id '%s' is a live playable class/key (no stale extras)" % id)

	# ---- A4. every texture is a real, square, 256×256 Texture2D ----
	for cls in PLAYABLE:
		for ab in GameData.CLASSES[cls]["abilities"]:
			var tex := AbilityIconsS.texture(cls, str(ab["key"]))
			ok(tex != null and tex is Texture2D, "%s/%s preloads a Texture2D" % [cls, ab["key"]])
			if tex != null:
				ok(tex.get_width() == 256 and tex.get_height() == 256,
					"%s/%s is 256×256 (got %d×%d)" % [cls, ab["key"], tex.get_width(), tex.get_height()])

	# ---- A5. filesystem: the two Tackle sources are byte-identical; imports keep mipmaps on ----
	var tq := FileAccess.get_file_as_bytes("res://client/ui/ability_icons/quarterback/tackle.png")
	var tl := FileAccess.get_file_as_bytes("res://client/ui/ability_icons/linebacker/tackle.png")
	ok(tq.size() > 0 and tq == tl, "quarterback/tackle.png and linebacker/tackle.png are byte-identical")
	for cls in PLAYABLE:
		for ab in GameData.CLASSES[cls]["abilities"]:
			var imp := FileAccess.get_file_as_string("res://client/ui/ability_icons/%s/%s.png.import" % [cls, ab["key"]])
			ok(imp.contains("mipmaps/generate=true"), "%s/%s import has mipmaps on" % [cls, ab["key"]])

	# ---- A6. unknown ids degrade gracefully ----
	ok(AbilityIconsS.texture("head_coach", "campreset") == null, "mob class/key → null (no crash)")
	ok(AbilityIconsS.texture("pitcher", "does_not_exist") == null, "unknown key → null (no crash)")
	ok(AbilityIconsS.id_for("pitcher", "fastball") == "pitcher/fastball", "id_for joins class/key")

	print("[ability_icons_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
