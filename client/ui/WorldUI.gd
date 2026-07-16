class_name WorldUI
extends RefCounted
## UI-overhaul P3 — the 3D-world UI's shared language. Label3D + procedural meshes can't take the
## screen-space Theme, so the world layer reads its sizes + colors from here (reusing Palette where the
## two render worlds should agree). Gives the nameplates, pad labels and HP bars one visual language.
## Kept free of GameData (no class_name there) — callers pass already-resolved class colors.

# Label3D sizing (promoted from the magic numbers scattered through _spawn + the pad renderers).
# UI-consistency pass: sizes restrained (56/46/52 → 46/38/44) — fixed_size billboards render at
# constant screen size, so the old values shouted over every window and read as clutter.
const PLATE_FONT := 42
const PLATE_NAME := 34        # player character-name line (prominent, sits above the bar)
const PLATE_LEVEL := 20       # player level line — deliberately small, tucked under the name
const PLATE_PIXEL := 0.0016
const PLATE_OUTLINE := 13
const PAD_FONT := 38
const PAD_PIXEL := 0.0016
const PAD_OUTLINE := 13
const OUTLINE_COLOR := Color(0, 0, 0, 0.9)

# --- UI-consistency pass: world-label fade tokens (distances in 3D world units; Client.SCALE
#     maps sim→world, home base ≈ 48×27 units). Labels never fully vanish — wayfinding keeps a
#     floor — and everything drops to WINDOW_FADE while a large data window is open.
const PAD_FADE_NEAR := 12.0   # pads at full alpha inside this camera distance
const PAD_FADE_FAR := 35.0    # … down to PAD_FADE_MIN by here
const PAD_FADE_MIN := 0.22
const PLATE_FADE_NEAR := 12.0
const PLATE_FADE_FAR := 32.0
const PLATE_FADE_MIN := 0.35
const WINDOW_FADE := 0.12     # world text while a big window is open (readability behind windows)

static func pad_fade(dist: float) -> float:
	return remap(clampf(dist, PAD_FADE_NEAR, PAD_FADE_FAR), PAD_FADE_NEAR, PAD_FADE_FAR, 1.0, PAD_FADE_MIN)

static func plate_fade(dist: float) -> float:
	return remap(clampf(dist, PLATE_FADE_NEAR, PLATE_FADE_FAR), PLATE_FADE_NEAR, PLATE_FADE_FAR, 1.0, PLATE_FADE_MIN)

# THE service/portal pad label — one factory for the six clones (portals + quest giver, shop,
# build shop, vendor, forge) that each hand-rolled this shape with drifting magic numbers.
static func pad_label(text: String, tint: Color, pos: Vector3) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.pixel_size = PAD_PIXEL
	lbl.font_size = PAD_FONT
	lbl.outline_size = PAD_OUTLINE
	lbl.outline_modulate = OUTLINE_COLOR
	lbl.modulate = tint
	lbl.position = pos
	return lbl

# HP bar — a 3-stop ramp so "getting low" reads before it's critical (was a single 35% flip)
const HP_FULL := Color(0.3, 0.85, 0.4)
const HP_MID := Color(0.94, 0.78, 0.3)
const HP_LOW := Color(0.9, 0.3, 0.3)

# nameplate text semantics (aligned with Palette's screen colors)
const HOSTILE := Color(1.0, 0.45, 0.45)     # a plate that WILL hurt you — always red, never overridden
const MOB_LEVEL := Color(0.92, 0.82, 0.6)
const MOB_ELITE := Color(1.0, 0.55, 0.4)
const DUMMY := Color(0.72, 0.74, 0.8)
const CORE := Color(0.32, 0.86, 1.0)

static func hp_color(frac: float) -> Color:
	if frac < 0.3:
		return HP_LOW
	if frac < 0.6:
		return HP_MID
	return HP_FULL

# a friendly player's plate reads in their (brightened) class color — identity at a glance without
# touching the gameplay-critical hostile red. `class_col` is the resolved GameData class Color.
static func friendly_plate(class_col: Color) -> Color:
	return class_col.lightened(0.3)

# ============================================================ Part A — stable, themed player nameplate
# The player identity plate (name + LV N) used to be a fixed_size billboard: constant SCREEN pixels at
# any camera distance, so it dwarfed the character at far zoom and never felt anchored. This section is
# the world-proportional replacement — the text is a real world-space object (fixed_size = false) that
# scales with perspective, plus a GENTLE, clamped distance compensation so it stays legible at the zoom
# extremes without snapping back to constant-screen. All sizing/scale/clamp math lives HERE (pure +
# testable — tools/worldui_plate_test.gd); the client only reads these tokens and never rewrites font
# metrics per frame. Player plates only — mob/boss/core/dummy plates keep fixed_size (Part B).

# world-proportional identity text: world glyph height ≈ font_size * pixel_size (at scale 1.0)
const PLATE_P_PIXEL := 0.0072      # world units per font pixel (fixed_size = false)
const PLATE_P_NAME := 46           # character-name render size (px) — body font, world height ≈ 0.33u
const PLATE_P_LEVEL := 30          # "LV N" render size (px) — display face (caps-safe), ≈ 0.216u
const PLATE_P_OUTLINE := 9         # dark edge so world text survives bright field backgrounds

# perspective-compensation clamp: s = clamp((dist/REF)^K, MIN, MAX). K=0 → pure world-proportional
# (text vanishes when far); K=1 → constant screen size (the old defect). K in-between reads as "anchored
# to the head, breathes gently with zoom." REF = the default camera distance (Client._dist starts 26,
# range DIST_MIN 10 … DIST_MAX 55) → at default the plate renders at 1.0.
const PLATE_SCALE_REF := 26.0
const PLATE_SCALE_K := 0.4
const PLATE_SCALE_MIN := 0.70      # closest zoom: shrink so the plate never covers the head
const PLATE_SCALE_MAX := 1.45      # farthest zoom: grow so it never becomes illegibly small

# bounded long-name policy: names are arbitrary text (up to the server's cap), so clamp the DISPLAYED
# glyph count + ellipsis. Proportional glyphs mean this is an approximate width bound, not exact — it
# guarantees the plate can never grow indefinitely, the acceptance-criteria requirement.
const PLATE_NAME_MAX_CHARS := 14

# fixed plate LAYOUT (world-unit Y offsets inside the scaled plate group; HP bar centered at y=0). Every
# slot is reserved whether or not it is populated → adding/removing the name, wobble, or a status never
# reflows the others (the "static / never jumps" requirement). Widths in world units.
const PLATE_WOBBLE_Y := 0.34       # wobble pip strip — a compact meter just above the HP bar
const PLATE_LEVEL_Y := 0.62        # LV N line
const PLATE_NAME_Y := 0.99         # character-name line (above the level line)
const PLATE_STATUS_Y := 1.46       # overhead status chips — reserved slot above the identity block
const PLATE_BACK_Y := 0.805        # backing chip centered on the name+level identity block
const PLATE_BACK_W := 2.5          # designed backing bounds (NOT sized to text per frame)
const PLATE_BACK_H := 0.80

# wobble pip meter (4 pips = Sim.WOBBLE_MAX) — the stumble tell, moved OUT of the level-label string so
# it can appear/vanish without changing the identity block's height.
const PLATE_WOBBLE_PIPS := 4
const PLATE_PIP_W := 0.16
const PLATE_PIP_H := 0.09
const PLATE_PIP_GAP := 0.06
const PIP_LIT := Color(0.98, 0.78, 0.30)     # a charging wobble stack (amber)
const PIP_HOT := Color(1.0, 0.42, 0.22)      # near the stumble threshold (lit >= 3): hotter
const PIP_DIM := Color(0.16, 0.19, 0.24, 0.85)   # an unfilled pip (ink, faint)

# self overhead status renderer (SubViewport → billboarded Sprite3D). Kept smaller than the self HUD row.
const STATUS_CAP := 4              # visible chips before the "+n" overflow chip (intentionally < HUD's 5)
const STATUS_CHIP_PX := 26         # chip edge in the offscreen viewport (render res; crisper than the old 20)
const STATUS_VP := Vector2i(194, 40)   # offscreen viewport size (fits CAP chips + overflow + padding)
const STATUS_SPRITE_PIXEL := 0.0110    # world units per viewport pixel → sprite ≈ 2.1u wide, 0.44u tall

# restrained UTILITY-tier backing in 3D: near-opaque navy/ink body + a thin cyan structural rail (echoes
# HudFrame.Tier.UTILITY — chamfer-free here for cost, but the same ink+rail vocabulary). No glow.
const PLATE_BODY := Color(0.02, 0.05, 0.09, 0.82)    # navy/ink body (near Palette.SB_INK/SB_NAVY)
const PLATE_RAIL := Color(0.0, 0.9, 1.0, 0.5)        # thin cyan structural rail (near Palette.SB_CYAN)

# gentle, clamped perspective compensation for the identity text (see PLATE_SCALE_* above). Pure math.
static func plate_dist_scale(dist: float) -> float:
	return clampf(pow(maxf(dist, 0.001) / PLATE_SCALE_REF, PLATE_SCALE_K), PLATE_SCALE_MIN, PLATE_SCALE_MAX)

# bounded long-name policy: clamp arbitrary player names to a documented max glyph count + ellipsis so
# the plate can never grow without bound. Empty stays empty (mobs / unnamed).
static func clamp_name(nm: String) -> String:
	if nm.length() <= PLATE_NAME_MAX_CHARS:
		return nm
	return nm.substr(0, PLATE_NAME_MAX_CHARS - 1).strip_edges() + "…"

# how many wobble pips light up for a raw wobble value (0 … Sim.WOBBLE_MAX). Pure — pinned by the test.
static func wobble_lit(wob: float) -> int:
	return clampi(int(ceil(wob)), 0, PLATE_WOBBLE_PIPS)

# a billboarded backing chip (rail behind body), sized ONCE to designed bounds. Returns a Node3D holding
# two unshaded no-depth quads; faces the camera via the parent nameplate holder's per-frame look_at.
static func plate_backing() -> Node3D:
	var g := Node3D.new()
	var rail := _plate_quad(PLATE_BACK_W + 0.06, PLATE_BACK_H + 0.06, PLATE_RAIL, -2)
	rail.position.z = -0.02
	g.add_child(rail)
	var body := _plate_quad(PLATE_BACK_W, PLATE_BACK_H, PLATE_BODY, -1)
	body.position.z = -0.01
	g.add_child(body)
	return g

# fade the backing chip with the rest of the plate — SET each quad's alpha from its constant base (rail /
# body) times k, so the distance + open-window fade never compounds (structure = [rail, body], see above).
static func fade_backing(g: Node3D, k: float) -> void:
	if g == null:
		return
	var kids := g.get_children()
	if kids.size() >= 2:
		((kids[0] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = PLATE_RAIL.a * k
		((kids[1] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color.a = PLATE_BODY.a * k

static func _plate_quad(w: float, h: float, col: Color, priority: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	mi.mesh = qm
	var mt := StandardMaterial3D.new()
	mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mt.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mt.albedo_color = col
	mt.no_depth_test = true                 # float above the field like the labels (no head-mesh clipping)
	mt.render_priority = priority           # draw behind the identity text (labels ride priority 1)
	# billboard upright (like the Label3Ds) so the chip never tilts/rolls when the character is off-axis;
	# keep_scale so the plate group's distance scale still sizes it.
	mt.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mt.billboard_keep_scale = true
	mi.material_override = mt
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# the character-NAME line: body font (names are arbitrary text; the display face is caps-only + would
# silently drop lowercase/symbols). World-proportional billboard, no depth test.
static func plate_name_label() -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.pixel_size = PLATE_P_PIXEL
	l.font_size = PLATE_P_NAME
	l.outline_size = PLATE_P_OUTLINE
	l.outline_modulate = OUTLINE_COLOR
	l.render_priority = 1
	l.outline_render_priority = 0
	return l

# the LV N line: display face (Sportbound Strike, caps-only) is SAFE here — "LV N" is uppercase + digits.
# Falls back to the body font if the display TTF is unavailable (HudFonts.display_variant → null).
static func plate_level_label() -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.pixel_size = PLATE_P_PIXEL
	l.font_size = PLATE_P_LEVEL
	var df := HudFonts.display_variant(PLATE_P_LEVEL, 0.14)
	if df != null:
		l.font = df
	l.outline_size = PLATE_P_OUTLINE
	l.outline_modulate = OUTLINE_COLOR
	l.render_priority = 1
	l.outline_render_priority = 0
	return l

# ============================================================ Part B — combat floater + boss-plate tokens
# The damage/heal/shield/burn floaters baked SIZE + OUTLINE + SEMANTIC COLORS as magic numbers inline in
# Client._spawn_num; the boss scoreboard typed its phase/ult/shield colors inline. Those visual tokens now
# live here (one language with the plates). Values are byte-identical to the originals → NO visual change;
# this only names them. The floaters' MOTION timing (rise speed / lifetime) stays in _spawn_num — it is
# combat-feel, not theme. Moving combat text stays UNBACKED by design (the plate rule's stated exception).
const FLOAT_PIXEL := 0.0011           # fixed_size floater scale (constant screen size — a readable pop)
const FLOAT_FONT := 96
const FLOAT_OUTLINE := 22             # (outline color reuses OUTLINE_COLOR above — was a retyped literal)
const FLOAT_DMG := Color(1.0, 1.0, 0.95)         # damage I deal — near-white
const FLOAT_CRIT := Color(1.0, 0.85, 0.35)       # a crit I deal — jumbotron-gold family (kept exact for feel)
const FLOAT_DMG_TAKEN := Color(1.0, 0.36, 0.3)   # damage I take — a hotter impact red than Palette.DANGER
const FLOAT_BYSTANDER := Color(0.78, 0.8, 0.86)  # a hit that isn't mine — muted grey (de-emphasized)
const FLOAT_HEAL := Palette.HEAL                 # +heal — reuse the existing green token (was retyped inline)
const FLOAT_SHIELD := Palette.SHIELD             # +absorb — reuse the existing blue token (was retyped inline)
const FLOAT_BURN := Color(1.0, 0.74, 0.38)       # DoT tick I deal / bystander — soft ember (SB_ORANGE family)
const FLOAT_BURN_TAKEN := Color(1.0, 0.55, 0.25) # DoT tick I take — hotter ember

# boss scoreboard colors (were inline literals in the boss branch of _update_mob_plate) — same values
const BOSS_ULT := Color(1.0, 0.2, 0.2)           # ult-warning plate — urgent red (hotter than a normal plate)
const BOSS_SHIELDED := Color(0.4, 0.82, 1.0)     # core-shielded cue — cyan ("destroy the cores" read)
const BOSS_PHASE := [Color(1.0, 0.6, 0.42), Color(1.0, 0.48, 0.32),   # per-phase orange→red intensity ramp
	Color(1.0, 0.34, 0.26), Color(1.0, 0.22, 0.22)]
