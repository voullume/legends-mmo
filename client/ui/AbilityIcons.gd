class_name AbilityIcons
extends RefCounted
## Full-color ability-art registry — the painterly hotbar illustrations (too_add_models/
## ABILITY_ICON_IMPLEMENTATION_HANDOFF.md). A deliberate COMPANION to, not part of, [[IconRegistry]]:
## that registry owns neutral Hybrid-Cutout SVGs that get MODULATED to semantic colors; these are
## opaque authored paintings that must render with their full authored palette (Color.WHITE, never
## tinted — there is intentionally no tint/color API here). Identity is the class/key PAIR, not the
## bare key: `tackle` exists for both Quarterback and Linebacker (owner-directed shared artwork,
## kept as two class-scoped files so future art may diverge only with owner approval), and
## Goalkeeper's displayed "Punching Save" lives under its GameData key `header`.
##
## All 64 playable class/key pairs are PRELOADED explicitly, so a wrong/missing path fails at
## parse/import time — never randomly mid-combat. Unknown ids return null and warn; the hotbar
## then falls back to the readable ability-name label.

const ICONS := {
	# ---- pitcher (batch 001) ----
	"pitcher/fastball": preload("res://client/ui/ability_icons/pitcher/fastball.png"),
	"pitcher/curveball": preload("res://client/ui/ability_icons/pitcher/curveball.png"),
	"pitcher/pickoff": preload("res://client/ui/ability_icons/pitcher/pickoff.png"),
	"pitcher/strikezone": preload("res://client/ui/ability_icons/pitcher/strikezone.png"),
	"pitcher/changeup": preload("res://client/ui/ability_icons/pitcher/changeup.png"),
	"pitcher/beanball": preload("res://client/ui/ability_icons/pitcher/beanball.png"),
	"pitcher/moundpresence": preload("res://client/ui/ability_icons/pitcher/moundpresence.png"),
	"pitcher/perfectgame": preload("res://client/ui/ability_icons/pitcher/perfectgame.png"),

	# ---- batter (batch 002) ----
	"batter/swing": preload("res://client/ui/ability_icons/batter/swing.png"),
	"batter/powerswing": preload("res://client/ui/ability_icons/batter/powerswing.png"),
	"batter/slide": preload("res://client/ui/ability_icons/batter/slide.png"),
	"batter/checkswing": preload("res://client/ui/ability_icons/batter/checkswing.png"),
	"batter/batflip": preload("res://client/ui/ability_icons/batter/batflip.png"),
	"batter/stolenbase": preload("res://client/ui/ability_icons/batter/stolenbase.png"),
	"batter/walkoff": preload("res://client/ui/ability_icons/batter/walkoff.png"),
	"batter/grandslam": preload("res://client/ui/ability_icons/batter/grandslam.png"),

	# ---- quarterback (batch 003) ----
	"quarterback/shouldercheck": preload("res://client/ui/ability_icons/quarterback/shouldercheck.png"),
	"quarterback/huddle": preload("res://client/ui/ability_icons/quarterback/huddle.png"),
	"quarterback/scramble": preload("res://client/ui/ability_icons/quarterback/scramble.png"),
	"quarterback/blitz": preload("res://client/ui/ability_icons/quarterback/blitz.png"),
	"quarterback/tackle": preload("res://client/ui/ability_icons/quarterback/tackle.png"),
	"quarterback/sack": preload("res://client/ui/ability_icons/quarterback/sack.png"),
	"quarterback/playaction": preload("res://client/ui/ability_icons/quarterback/playaction.png"),
	"quarterback/hailmary": preload("res://client/ui/ability_icons/quarterback/hailmary.png"),

	# ---- linebacker (batch 004) — tackle.png is pixel-identical to quarterback/tackle.png ----
	"linebacker/shed": preload("res://client/ui/ability_icons/linebacker/shed.png"),
	"linebacker/tackle": preload("res://client/ui/ability_icons/linebacker/tackle.png"),
	"linebacker/block": preload("res://client/ui/ability_icons/linebacker/block.png"),
	"linebacker/stripball": preload("res://client/ui/ability_icons/linebacker/stripball.png"),
	"linebacker/bullrush": preload("res://client/ui/ability_icons/linebacker/bullrush.png"),
	"linebacker/crackback": preload("res://client/ui/ability_icons/linebacker/crackback.png"),
	"linebacker/goalstand": preload("res://client/ui/ability_icons/linebacker/goalstand.png"),
	"linebacker/fourthgoal": preload("res://client/ui/ability_icons/linebacker/fourthgoal.png"),

	# ---- setter (batch 005) ----
	"setter/bump": preload("res://client/ui/ability_icons/setter/bump.png"),
	"setter/set": preload("res://client/ui/ability_icons/setter/set.png"),
	"setter/cover": preload("res://client/ui/ability_icons/setter/cover.png"),
	"setter/rally": preload("res://client/ui/ability_icons/setter/rally.png"),
	"setter/quickset": preload("res://client/ui/ability_icons/setter/quickset.png"),
	"setter/dig": preload("res://client/ui/ability_icons/setter/dig.png"),
	"setter/joust": preload("res://client/ui/ability_icons/setter/joust.png"),
	"setter/rotation": preload("res://client/ui/ability_icons/setter/rotation.png"),

	# ---- spiker (batch 006) — displayed "Jump Serve" lives under its key `serve` ----
	"spiker/serve": preload("res://client/ui/ability_icons/spiker/serve.png"),
	"spiker/approach": preload("res://client/ui/ability_icons/spiker/approach.png"),
	"spiker/thunderspike": preload("res://client/ui/ability_icons/spiker/thunderspike.png"),
	"spiker/toolblock": preload("res://client/ui/ability_icons/spiker/toolblock.png"),
	"spiker/rollshot": preload("res://client/ui/ability_icons/spiker/rollshot.png"),
	"spiker/pancake": preload("res://client/ui/ability_icons/spiker/pancake.png"),
	"spiker/roofblock": preload("res://client/ui/ability_icons/spiker/roofblock.png"),
	"spiker/killshot": preload("res://client/ui/ability_icons/spiker/killshot.png"),

	# ---- striker (batch 007) ----
	"striker/finesse": preload("res://client/ui/ability_icons/striker/finesse.png"),
	"striker/dribble": preload("res://client/ui/ability_icons/striker/dribble.png"),
	"striker/yellowcard": preload("res://client/ui/ability_icons/striker/yellowcard.png"),
	"striker/stepover": preload("res://client/ui/ability_icons/striker/stepover.png"),
	"striker/clinical": preload("res://client/ui/ability_icons/striker/clinical.png"),
	"striker/throughball": preload("res://client/ui/ability_icons/striker/throughball.png"),
	"striker/bicyclekick": preload("res://client/ui/ability_icons/striker/bicyclekick.png"),
	"striker/goldengoal": preload("res://client/ui/ability_icons/striker/goldengoal.png"),

	# ---- goalkeeper (batch 008) — displayed "Punching Save" lives under its key `header` ----
	"goalkeeper/distribution": preload("res://client/ui/ability_icons/goalkeeper/distribution.png"),
	"goalkeeper/header": preload("res://client/ui/ability_icons/goalkeeper/header.png"),
	"goalkeeper/divingsave": preload("res://client/ui/ability_icons/goalkeeper/divingsave.png"),
	"goalkeeper/keeperrush": preload("res://client/ui/ability_icons/goalkeeper/keeperrush.png"),
	"goalkeeper/sweeper": preload("res://client/ui/ability_icons/goalkeeper/sweeper.png"),
	"goalkeeper/claimcross": preload("res://client/ui/ability_icons/goalkeeper/claimcross.png"),
	"goalkeeper/rollout": preload("res://client/ui/ability_icons/goalkeeper/rollout.png"),
	"goalkeeper/penaltysave": preload("res://client/ui/ability_icons/goalkeeper/penaltysave.png"),
}

static func id_for(class_id: String, ability_key: String) -> String:
	return "%s/%s" % [class_id, ability_key]

# the full-color Texture2D for a class/key pair (null + warning if unknown — the hotbar caller
# supplies the readable name-label fallback)
static func texture(class_id: String, ability_key: String) -> Texture2D:
	var id := id_for(class_id, ability_key)
	if not ICONS.has(id):
		push_warning("AbilityIcons: missing ability art '%s'" % id)
		return null
	return ICONS[id]

# every registered id (used by the registry test to sweep completeness both directions)
static func ids() -> Array:
	return ICONS.keys()
