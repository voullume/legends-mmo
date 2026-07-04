# Combat-Feel Tier 2 — new-chat kickoff prompt

Paste the block below into a fresh chat to start the Tier-2 pass.

---

Build the Tier-2 combat-feel pass for Legends MMO — the four juice items deferred from the (shipped +
live) Tier-1 pass: heal/shield combat text, procedural recoil + squash-stretch on struck bodies,
per-class signature VFX colors, and debris shards.

READ FIRST, in order:
1. docs/combat-feel-tier2-handoff.md — THE FULL PLAN (per-item hook points, the transform-ownership
   gotcha, sequencing, verification runbook, deploy split).
2. CLAUDE.md — architecture + conventions (server-authoritative, := inference traps, TABS, deploy flow).
3. Recalled memory: legends-mmo-combat-feel (what Tier 1 built and where), legends-mmo-deploy-ops.

MUST-KNOW context (details + line refs in the handoff):
- Tier 1 is LIVE: the impact stack (audio/flash/kick/hitstop/predicted-press) is event-driven from
  Client._handle_events. Proc-tagged events ("proc": true) are PASSIVE burn ticks — never give them
  impact-stack treatment. Every motion effect obeys the reduce_fx toggle + gets a tunable const.
- Item A (heal/shield text) appends presentation EVENTS in shared/Combat.gd apply_heal/apply_shield —
  events only, identity must stay byte-identical (bal_identity: sig_w=175623132 sig_d=351654260).
  Do NOT event per-hit lifesteal or the direct-write regens (spam — see the handoff's exclusion list).
- Item B (recoil/squash) is CLIENT-ONLY render reaction. Respect transform ownership: holder.position =
  sim lerp, model.rotation.y = facing, model.scale = constant mscale, mob anim_node = procedural
  animator's (mobs already recoil — skip them). Restore transforms EXACTLY; decay in _update_fx.
- Item C (class colors) rides GameData.CLASSES[cid].color; projectile tint needs ONE additive field in
  the server snapshot (old clients ignore it).
- Item D (shards) = pooled, hard-capped, reduce_fx-skipped.
- Compile-check via a REAL headless boot + grep, NOT --script loads (autoload resolution false-fails).

WORKFLOW (project discipline): build slice → real-boot grep clean → bal_identity if shared/ touched →
headless event test (tools/test_procs.gd style) for A → adversarial review (Workflow) of the risk spots →
CHECKPOINT before any deploy. Order: A → B → C → D, each independently shippable. Deploy: B/D are
client-only (re-export + v0.1.0-test release upload — needs my approval); A/C need the server first
(push → CI image → droplet pull → smoke-client verify), then the client export/upload.

Start by reading docs/combat-feel-tier2-handoff.md, confirm you've read it, then begin with Item A.
