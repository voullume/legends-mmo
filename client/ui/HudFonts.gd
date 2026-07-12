class_name HudFonts
extends RefCounted
## HUD pattern P1 — font roles. DISPLAY = the Sportbound Strike prototype (caps-only starter
## face, see client/ui/fonts/FONTS-README.md for the hard usage rules + licensing status):
## short uppercase headings, zone titles, event banners, timers, mode badges ONLY. BODY = the
## engine default (Open Sans SemiBold) — chat, tooltips, names, descriptions never use the
## display face. display() degrades to null (theme font) if the TTF is missing, so nothing
## hard-depends on the prototype file.

const DISPLAY_PATH := "res://client/ui/fonts/SportboundStrike-Regular.ttf"

static var _display: Font = null
static var _tried := false
static var _variants := {}   # "size|tracking" -> FontVariation (letter-spaced display face)

static func display() -> Font:
	if not _tried:
		_tried = true
		if ResourceLoader.exists(DISPLAY_PATH):
			_display = load(DISPLAY_PATH)
	return _display

# The display face with em-tracking baked in (spec: headings .06–.10em, subheads .14–.18em,
# micro labels .18–.25em). Returns null when the prototype font is unavailable.
static func display_variant(size: int, tracking_em: float) -> Font:
	var base := display()
	if base == null:
		return null
	var key := "%d|%.2f" % [size, tracking_em]
	if not _variants.has(key):
		var fv := FontVariation.new()
		fv.base_font = base
		fv.set_spacing(TextServer.SPACING_GLYPH, int(round(float(size) * tracking_em)))
		_variants[key] = fv
	return _variants[key]

# Shrink a display size until `text` fits max_width (content-safe-area rule: display text must
# never cross the frame decorations; long titles scale down instead of overflowing).
static func fit_size(text: String, size: int, tracking_em: float, max_width: float) -> int:
	var s := size
	while s > 9:
		var f := display_variant(s, tracking_em)
		var fnt: Font = f if f != null else ThemeDB.fallback_font
		if fnt.get_string_size(text.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, s).x <= max_width:
			break
		s -= 1
	return s

# A display-typography Label: uppercase, tracked, optional glow (outline) in the accent color.
# Glow is theme-level (never rasterized into art) and restrained under reduced FX.
# max_width > 0 auto-shrinks the font so the line stays inside the caller's safe area.
static func display_label(text: String, size: int, color: Color = Palette.TEXT_BRIGHT,
		tracking_em: float = 0.08, glow: Color = Color(0, 0, 0, 0), max_width: float = 0.0) -> Label:
	if max_width > 0.0:
		size = fit_size(text, size, tracking_em, max_width)
	var l := Label.new()
	l.text = text.to_upper()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var f := display_variant(size, tracking_em)
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if glow.a > 0.0:
		l.add_theme_constant_override("outline_size", int(maxf(2.0, float(size) * (0.10 if HudFrame.reduced else 0.16))))
		l.add_theme_color_override("font_outline_color", Color(glow, 0.35))
	else:
		# always keep a thin dark edge so display text survives bright world backgrounds
		l.add_theme_constant_override("outline_size", maxi(2, size / 8))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	return l
