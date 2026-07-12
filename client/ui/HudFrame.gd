class_name HudFrame
extends Control
## HUD pattern P1 — the reusable sports-tech frame chrome, drawn procedurally so any module size
## stays crisp (no nine-patch stretch artifacts, no baked-checkerboard PNGs). Geometry is ported
## from the match-found frame-only SVG (docs/ideas-not-in/hud ui/, 960×260 reference): chamfered
## body, cyan rails, corner brackets, lime elbows, tech tabs, tick bars, side dots, speed lines.
## Three density tiers (DESIGN LANGUAGE): HERO for rare event banners, PANEL for always-on HUD
## modules, UTILITY for tooltips/prompts/settings rows. The frame is DECORATIVE ONLY: it never
## takes mouse input and never carries live text — callers layer real Controls in the content
## rect published by margins()/attach_body().

enum Tier { HERO, PANEL, UTILITY }

const REF := Vector2(960.0, 260.0)          # hero reference composition (SVG viewBox)
const MIN_HERO := Vector2(360.0, 120.0)     # from match-found-tokens.json recommended_min_size
const MIN_PANEL := Vector2(96.0, 40.0)
const MIN_UTILITY := Vector2(40.0, 24.0)

# reduce_fx mirror — set once by the client at HUD build; gates the soft glow passes and any
# future pulse animation (color/geometry always stays).
static var reduced := false

var tier: int = Tier.PANEL
var accent: Color = Palette.SB_CYAN         # primary rail
var accent2: Color = Palette.SB_LIME        # ready/success elbows
var accent3: Color = Palette.SB_ORANGE      # warning/action speed lines
var body_alpha := 0.88
var hex := true                             # low-opacity hex texture (HERO only)
var header := false                         # PANEL: bright header-tab segment on the top rail
var stripe := false                         # UTILITY: 2px semantic accent stripe on the left
var _body: MarginContainer = null

func _init(p_tier: int = Tier.PANEL) -> void:
	tier = p_tier
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)

static func make(p_tier: int, opts: Dictionary = {}) -> HudFrame:
	var f := HudFrame.new(p_tier)
	if opts.has("accent"): f.accent = opts["accent"]
	if opts.has("accent2"): f.accent2 = opts["accent2"]
	if opts.has("accent3"): f.accent3 = opts["accent3"]
	if opts.has("body_alpha"): f.body_alpha = opts["body_alpha"]
	if opts.has("hex"): f.hex = opts["hex"]
	if opts.has("header"): f.header = opts["header"]
	if opts.has("stripe"): f.stripe = opts["stripe"]
	return f

# Frame + managed content MarginContainer in one call: {frame, body}. Add children to `body`;
# the safe-area margins track the frame's size (CONTENT-SAFE AREAS contract).
static func boxed(p_tier: int, opts: Dictionary = {}) -> Dictionary:
	var f := make(p_tier, opts)
	return {"frame": f, "body": f.attach_body()}

func attach_body() -> MarginContainer:
	if _body == null:
		_body = MarginContainer.new()
		_body.set_anchors_preset(Control.PRESET_FULL_RECT)
		_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_body)
		_apply_margins()
	return _body

# Published content-safe margins: live content must never overlap brackets/elbows/tabs/ticks.
func margins() -> Dictionary:
	match tier:
		Tier.HERO:
			return {"l": clampf(size.x * 0.125, 42.0, 120.0), "r": clampf(size.x * 0.125, 42.0, 120.0),
				"t": clampf(size.y * 0.21, 22.0, 55.0), "b": clampf(size.y * 0.21, 22.0, 55.0)}
		Tier.PANEL:
			return {"l": 14.0, "r": 14.0, "t": 18.0 if header else 12.0, "b": 12.0}
		_:
			return {"l": 10.0 if stripe else 8.0, "r": 8.0, "t": 6.0, "b": 6.0}

func content_rect() -> Rect2:
	var mg := margins()
	return Rect2(Vector2(mg["l"], mg["t"]), size - Vector2(mg["l"] + mg["r"], mg["t"] + mg["b"]))

func _on_resized() -> void:
	_apply_margins()
	queue_redraw()

func _apply_margins() -> void:
	if _body == null:
		return
	var mg := margins()
	_body.add_theme_constant_override("margin_left", int(mg["l"]))
	_body.add_theme_constant_override("margin_right", int(mg["r"]))
	_body.add_theme_constant_override("margin_top", int(mg["t"]))
	_body.add_theme_constant_override("margin_bottom", int(mg["b"]))

func _draw() -> void:
	if size.x < 8.0 or size.y < 8.0:
		return          # pre-layout / degenerate: chamfer points would self-intersect
	match tier:
		Tier.HERO: _draw_hero()
		Tier.PANEL: _draw_panel()
		_: _draw_utility()

# ---------------------------------------------------------------- shared helpers

# Chamfered rect outline; per-corner chamfer [tl, tr, br, bl].
func _chamfer_rect(r: Rect2, ch: Array) -> PackedVector2Array:
	var p := PackedVector2Array()
	p.append(Vector2(r.position.x + float(ch[0]), r.position.y))
	p.append(Vector2(r.end.x - float(ch[1]), r.position.y))
	p.append(Vector2(r.end.x, r.position.y + float(ch[1])))
	p.append(Vector2(r.end.x, r.end.y - float(ch[2])))
	p.append(Vector2(r.end.x - float(ch[2]), r.end.y))
	p.append(Vector2(r.position.x + float(ch[3]), r.end.y))
	p.append(Vector2(r.position.x, r.end.y - float(ch[3])))
	p.append(Vector2(r.position.x, r.position.y + float(ch[0])))
	return p

func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var q := p.duplicate()
	if q.size() > 0:
		q.append(q[0])
	return q

# Vertical navy→ink gradient fill via per-vertex polygon colors.
func _fill_gradient(pts: PackedVector2Array, top_c: Color, bot_c: Color) -> void:
	var y0 := 1e9
	var y1 := -1e9
	for p in pts:
		y0 = minf(y0, p.y)
		y1 = maxf(y1, p.y)
	var cols := PackedColorArray()
	for p in pts:
		cols.append(top_c.lerp(bot_c, clampf((p.y - y0) / maxf(1.0, y1 - y0), 0.0, 1.0)))
	draw_polygon(pts, cols)

# Rail stroke with optional soft glow passes (skipped under reduced FX).
func _rail(pts: PackedVector2Array, col: Color, width: float, glow: bool) -> void:
	var cp := _closed(pts)
	if glow and not reduced:
		draw_polyline(cp, Color(col, 0.10), width * 3.0, true)
		draw_polyline(cp, Color(col, 0.16), width * 1.8, true)
	draw_polyline(cp, Color(col, 0.88), width, true)

# Transform reference-corner-local points (SVG px, TL-based) to a corner of this rect.
# corner: 0=TL 1=TR 2=BL 3=BR. k scales the reference distances.
func _corner_pts(ref_pts: Array, corner: int, k: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for rp in ref_pts:
		var v: Vector2 = rp * k
		out.append(Vector2(size.x - v.x if corner & 1 else v.x, size.y - v.y if corner & 2 else v.y))
	return out

# ---------------------------------------------------------------- HERO

# The 960×260 match-found composition: corner features scale with k and stay corner-anchored,
# center tabs/ticks stay centered, edges stretch — so no element distorts at any panel size.
func _draw_hero() -> void:
	var w := size.x
	var h := size.y
	var k := clampf(minf(w / 720.0, h / 260.0), 0.35, 1.0)   # feature scale vs reference
	var m := 22.0 * k                                       # outer margin (brackets live here)
	var c := 48.0 * k                                       # body corner chamfer
	var raise := 14.0 * k                                   # center strip lift
	var cx := w * 0.5
	var step := 23.0 * k
	var strip := minf(182.0 * k, (w - 2.0 * m - 2.0 * c - 2.0 * step - 60.0 * k) * 0.5)
	if strip < 24.0 * k:
		strip = 0.0                                         # too narrow: plain chamfer silhouette

	var body := _hero_outline(Rect2(m, m, w - 2.0 * m, h - 2.0 * m), c, raise, strip, step, cx)
	_fill_gradient(body, Color(Palette.SB_NAVY.lightened(0.05), body_alpha),
		Color(Palette.SB_INK, body_alpha * 0.97))

	if hex:
		_draw_hex_field(Rect2(m + 8.0, m + 8.0, w - 2.0 * m - 16.0, h - 2.0 * m - 16.0), k)

	# outer cyan rail (glowing) + inner thin rail
	_rail(body, accent, 3.0 * k, true)
	var inset := 24.0 * k
	if h - 2.0 * m - 2.0 * inset > 20.0:
		var inner := _hero_outline(Rect2(m + inset, m + inset, w - 2.0 * (m + inset), h - 2.0 * (m + inset)),
			maxf(4.0, c - inset * 0.6), raise * 0.85, maxf(0.0, strip - 20.0 * k), step, cx)
		draw_polyline(_closed(inner), Color(accent, 0.35), maxf(1.0, 1.4 * k), true)

	# neon lime corner elbows (glow) — ready/success accent
	for corner in 4:
		var el := _corner_pts([Vector2(145, 47), Vector2(78, 47), Vector2(47, 78)], corner, k)
		if not reduced:
			draw_polyline(el, Color(accent2, 0.16), 12.0 * k, true)
		draw_polyline(el, Color(accent2, 0.92), 6.0 * k, true)

	# cyan corner brackets (outside the body)
	for corner in 4:
		var br := _corner_pts([Vector2(73, 24), Vector2(32, 65), Vector2(32, 111)], corner, k)
		draw_polyline(br, Color(accent, 0.85), 5.0 * k, true)

	# top/bottom center tech tabs
	if strip > 0.0:
		for bottom in 2:
			var y0 := (h - m + 2.0 * k) if bottom == 1 else (m - 2.0 * k)
			var y1 := (h - m - 18.0 * k) if bottom == 1 else (m + 18.0 * k)
			var tab := PackedVector2Array([Vector2(cx - 106.0 * k, y0), Vector2(cx + 106.0 * k, y0),
				Vector2(cx + 128.0 * k, y1), Vector2(cx - 128.0 * k, y1)])
			draw_colored_polygon(tab, Color(0.027, 0.07, 0.114, 0.95))
			draw_polyline(_closed(tab), Color(accent, 0.6), maxf(1.0, 1.5 * k), true)
		# cyan tick bars inside both tabs
		for bottom in 2:
			var ty := (h - m - 12.0 * k) if bottom == 1 else (m + 6.0 * k)
			for i in 4:
				draw_rect(Rect2(cx + (-50.0 + 26.0 * i) * k, ty, 18.0 * k, 6.0 * k), Color(accent, 0.9))

	# side shoulder tabs (wide frames only)
	if w - 2.0 * m - 2.0 * c > 620.0 * k:
		for corner in 4:
			var st := _corner_pts([Vector2(118, 34), Vector2(235, 34), Vector2(252, 48), Vector2(98, 48)], corner, k)
			draw_colored_polygon(st, Color(0.027, 0.07, 0.114, 0.95))
			draw_polyline(_closed(st), Color(accent, 0.5), maxf(1.0, 1.2 * k), true)

	# side indicator dots
	for corner in 2:
		for i in 3:
			var dp := _corner_pts([Vector2(84, 86 + 18 * i)], corner, k)
			draw_circle(dp[0], 3.0 * k, Color(accent, 0.9))

	# orange speed accents (asymmetric)
	draw_line(_corner_pts([Vector2(258, 61)], 0, k)[0], _corner_pts([Vector2(201, 61)], 0, k)[0],
		Color(accent3, 0.8), 3.0 * k, true)
	draw_line(_corner_pts([Vector2(258, 61)], 3, k)[0], _corner_pts([Vector2(200, 61)], 3, k)[0],
		Color(accent3, 0.8), 3.0 * k, true)
	draw_line(_corner_pts([Vector2(240, 52)], 3, k)[0], _corner_pts([Vector2(172, 52)], 3, k)[0],
		Color(accent3, 0.65), 3.0 * k, true)

func _hero_outline(r: Rect2, c: float, raise: float, strip: float, step: float, cx: float) -> PackedVector2Array:
	var t := r.position.y
	var b := r.end.y
	var l := r.position.x
	var rt := r.end.x
	var p := PackedVector2Array()
	p.append(Vector2(l + c, t))
	if strip > 0.0:
		p.append(Vector2(cx - strip - step, t))
		p.append(Vector2(cx - strip, t - raise))
		p.append(Vector2(cx + strip, t - raise))
		p.append(Vector2(cx + strip + step, t))
	p.append(Vector2(rt - c, t))
	p.append(Vector2(rt, t + c))
	p.append(Vector2(rt, b - c))
	p.append(Vector2(rt - c, b))
	if strip > 0.0:
		p.append(Vector2(cx + strip + step, b))
		p.append(Vector2(cx + strip, b + raise))
		p.append(Vector2(cx - strip, b + raise))
		p.append(Vector2(cx - strip - step, b))
	p.append(Vector2(l + c, b))
	p.append(Vector2(l, b - c))
	p.append(Vector2(l, t + c))
	return p

# Low-opacity hex texture (one draw_multiline call; redrawn only on resize).
func _draw_hex_field(r: Rect2, k: float) -> void:
	var tw := 28.0 * maxf(k, 0.6)
	var th := 24.0 * maxf(k, 0.6)
	var seg := PackedVector2Array()
	var hexp := [Vector2(0.25, 0.04), Vector2(0.75, 0.04), Vector2(1.0, 0.5),
		Vector2(0.75, 0.96), Vector2(0.25, 0.96), Vector2(0.0, 0.5)]
	var y := r.position.y
	while y + th <= r.end.y:
		var x := r.position.x
		while x + tw <= r.end.x:
			for i in 6:
				var a: Vector2 = hexp[i]
				var bb: Vector2 = hexp[(i + 1) % 6]
				seg.append(Vector2(x + a.x * tw, y + a.y * th))
				seg.append(Vector2(x + bb.x * tw, y + bb.y * th))
			x += tw
		y += th
	if seg.size() >= 2:
		draw_multiline(seg, Color(accent, 0.08), 1.0)

# ---------------------------------------------------------------- PANEL (standard HUD tier)

func _draw_panel() -> void:
	var w := size.x
	var h := size.y
	var c := clampf(minf(w, h) * 0.18, 6.0, 16.0)
	var r := Rect2(1.5, 1.5, w - 3.0, h - 3.0)
	var body := _chamfer_rect(r, [c, c * 0.45, c, c * 0.45])   # asymmetric athletic chamfer
	_fill_gradient(body, Color(Palette.SB_NAVY.lightened(0.03), body_alpha),
		Color(Palette.SB_INK, body_alpha))
	# main rail + faint inner line
	_rail(body, accent, 2.0, true)
	var ir := Rect2(r.position + Vector2(5, 5), r.size - Vector2(10, 10))
	if ir.size.x > 16.0 and ir.size.y > 16.0:
		draw_polyline(_closed(_chamfer_rect(ir, [c * 0.6, c * 0.3, c * 0.6, c * 0.3])),
			Color(accent, 0.18), 1.0, true)
	# header tab: bright segment along the top-left rail with a drop tick
	if header:
		var hx0 := r.position.x + c
		var hx1 := hx0 + minf(w * 0.34, 132.0)
		draw_line(Vector2(hx0, r.position.y), Vector2(hx1, r.position.y), Color(accent, 1.0), 3.0, true)
		draw_line(Vector2(hx1, r.position.y), Vector2(hx1 + 7.0, r.position.y + 7.0), Color(accent, 1.0), 3.0, true)
	# lime status ticks top-right; orange notch bottom-right (small indicator language)
	var tx := r.end.x - c * 0.45 - 10.0
	for i in 3:
		draw_rect(Rect2(tx - 10.0 * i, r.position.y + 4.0, 6.0, 2.5), Color(accent2, 0.85 - 0.22 * i))
	draw_line(Vector2(r.end.x - c - 12.0, r.end.y), Vector2(r.end.x - c - 4.0, r.end.y),
		Color(accent3, 0.7), 2.5, true)

# ---------------------------------------------------------------- UTILITY

func _draw_utility() -> void:
	var r := Rect2(0.5, 0.5, size.x - 1.0, size.y - 1.0)
	var body := _chamfer_rect(r, [5.0, 5.0, 5.0, 5.0])
	draw_colored_polygon(body, Color(Palette.SB_INK, 0.93))
	draw_polyline(_closed(body), Color(Palette.BORDER_BRIGHT, 0.7), 1.0, true)
	if stripe:
		draw_rect(Rect2(r.position.x + 1.0, r.position.y + 5.0, 2.0, r.size.y - 10.0), Color(accent, 0.9))
