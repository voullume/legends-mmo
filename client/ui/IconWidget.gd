class_name IconWidget
extends RefCounted
## Permanent Hybrid-Cutout UI icon system — the reusable screen-space icon factory. Rather than
## configuring a TextureRect by hand in every caller, everyone builds icons through here so the
## expand/stretch/filter/mouse-filter policy stays identical everywhere (docs/ui-icon-integration-
## handoff.pdf §5). All resource paths + default colors come from [[IconRegistry]] — no caller
## hardcodes an SVG path. Screen-space only; the 3D world uses WorldUI (Sprite3D can't take these).
##
## SVG masters import at 128px (svg/scale 2) with mipmaps, so downscaling to a 14px status chip is
## clean — LINEAR_WITH_MIPMAPS is the consistent filter for every SVG-derived texture here.

# a configured TextureRect for one semantic icon. opts (all optional):
#   px         → artwork square px (default = the id's size-class px)
#   color      → modulation (default = the id's registry default color)
#   tooltip    → hover text (icon-only INTERACTIVE controls always get one: falls back to the
#                accessible name so a texture-only control is never unlabelled — handoff §12)
#   interactive→ true makes it clickable (MOUSE_FILTER_STOP); default IGNORE (decorative)
static func make(id: String, opts := {}) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = IconRegistry.texture(id)
	var px := int(opts.get("px", IconRegistry.size_px(id)))
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE            # the 128px master never dictates layout size —
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED # and it must be set BEFORE size: with the default
	tr.custom_minimum_size = Vector2(px, px)                   # KEEP_SIZE the 128px min clamps size, and anchored
	tr.size = Vector2(px, px)                                  # badge callers (KEEP_SIZE presets) bake 128px offsets
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tr.modulate = opts.get("color", IconRegistry.color(id))
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var interactive := bool(opts.get("interactive", false))
	tr.mouse_filter = Control.MOUSE_FILTER_STOP if interactive else Control.MOUSE_FILTER_IGNORE
	var tip := str(opts.get("tooltip", ""))
	if tip == "" and interactive:
		tip = IconRegistry.fallback(id)
	if tip != "":
		tr.tooltip_text = tip
	return tr

# an icon Control that degrades to a plain-text fallback WORD when the texture is missing (never the
# old emoji — handoff §12). Production ids always have a texture (the registry test enforces it), so
# the Label path is a defensive net for a truly absent asset.
static func make_or_label(id: String, opts := {}) -> Control:
	if IconRegistry.texture(id) != null:
		return make(id, opts)
	var l := Label.new()
	l.text = IconRegistry.fallback(id)
	l.add_theme_color_override("font_color", opts.get("color", IconRegistry.color(id)))
	if opts.has("font_size"):
		l.add_theme_font_size_override("font_size", int(opts["font_size"]))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

# a structural icon+label row (HBox → TextureRect + Label) — the handoff's answer to embedding an
# image inside prose. Used by the currency tray, compact resource displays, inline state rows, and
# toast icon-siblings. Returns the HBox with `icon`/`label` metas for later text/color updates.
static func row(id: String, text: String, opts := {}) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(opts.get("sep", 5)))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic := make_or_label(id, opts)
	h.add_child(ic)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", opts.get("text_color", opts.get("color", IconRegistry.color(id))))
	if opts.has("font_size"):
		l.add_theme_font_size_override("font_size", int(opts["font_size"]))
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	h.set_meta("label", l)
	h.set_meta("icon", ic)
	return h

# an icon-capable button — native Button.icon (icon before text, auto hover/pressed/disabled
# modulation) capped to `px` so the 128px master renders at button scale. Keeps the caller's font
# colors; the icon rides the same fg unless `icon_color` overrides. Covers the migrated button call
# sites (Equip Best, Delete, lock/unlock, …) that used to embed an emoji in the label string.
static func icon_button(id: String, text: String, fg: Color, on_press: Callable, opts := {}) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.icon = IconRegistry.texture(id)
	b.expand_icon = false
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	b.add_theme_constant_override("icon_max_width", int(opts.get("px", 18)))
	var icol: Color = opts.get("icon_color", fg)
	b.add_theme_color_override("icon_normal_color", icol)
	b.add_theme_color_override("icon_hover_color", icol.lightened(0.2))
	b.add_theme_color_override("icon_pressed_color", icol)
	b.add_theme_color_override("icon_focus_color", icol)
	b.add_theme_color_override("icon_disabled_color", Color(icol, 0.4))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", fg.lightened(0.2))
	if bool(opts.get("disabled", false)):
		b.disabled = true
	elif on_press.is_valid():
		b.pressed.connect(on_press)
	return b
