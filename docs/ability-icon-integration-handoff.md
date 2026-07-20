# Legends MMO — Ability / Skill Emblem Icon Handoff

**Purpose.** Design and integrate a permanent set of **skill emblem icons** for the 8 player classes
(64 abilities total), replacing the auto-shrunk ability-name text on each hotbar slot. The icons must
mesh with the shipped **Hybrid Cutout** UI icon system (v1.8.2, `docs/ui-icon-integration-handoff.pdf`)
— same asset spec, same runtime-modulation pipeline, same `IconRegistry`/`IconWidget` plumbing.

This is an **implementation plan + design brief**, not authorization to deploy. Like the UI-icon pass
it is **client-only** and should remain a reviewable change until in-game screenshots are approved.

---

## 0. Owner design direction (decided)

- **Sport-symbol motif.** Icons lean on each sport's visual vocabulary (see §5). Not literal team logos.
- **NO text / letters on the art.** The icon is a pure symbol. The keybind number (1–8) is separate
  chrome (the existing keycap chip), and the ability name/description live in the hover tooltip — never
  baked into the SVG. (This matches the Hybrid-Cutout rule: masters carry no `<text>` / font deps.)
- **Neutral masters, runtime-modulated** (the default, same as every shipped system icon). A **shared
  tint per ability *type*** is **optional / nice-to-have** — not required — and only where it helps a
  category read at a glance (e.g. all supports one hue). See §4 + §6.
- **Cohesion over uniqueness.** 64 icons should read as one family: shared stroke weight, shared
  "effect accent" motifs (slow / stun / knockback / shield / dash …, see §6), consistent silhouette
  density. Basics = simplest silhouettes; ults = the showpieces.

---

## 1. Asset production spec (identical to the shipped system)

Every master SVG must be:

- **64 × 64 viewBox**, transparent background.
- **Neutral ice-white artwork** `#EAFBFF` with dark cutouts `#08141D` (the 2-tone Hybrid-Cutout look).
  Do NOT bake semantic color in — color is applied at runtime via `modulate`.
- **No `<text>` / no font dependencies. No external references. No embedded raster (`data:` / base64).**
- Bold, legible silhouette at **small sizes** — a hotbar slot renders the icon at ~**40–48 px** (see §7),
  and it must still read there. (Design at 64, sanity-check at 40.)
- Imported into Godot at **`svg/scale = 2`** (128 px raster) with **mipmaps on**, exactly like
  `client/ui/icons/system/*` — so downscaling to the slot stays crisp. Force-add the `.svg.import`
  files (the repo `*.import`-ignores but tracks them; see the UI-icon pass).

**Quality gate (run before wiring):** every master is 64×64 viewBox · transparent · no text/font ·
no external refs · no raster · imports to `Texture2D` · modulates cleanly. (There's a one-liner grep
sweep in the UI-icon pass you can reuse.)

---

## 2. Naming & directory layout

Ability keys are **NOT globally unique** — `tackle` exists on both Quarterback and Linebacker (different
abilities). So icon IDs must be **class-scoped**.

```
client/ui/icons/system/abilities/<class>/<key>.svg      # 64 files
  e.g. abilities/pitcher/fastball.svg
       abilities/quarterback/tackle.svg
       abilities/linebacker/tackle.svg      # distinct art from QB's tackle
```

Semantic ID (registry key): **`abil.<class>.<key>`** (or `<class>/<key>`), resolved by a helper
`AbilityIcons.for(class_id, key)` (see §7). One SVG per (class, key) pair — 8 classes × 8 slots = **64**.

> The Glitchyard mobs/bosses reuse class-ish kits but **never render a hotbar** (only players do), so
> they need **no** ability icons. Scope is the 8 playable classes only.

---

## 3. Design cohesion rules

1. **One family.** Shared line weight, corner style, and cutout density across all 64.
2. **Slot-role reads at a glance** even before color:
   - **Basic** (slot 1): the simplest, cleanest silhouette — the "default swing/throw/pass" of the class.
   - **Specials** (slots 2–7): distinct verbs (dash, buff, stun, AoE, …).
   - **Ult** (slot 8): the showpiece — busier, more dramatic, the class's signature moment.
3. **Effect accent vocabulary** (see §6): reuse a small kit of accent motifs so recurring effects look
   related across classes (a "slow" chevron, a "stun" burst, a "shield" arc, a "dash" streak, …).
4. **No text, ever** — including no stylized letters, jersey numbers, or word-marks.

---

## 4. Runtime color (default = neutral; per-type tint optional)

The shipped pipeline modulates a neutral master to a color at draw time. For ability icons the **default**
is: render neutral / class-agnostic and let the **slot chrome** carry category (the hotbar already tints
each slot's background by role — ult = gold ring, basic = green, support = blue, normal = grey, via
`Client._slot_color`).

If the owner wants an **optional per-type tint** on the *icon itself* (nice for scanning), reuse the
same buckets so it stays consistent with the slot background:

| Category | Detected from ability def | Suggested tint |
|---|---|---|
| Ultimate | `ult == true` | gold (`Palette.ACCENT`) |
| Basic | `basic == true` | lime/green (`Palette.SB_LIME`) |
| Support (ally) | `type in [allybuff, allyheal, teamheal]` | cyan/blue (`Palette.SB_CYAN`) |
| Offense/other | else | neutral bright (`Palette.TEXT_BRIGHT`) |

Finer-grained option (only if it reads well): tint by **effect** rather than slot-role — e.g. all
*heals* green, all *shields* blue, all *stuns/CC* amber. Recommend starting **neutral** and adding tint
only if a play-test says the bar is hard to scan. Keep it a single toggle/switch so it's cheap to flip.

---

## 5. Sport-symbol motif guidance (per sport & class)

Draw the class's identity from its sport's equipment/action vocabulary — no team branding.

- **⚾ Baseball** — ball seams, bat, mound/plate, strike-zone box, glove. **Pitcher** = the arm/mound
  artillery (pitch arcs, zone box); **Batter** = the bat/impact/base-running (contact bursts, bases).
- **🏈 Football** — the ball's laces/oval, helmet, line-of-scrimmage, arrows/routes, shield-blocking.
  **Quarterback** = command/support (huddle, routes, throwing arc, protective pocket); **Linebacker** =
  the wrecking bruiser (charge, flatten, wrap-up, anchored stance).
- **🏐 Volleyball** — the net, the ball, the block "roof", a spike-down arc, a dig/pass. **Setter** =
  the enabler (set-up hands, rally, the net); **Spiker** = the leaping killer (airborne spike, the roof,
  a bypass "off-the-hands").
- **⚽ Soccer** — the ball's pentagon panels, the goal frame, boot/cleat, cards, the net ripple.
  **Striker** = the finisher (curled shots, boot, goal); **Goalkeeper** = the wall (gloves, the frame,
  a save dive, a reflect).

**Passive identities** (great anchors for a *class emblem*, if one is wanted alongside the 8 skills):

| Class | Passive identity (motif seed) |
|---|---|
| Pitcher | Zone artillery — paints the strike-zone box from range |
| Batter | Melee lifesteal + shield-crusher — heals off contact |
| Quarterback | The "pocket" — allies near him take less damage (protective aura) |
| Linebacker | **Momentum** — melee hits stack bonus damage (a building charge) |
| Setter | Amplifies allies (support boost + buff "echo"), heals off blocks |
| Spiker | Shield-**pierce** + bonus damage while **airborne** |
| Striker | **Hat Trick** — repeated hits on one target ramp; extra vs. low-HP (the closer) |
| Goalkeeper | **Clean Sheet** — builds a shield over time while untouched; amplified reflect |

---

## 6. Recurring effect vocabulary (shared accent motifs)

Reusing a tiny motif kit ties the 64 icons together. Recurring effects across the roster:

- **Slow** (×~7): Curveball, Changeup, Roll Shot, Through Ball, Joust, Crackback, Keeper Rush, Sweeper,
  Tackle(QB) → a shared "drag/weighted chevron" accent.
- **Stun / knockdown** (×~6): Beanball, Sack, Yellow Card, Tackle(LB), Fourth & Goal → a shared
  "impact burst" accent.
- **Knockback** (×~4): Power Swing, Bat Flip, Bull Rush, Grand Slam → a shared "shove/arc" accent.
- **Dash / evade / leap mobility** (×~12): Pickoff, Slide, Scramble, Cover, Approach, Pancake, Dribble,
  Thunderspike, Bicycle Kick, Kill Shot, Keeper Rush, Diving Save → a shared "motion streak" accent.
- **Shield / DR stances** (×~9): Check Swing, Block, Roof Block, Goal-Line Stand, Mound Presence,
  Step Over, Claim the Cross, Huddle Up, Diving Save, Roll Out, Penalty Save → a shared "guard arc".
- **Heal / cleanse** (×~3): Dig, Rotation, (Golden Goal on-kill) → a shared "restore" mark.
- **Pierce / reflect / empower / guard** (unique flavor): Tool the Block (pierce), Punching Save
  (reflect), Set (empower next), Roof Block (guard) — these map 1:1 to the *status* icons already
  shipped (shield_pierce / reflect / empowered / guard) and could echo those silhouettes for continuity.

---

## 7. Implementation plan (code integration)

**Client-only. No `server/`, `shared/`, protocol, snapshot, combat, ability-key, balance, or save changes.**

### 7a. Registry — a companion `AbilityIcons.gd` (client/ui/)
Mirror `IconRegistry`'s pattern, but keyed by (class, key), so ability entries don't bloat the general
UI registry and can carry ability-specific metadata (category → optional tint):

```gdscript
class_name AbilityIcons
extends RefCounted
# ID = "<class>/<key>". Textures PRELOADED so a missing path fails at import, not at play.
const ICONS := {
    "pitcher/fastball": preload("res://client/ui/icons/system/abilities/pitcher/fastball.svg"),
    "quarterback/tackle": preload("res://client/ui/icons/system/abilities/quarterback/tackle.svg"),
    "linebacker/tackle": preload("res://client/ui/icons/system/abilities/linebacker/tackle.svg"),
    ...  # 64 entries
}
static func texture(class_id: String, key: String) -> Texture2D:
    return ICONS.get("%s/%s" % [class_id, key])       # null → caller falls back to the name label
static func tint(ab: Dictionary) -> Color:            # optional per-category tint (see §4)
    if ab.get("ult", false): return Palette.ACCENT
    if ab.get("basic", false): return Palette.SB_LIME
    if str(ab.get("type","")) in ["allybuff","allyheal","teamheal"]: return Palette.SB_CYAN
    return Palette.TEXT_BRIGHT
```

### 7b. Hotbar slot — `Client._build_hotbar` (Client.gd ~4093)
Each 60×60 slot today draws: `bg` panel · `cd` wipe · `cap` keycap (top-left) · **`nl` ability-NAME
label (~y30, auto-shrunk)** · `cs` cooldown-seconds (center) · `ready` tick · `lock` overlay.

- **Replace the `nl` name Label with an icon `TextureRect`** built via `IconWidget.make(...)`:
  - `~44 px`, centered in the slot (below the top-left keycap), `MOUSE_FILTER_IGNORE`,
    `LINEAR_WITH_MIPMAPS`, `KEEP_ASPECT_CENTERED`, `EXPAND_IGNORE_SIZE` (same factory settings the
    shipped icons use — anchor it so its size derives from the slot, per the StatusRow lesson).
  - `modulate` = neutral by default, or `AbilityIcons.tint(ab)` if the tint toggle is on.
- **Keep everything else** (keycap number, cd wipe, cd seconds, ready tick, lock overlay) exactly as is —
  the cd-seconds label draws *over* the icon during cooldown, which is correct.
- **Name text moves to the tooltip only** — it's already there (`_on_slot_hover` → `_tt_label` at
  Client.gd ~4250 shows name/type/desc/stats), so no info is lost by dropping the tiny on-slot name.
- **Graceful fallback:** if `AbilityIcons.texture(class,key) == null`, keep the current name Label for
  that slot (so a not-yet-drawn ability degrades to text, never a blank slot — mirrors the StatusRow
  glyph fallback).

### 7c. Tooltip & lock overlay — unchanged
The unlock overlay's "Lv N" text and the hover tooltip stay code-native; the icon is decorative under them.

### 7d. Tests (mirror the UI-icon pass)
- Extend / add a registry test: **sweep all 64 (class,key) IDs** — each exists, texture non-null, and
  every ability in `GameData.CLASSES[*].abilities` resolves (so an added/renamed ability can't silently
  ship without art). Assert tint categories are valid.
- Add a hotbar render check: build `_build_hotbar(class)` for each of the 8 classes → 8 icon TextureRects
  with the right textures, no overflow, keycap + cd overlays intact, and the missing-icon fallback path.
- Re-run the existing headless suite (import, theme/window/hud/worldui/registry/status_row) + a windowed
  hotbar gallery + an in-game smoke (drive a real client, `--open` nothing needed — the bar is always up),
  then the conventional adversarial review. Capture before/after at 1920×1080 + a smaller size.

### 7e. Suggested phase order
1. Draw + import the 64 masters (batch by sport for cohesion).
2. `AbilityIcons.gd` + registry test (fail fast on a missing/renamed ability).
3. Hotbar slot: icon TextureRect + name→tooltip + fallback.
4. Optional per-category tint (single toggle).
5. Tests · windowed gallery · in-game smoke · adversarial review · screenshots.

---

## 8. Complete ability catalog (source of truth: `shared/GameData.gd`)

Kits are 8 slots: **1 = basic**, **2–7 = specials** (unlock in order by level), **8 = ult**. Cue tags
show the icon's "shape"; the description is the in-game copy. Class `hex` is the class color (for tint /
emblem, not required on the art).

### ⚾ Pitcher · `#58C6FF` · Zone Artillery
1. **Fastball** — *basic · projectile* — A quick pitch that pelts the target.
2. **Curveball** — *projectile · slow* — A bending pitch that slows the target.
3. **Pickoff Move** — *dash · evade* — A quick-step dash off the mound; briefly evades all attacks.
4. **Strike Zone** — *ground-zone · empower* — Paint a zone: your projectiles (and allies') hit harder inside it.
5. **Changeup** — *projectile · heavy slow* — A deceptive off-speed ball that heavily slows the target.
6. **Beanball** — *projectile · stun* — A wild inside fastball that stuns the target.
7. **Mound Presence** — *self-buff · DR + move-speed* — Dig in: take less damage and move faster briefly.
8. **Perfect Game** — *ULT · barrage ×3* — Unleash three full-heat fastballs in a row.

### ⚾ Batter · `#2F86FF` · Melee Burst
1. **Swing** — *basic · melee · lifesteal* — A bat swing; your melee hits heal you for a cut of the damage.
2. **Power Swing** — *melee · big hit + knockback* — A wound-up slugger swing that knocks the target back.
3. **Slide** — *dash · evade · gap-close* — Dive into/out of the play; briefly evades all attacks.
4. **Check Swing** — *self-buff · DR* — Hold up and brace: sharply reduced damage taken, briefly.
5. **Bat Flip** — *melee AoE · knockback* — A taunting arc: damages and knocks back everyone nearby.
6. **Stolen Base** — *self-buff · move-speed* — Take off for the next bag: a burst of speed.
7. **Walk-Off** — *melee · self-shield on hit* — A game-ending blow; a clean hit also shields you.
8. **Grand Slam** — *ULT · melee AoE · huge knockback* — A colossal swing: heavy damage + big knockback all around.

### 🏈 Quarterback · `#51E08A` · Support Tank
1. **Shoulder Check** — *basic · melee* — A shoulder-first jab.
2. **Huddle Up** — *ally-buff · shield* — Call the huddle: shield an ally.
3. **Scramble** — *dash · evade → self DR* — Escape the pocket: dash with brief evasion, then shrug off damage.
4. **Blitz** — *ally-buff · attack-speed* — Fire up an ally: faster basic attacks.
5. **Tackle** — *dash-attack · slow* — Charge a target, hit, and slow them. *(distinct from LB Tackle)*
6. **Sack** — *melee · stun (low dmg)* — A wrap-up hit that stuns the target.
7. **Play Action** — *ally-buff · move-speed + DR* — Fake the hand-off: an ally moves faster, takes less damage.
8. **Hail Mary** — *ULT · projectile · team shield on hit* — A deep bomb; a connecting hit shields every ally.

### 🏈 Linebacker · `#1FA864` · Bruiser
1. **Shed Block** — *basic · melee · builds Momentum* — Shed a blocker and strike; melee hits build Momentum (stacking dmg).
2. **Tackle** — *dash-attack · knockdown* — Charge and flatten the target. *(distinct from QB Tackle)*
3. **Block** — *self-buff · heavy DR* — Set your base: take much less damage, briefly.
4. **Strip Ball** — *melee · dispel (strips 1 enemy buff)* — Punch the ball out: a hit strips one enemy buff.
5. **Bull Rush** — *dash-attack · knockback* — Charge through the line, knocking the target back.
6. **Crackback** — *melee AoE · slow* — A blindside sweep: damages and slows everyone nearby.
7. **Goal-Line Stand** — *self-buff · huge DR (self-slow)* — Anchor the line: heavy DR, but you move slower.
8. **Fourth & Goal** — *ULT · dash-attack · knockdown* — An unstoppable charge: massive damage + a knockdown.

### 🏐 Setter · `#C792EA` · Support
1. **Bump** — *basic · projectile* — A precise pass turned projectile.
2. **Set** — *ally-buff · empower (next special ×1.7)* — Set up an ally: their next special hits much harder.
3. **Cover** — *dash · evade* — Slide under the play: dash with brief evasion.
4. **Rally** — *ally-buff · crit + attack-speed* — Rally an ally: bonus crit and faster basics.
5. **Quick Set** — *ally-buff · move-speed* — Run the quick tempo: an ally moves much faster.
6. **Dig** — *ally-heal* — Dig the attack out: heal an ally.
7. **Joust** — *projectile · slow* — Contest at the net: damages and slows the target.
8. **Rotation** — *ULT · team-heal · cleanse* — Rotate the lineup: heal the whole team and cleanse stuns/slows.

### 🏐 Spiker · `#9D5CFF` · Burst Assassin
1. **Jump Serve** — *basic · projectile* — A leaping serve fired at the target.
2. **Approach** — *dash → self move-speed* — Explosive approach steps: dash, then keep the momentum.
3. **Thunderspike** — *leap-attack · airborne (bonus dmg)* — Leap to the target and spike down.
4. **Tool the Block** — *self-buff · pierce (ignore shields)* — Aim off the hands: your hits pierce enemy shields.
5. **Roll Shot** — *projectile · slow* — A soft roll shot that slows the target.
6. **Pancake** — *dash · evade* — Dive flat to the floor: dash with brief evasion.
7. **Roof Block** — *self-buff · DR + guard (knocks back 1st melee)* — Put up a roof; first melee attacker is knocked back.
8. **Kill Shot** — *ULT · leap-attack · untargetable while airborne* — Leap untargetable and bury the kill shot.

### ⚽ Striker · `#FF8A4C` · Finisher
1. **Finesse Shot** — *basic · projectile · builds Hat Trick* — A curled shot; repeated hits on one target chain into Hat Trick.
2. **Dribble** — *dash (short CD)* — A burst dribble: quick dash on a short cooldown.
3. **Yellow Card** — *melee · stun* — A cynical foul that stuns the target.
4. **Step Over** — *self-buff · move-speed + DR* — Sell the feint: move faster and take less damage.
5. **Clinical Finish** — *projectile · execute (bonus vs. hurt)* — A clinical strike; bonus damage vs. badly hurt targets.
6. **Through Ball** — *projectile · slow* — A driven ball that slows the target.
7. **Bicycle Kick** — *leap-attack · overhead* — Leap to the target and strike overhead.
8. **Golden Goal** — *ULT · projectile · on-kill speed/DR burst* — The match-winner; scoring the kill grants speed + toughness.

### ⚽ Goalkeeper · `#E4572E` · Guardian
1. **Distribution** — *basic · projectile* — A sharp throw at the target.
2. **Punching Save** — *self-buff · reflect (next hit, amplified)* — Read the shot: reflect the next hit back, amplified.
3. **Diving Save** — *ally-buff · dash-to + shield* — Dive to an ally and shield them.
4. **Keeper Rush** — *dash-attack · slow* — Rush off the line: a dash attack that slows the target.
5. **Sweeper** — *melee AoE · slow* — Sweep the box: damages and slows everyone nearby.
6. **Claim the Cross** — *self-buff · DR + move-speed* — Command the area: take less damage and move faster.
7. **Roll Out** — *ally-buff · shield + move-speed* — Roll the ball out: shield an ally and speed them up.
8. **Penalty Save** — *ULT · barrier → damage-scaled blast* — An impenetrable stance ending in a blast that grows with damage soaked.

---

## 9. Open decisions (owner calls before/at build)

1. **Per-type icon tint:** ship **neutral** (recommended; slot background already conveys role), or turn
   on the §4 per-category tint? (Cheap single toggle either way.)
2. **On-slot layout:** icon **fills the slot** with the name only in the tooltip (recommended), or icon +
   a tiny name footer? (Recommended: icon-only face — the 54×28 name box is the readability problem this
   solves.)
3. **Class emblems too?** Do we also want an **8-class emblem** set (using the §5 passive identities) for
   the character/class-select screens, or just the 64 skill icons this pass?
4. **Effect-motif kit:** approve a small shared accent kit (slow / stun / knockback / shield / dash / heal
   / pierce-reflect-empower-guard) first (§6), so all 64 draw from the same vocabulary.
5. **Reuse the shipped status icons** for pierce / reflect / empowered / guard silhouettes (continuity),
   or draw fresh ones for the ability context?

## 10. What NOT to change (client-only boundary)

`server/`, `shared/` (incl. `GameData.gd` ability defs/keys), snapshot formats, protocol version, combat
logic, ability keys/bindings, balance, and save data are **out of scope**. Ability **keys and names are
pinned by tests + owner-facing docs** — do not rename them to fit art; the icon maps to the existing key.
