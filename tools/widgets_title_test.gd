extends SceneTree
## Part B (text-theme sweep) — pins Widgets.panel()'s window-title font policy so it can't silently
## regress to the pre-sweep bug (the caps-only display face applied UNCONDITIONALLY, forcing it onto
## emoji / em-dash / ◈ glyphs it lacks). panel() must now mirror Widgets.section():
##   • a DISPLAY-SAFE title (caps + limited punctuation) → the display face, uppercased (branded);
##   • a NON-safe title (emoji / em-dash / ·) → NO display-font override (falls back to the body font).
## Also re-affirms display_safe()'s coverage set. Headless-safe; exits non-zero on any failure.
## ~/.local/bin/godot --headless --path . --script res://tools/widgets_title_test.gd

const WidgetsS := preload("res://client/ui/Widgets.gd")
const HudFontsS := preload("res://client/ui/HudFonts.gd")

var fails := 0
var checks := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
		print("  FAIL: %s" % what)
	else:
		print("  ok: %s" % what)

# the display face a display-safe title should carry (null if the prototype TTF is absent — then the
# test only asserts that non-safe titles never carry a DIFFERENT display override than safe ones).
func _display_font():
	return HudFontsS.display_variant(15, 0.06)   # Palette.SIZE_TITLE is 22; only presence matters here

func _title_label(p: Dictionary) -> Label:
	return p["title"] as Label

func _init() -> void:
	print("[widgets_title_test] running")
	var disp_available := HudFontsS.display() != null

	# --- display_safe coverage (the contract panel()/section() both gate on) ---
	ok(WidgetsS.display_safe("FORGE"), "plain caps title is display-safe")
	ok(WidgetsS.display_safe("Practice Vendor - Rookie Camp Set"), "hyphen + spaces stay display-safe")
	ok(not WidgetsS.display_safe("📜 Quest Giver"), "emoji title is NOT display-safe")
	ok(not WidgetsS.display_safe("Practice Vendor — Rookie Camp Set"), "em-dash title is NOT display-safe")
	ok(not WidgetsS.display_safe("◈ Practice Vendor"), "◈ title is NOT display-safe")
	ok(not WidgetsS.display_safe("Q1 · Evaluation"), "middle-dot title is NOT display-safe")

	# --- panel() applies the display face to a SAFE title (uppercased) ---
	var safe := WidgetsS.panel("Forge", "X", 560.0, null, false)
	var st := _title_label(safe)
	ok(st.text == "FORGE", "safe title is uppercased for the display face (got '%s')" % st.text)
	if disp_available:
		ok(st.has_theme_font_override("font"), "safe title carries the display-font override")
	(safe["root"] as Node).queue_free()

	# --- panel() does NOT force the display face onto a NON-safe (emoji) title ---
	var unsafe := WidgetsS.panel("📜 Quest Giver", "X", 560.0, null, false)
	var ut := _title_label(unsafe)
	ok(ut.text == "📜 Quest Giver", "non-safe title keeps its exact text (no uppercasing): '%s'" % ut.text)
	ok(not ut.has_theme_font_override("font"), "non-safe title does NOT carry the display-font override (body fallback)")
	(unsafe["root"] as Node).queue_free()

	# --- an em-dash title also falls back (the common 'Name — Subtitle' window form) ---
	var emdash := WidgetsS.panel("Vendor — Rookie Set", "X", 560.0, null, false)
	var et := _title_label(emdash)
	ok(not et.has_theme_font_override("font"), "em-dash title does NOT carry the display-font override")
	(emdash["root"] as Node).queue_free()

	print("[widgets_title_test] %d checks, %d failures" % [checks, fails])
	quit(1 if fails > 0 else 0)
