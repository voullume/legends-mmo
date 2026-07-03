# Combat-Feel Pass — new-chat kickoff prompt

Paste the block below into a fresh chat to start the **Tier-1 combat-feel pass**. It points at the full plan
(`docs/combat-feel-handoff.md`) and front-loads the must-know context + gotchas so the new session is
self-sufficient (it auto-loads the memory index + `CLAUDE.md`).

---

Build the **Tier-1 combat-feel pass** for Legends MMO — fix "pressing the buttons just feels like pressing
buttons." Combat works; it lacks game-FEEL. This is a CLIENT-ONLY presentation pass (no `shared/`, no server,
no migration, no determinism/balance risk).

READ FIRST, in order:
1. `docs/combat-feel-handoff.md` — THE FULL PLAN (diagnosis, the 5 Tier-1 changes with exact code hook points,
   sequencing, constraints, deploy).
2. `CLAUDE.md` — architecture + conventions (server-authoritative, `:=` inference traps, TABS, the deploy flow).
3. Recalled memory, especially: `legends-mmo-combat-feel`, `legends-mmo-deploy-ops`,
   `legends-mmo-character-anim-deadend`.

MUST-KNOW context (details + line refs in the handoff):
- **Audio is already sourced.** 14 CC0 Kenney `.ogg` files are in `audio/sfx/` named to `AudioManager.SFX_NAMES`,
  imported + verified loadable (grounded/de-sci-fi'd; see `audio/sfx/ATTRIBUTION.md`). The game becomes audible
  the moment these are committed + the client is re-exported — zero code. First task: commit them, then polish
  the call sites (dealt-vs-taken routing, damage-scaled pitch/gain, cast sounds for nearby casters).
- **Per-class cast sounds are pre-staged** (bat crack, ball kick, tackle, spike, throws…): 8 `cast_<class>.ogg`
  are already in `audio/sfx/`, imported, but INERT (not in `SFX_NAMES`). Wiring them is a small client change —
  add the 8 names + a `classId → cast_<class>` lookup falling back to the generic `cast_melee/ranged/...`. Punchier
  throw alternates for pitcher/QB are in `audio/sfx/alts/`. Details in `audio/sfx/ATTRIBUTION.md` + the handoff.
- **The 5 Tier-1 changes:** (1) wire audio punch, (2) material hit-flash on the struck body, (3) directional
  camera kick when YOU deal damage, (4) render-only hitstop, (5) predicted feedback on the exact keypress
  (swing anim + hotbar depress + predicted cooldown). Root cause of the "lag feel" is #5 + the silence.
- **The character animations are a DEAD-END** — do NOT try to improve them. All feel is code-driven.

HARD CONSTRAINTS:
- Client-only. No `shared/` change (would break combat determinism — the balance harness must stay
  byte-identical). Server stays authoritative; predicted client tells must self-correct on the next snapshot.
- **Hitstop must be RENDER-ONLY** — never `Engine.time_scale`/`paused` (stalls the 60 Hz input loop, desyncs).
- Effects must be cheap + pooled (MMO scale). Every effect gets a tunable magnitude + a "reduce screen effects"
  toggle in the O-settings menu (motion-sickness accessibility).
- Two real risk spots to watch: the hit-flash shares the `material_overlay` channel with the **dye cosmetic**
  (cache/restore the dye), and **predicted-cast mispredict** (server rejects out-of-range/stunned casts —
  keep the tell subtle + self-correcting, nothing irreversible on prediction).

WORKFLOW (project discipline): build a slice → `godot --headless --import` (clean) → adversarial review
(Workflow) of the risk spots → CHECKPOINT before any deploy. Suggested order: audio → impact stack
(flash+kick+hitstop, tuned together) → predicted press. Deploy is a CLIENT RE-EXPORT + `v0.1.0-test` release
upload (NOT a droplet redeploy) — see the handoff + deploy-ops memory; the release upload needs user approval.

Start by reading `docs/combat-feel-handoff.md`, confirm you've read it, then begin with Step 0 (audio: commit
the placed SFX + the call-site polish).
