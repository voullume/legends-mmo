# UI Overhaul (P0 + P1 w/ DPS meter) — new-chat kickoff prompt

Paste the block below into a fresh chat to start the UI overhaul.

---

Build the UI overhaul foundation for Legends MMO — P0 (design system) then P1 (HUD) with the DPS/HPS
meter as the flagship panel. The game is feature-complete and live; this pass gives it a visual
identity. Everything here is CLIENT-ONLY.

READ FIRST, in order:
1. docs/ui-overhaul-handoff.md — THE FULL PLAN (current-UI inventory with fresh file:line anchors,
   the Theme-on-_hud architecture move, phases P0–P4, §4a = the complete DPS-meter spec, keybind map).
2. CLAUDE.md — conventions (TABS, := inference traps, deploy flow).
3. Recalled memory: legends-mmo-ui-overhaul, legends-mmo-combat-feel (Tier 2 built the event stream +
   FX language the meter and floaters ride), legends-mmo-deploy-ops (client deploy = re-export + upload).

MUST-KNOW context (details + line refs in the handoff):
- CLIENT-ONLY: never touch shared/ or server/. No bal_identity gate, no server redeploy. If a UI idea
  seems to need a server field, STOP and flag it — it's out of scope by design (§4a lists the one known
  case: lifesteal/regen HPS visibility → a future shared/ slice, NOT this pass).
- The ONE architectural move: a single Theme resource set on the _hud CanvasLayer (Client.gd:2026)
  restyles every Control at once. Build Palette.gd + theme.tres + Widgets.gd (client/ui/), apply, add
  the project.godot [display] stretch config, then migrate panels one at a time. A project.godot edit
  DOES bust the import cache, but that's now harmless: your dev box re-imports locally, CI rebuilds the
  server image off-box on every push anyway (slower with the cache busted, but safe), and the droplet
  only ever pulls the prebuilt GHCR image — client-only work never causes an on-box build or needs a
  server redeploy.
- The DPS meter (§4a) is pure client: accumulate dmg + heal/shield events inside _handle_events
  (Client.gd:1031) BEFORE _state["events"].clear(); 15-slot per-second ring for rolling DPS; encounter
  edges on ≥5 s event silence; rows = class-color chip + name + normalized bar + number; modes
  DPS-rolling / DPS-encounter / HPS / taken; toggle key N; footer caveat "lifesteal + regens not counted".
  Tap the RAW events, not the render-side gains coalescing that sits in the same loop.
- Panel re-render at ~4 Hz on a timer, never per frame. Prune idle meter rows (>60 s). Sandbox R/C
  resets must not leak rows (_teardown discipline — same trap the Tier-2 shard pool hit).
- Verify visually: F5 sandbox (bots brawl → meter fills immediately) + --online against the live server
  (heal/shield events are live). A real headless boot + grep still gates every commit (compile check);
  there is no UI test harness — eyeball at 2–3 window sizes for the stretch config.

WORKFLOW (project discipline): P0 first (Palette + theme.tres + font + [display] + apply to _hud +
restyle ONE panel, the Practice Vendor, as the Widgets pattern-proof) → eyeball at multiple sizes →
P1 vitals frame + currency tray → the §4a DPS meter → skill-bar polish → real-boot grep clean →
adversarial review (Workflow) focused on: Theme-migration breakage across ALL panels (open every one),
node leaks on re-render, meter accumulator correctness (proc-tagged dmg counted, gains tapped raw,
encounter edges, teardown), resolution scaling, keybind collisions (N is free; L/G are taken) →
CHECKPOINT before deploy. Deploy = client re-export + v0.1.0-test release upload (needs my approval);
no server work.

Start by reading docs/ui-overhaul-handoff.md, confirm you've read it (call out §4a), then begin P0.
