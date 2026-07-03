# AI Residents — Design + Implementation Handoff

> **Status: PLAN ONLY (2026-07-03).** AI-driven "players" that live in the world, fight content, and can be
> partied/played-with by real players — some specialized at different parts of the game. Nothing below is built.
> Read `CLAUDE.md` + the endgame handoffs first. Every design choice is grounded in seams the engine already has.

---

## 0. TL;DR + the one insight that makes this cheap

**Goal:** populate the live world with AI "residents" that function and act like normal players — they fight
mobs, roam zones, support allies, can be **invited to a party and played alongside**, and specialize (a
grinder farms the Glitchyard, a raider camps the boss, a support heals whoever's near, a duelist haunts the
Arena).

**The load-bearing insight:** the sim already decides *human vs AI* per fighter via one flag. In
`shared/Sim.gd::sim_tick`, a fighter runs `_player_step` **only if `state["controlled"].has(f["id"])`** —
otherwise it runs the full **AI brain** (`shared/AI.gd`: target-pick → ability loop → movement → separation →
support routing). The server builds `w["controlled"]` **only for connected peers** (`_tick_world`). So a
**team-0 fighter the server spawns but never marks `controlled` is, for free, a competent friendly AI player**
— it shares team 0 with real players (so it fights the team-1 mobs *alongside* them, and a support-class one
even heals them), and it already renders in snapshots like any fighter.

**Approach: SERVER-SIDE residents (not external client bots).** Ephemeral, server-defined entities — no
Supabase accounts, no login, no DB, no economy. They *are* played-with-like-normal-players from every other
player's view (identical model/combat/nameplate, partyable), they just have no keyboard. This is ~10× cheaper
than running a headless Godot client per bot and needs no auth/network/snapshot-stream per resident.
(The heavier "external client bots on real accounts" variant is only worth it for full-stack *login/DB
testing* — a separate future track; see §7.)

---

## 1. Architecture — three layers

1. **Combat (reuse, zero new code).** A resident is a team-0 fighter absent from `controlled` → the existing
   AI brain drives its fighting. Targeting `_nearest_enemy` finds cross-team hostiles → team-1 mobs; support
   routing (`AI.support_tick`) heals/buffs team-0 allies **including real players**. In a `pvp` zone the
   existing `Combat.is_hostile` makes an un-partied resident hostile to other players (→ a duelist). All free.
2. **Identity (small).** Residents have no `_session`, so the name/level the snapshot normally pulls from
   `_session` (via `pinfo` in `_broadcast`) must come from a parallel source: fields stamped on the fighter
   (`resName`/`resLevel`/`resPersona`). `_snapshot_for` adds them to the fighter block so the client renders a
   normal nameplate. (Optional: a subtle marker, or fully indistinguishable — a §7 decision.)
3. **The Director (the new work).** The AI brain only fights *within* a world; it doesn't pick zones, travel,
   respawn, or interact with content/party systems. A server-side **`_tick_residents()`** director (low
   cadence, ~1 Hz) gives each resident player-like macro behavior: which zone to be in, roaming, zone travel
   (via `_relocate`, since residents don't walk portals), respawn, persona power, party-follow, and chat.

---

## 2. The roster + specialization (personas)

A `RESIDENTS` roster (a data table — `shared/Residents.gd` or a server const). Each entry:
`{id, name, class, persona, level, power_tier, home_zone}`. **Persona → behavior + where it lives + how strong.**
Starting roster (tune freely):

| Persona | Class (example) | Home / behavior | Power tier |
|---|---|---|---|
| **Grinder** | Linebacker / Batter | roams Glitchyard 1–5 camps, farms mobs; great to fight alongside a leveling player | mid |
| **Raider** | Spiker / Striker | camps the Head Coach arena (and can be pulled into the fight); survives the boss | high |
| **Support** | Setter / Goalkeeper | roams the early zones, heals/buffs whoever's near — the ideal party companion | mid |
| **Duelist** | Spiker / Striker | haunts the **Arena** (PvP), fights other players there | high |
| **Wanderer** | any | drifts between zones + home, low-key ambient presence + chat | low/mid |

Start with ~5–8 residents total (bounded for load). More personas later (a "mentor" that seeks out low-level
players and sticks with them; a "boss-caller" that rallies a raid).

---

## 3. The power model (gear-equivalent, determinism-safe)

Real players scale via **level** (flat `LEVEL_HP` per level) + **gear** (capped stat bonuses). Residents have
no inventory, so a **`_scale_resident(f, level, tier)`** emulates gear with a per-persona multiplier:
`maxHP += (level-1)*LEVEL_HP; maxHP *= tier.hp; dmgMult *= tier.dmg`. A **raider** (high tier) survives the
boss; a **grinder** (mid) fits the camps. This mirrors `_scale_mob` but for team-0 residents. **Determinism
note:** residents live only in the LIVE sim, never in the `bal_identity`/`bal_p1` harness (which runs isolated
player-vs-player matches), so this changes no harness result — byte-identity is preserved. No `shared/` combat
change is needed for any of this (the director + scaling are server-side; combat reuses the existing brain).

---

## 4. Cross-cutting concerns (designed-for up front)

- **Server load:** each resident = one fighter running the AI brain (cheap) + a ~1 Hz director step (trivial).
  Current headroom is large (`peak_tick 4.3ms/33ms`, 538 MB free). Cap the roster (~5–10) and it's negligible.
- **Kill-steal:** if a resident last-hits a mob a player was fighting, `_award_kills` credits the resident's
  fid (which is in no `_session`) → the player gets nothing. Mitigations (pick in §7): residents avoid
  last-hitting when a player is engaged; or credit the highest-damage *player* on the mob; or accept it
  (residents help *and* occasionally steal, like a real ally). Low impact for a demo.
- **Economy:** residents earn nothing (no session/DB) and can't buy/sell/loot — `_award_kills`,
  `_grant_loot`, shop/forge/etc. are all `_session`-keyed, so residents are naturally excluded. No dupe/economy
  surface. They also must be excluded from leaderboards (they have no `char_id`).
- **Determinism/dupe:** no `shared/` combat change; the director is server orchestration; run `bal_identity`
  each phase as proof (expected byte-identical). No new client→server mutating RPC except party-accept-for-a-
  resident, which is server-authoritative.
- **Instances:** residents live in the **shared** worlds (home / Glitchyard / boss arena / Arena). Joining a
  player's *private* Camp/Drill instance is a stretch goal (§7), not in the core plan.

---

## 5. Phased implementation plan (each: implement → `--import` → `bal_identity` proof → adversarial review →
   CHECKPOINT before deploy; residents are server + snapshot + client-render, so deploy = server redeploy +
   client re-export, **no migration**)

### RP0 — Presence & combat (the proof)
Spawn the roster as team-0 fighters at boot in their home zones, driven by the AI brain, with identity in the
snapshot and respawn on death. No director/travel yet — they fight where they stand. *Outcome: named AI
"players" visibly fighting mobs in the live zones.*
- `_spawn_residents()` (after `_spawn_world_actors` in `start()`): for each roster entry, `_spawn_fighter(cls,
  0, pos, home)`, stamp `resident/resName/resLevel/resPersona`, call `_scale_resident`.
- **Never add residents to `w["controlled"]`** (they must run the AI brain) — `_tick_world` only adds peers,
  so this is automatic; add an assertion/comment.
- Identity: `_snapshot_for` adds `name`/`level` (+ a `resident` marker) to a resident's fighter block; the
  client nameplate path already renders team-0 `level`/`name` (`Client.gd::_update_ui`).
- Respawn: teach `_revive` the resident case — re-apply `_scale_resident` (not `_recompute_player_stats`,
  which needs a session). Queue resident respawn in `_tick_world` like a mob (they're team 0 but session-less).
- Verify: connect a headless client, confirm residents appear + fight + respawn, 0 errors; `bal_identity`
  byte-identical.

### RP1 — The Director + specialization
Add `_tick_residents()` (~1 Hz): per-persona home-keeping + roaming (nudge toward camps within the home zone),
periodic **zone travel** (`_relocate` a wanderer between zones), and persona-appropriate positioning (a raider
holds near the boss camp; a duelist stays in the Arena). Residents now *behave* like players working content.
- Data-drive it from the persona (home_zone + a small behavior enum). Keep it cheap (state on the fighter/a
  `_residents` meta dict; no per-tick pathfinding — the AI brain handles local movement, the director only
  sets coarse goals/relocations).

### RP2 — Party & "play with" (the payoff)
Let a real player right-click-invite a resident; the resident **auto-accepts** (a short natural delay), joins
the party, **follows the leader**, and supports/fights for the party.
- Party model extension (the meatiest bit): `_party_key`/roster are pid-based; residents are fid-only.
  Add resident fids as party members (a `party_residents` list on the session + a `_resident_party` map),
  fold them into `_party_key` (so party-mates are allies + no friendly-fire in pvp) and `_party_roster`
  (so the HUD frame shows the resident's live HP/name).
- `party_invite`: when the target fid is a resident (`_pid_by_fid` == -1 but it's a resident), route to a
  resident auto-accept instead of the peer `recv_party_invite`.
- Director: a partied resident's home becomes "follow the leader" — `_relocate`/steer toward the leader's zone
  + position; a support resident heals the party (already automatic via `AI.support_tick`).

### RP3 — Life & flavor (optional, small)
Persona chat lines via the existing chat relay (e.g. the Grinder says "camp's clear, moving up"; a Support
says "topped you off"), contextual (on a kill, on joining a party, on a boss pull). Adds presence; cheap.

### RP4 — Reports (optional; the earlier testing angle)
The director logs per-resident metrics/anomalies (stuck, repeated deaths in one zone, no progress) to a
`bot_reports` table or the server log — a lightweight automated-playtest signal. Fully separable.

---

## 6. Decisions — LOCKED (approved 2026-07-03)
1. **Roster = 6** residents (personas below).
2. **Subtle marker** (a small ◆ / faint tag) — not fully hidden, not a loud "BOT"; human-like names.
3. **Kill attribution:** most residents are "polite" — when a polite resident lands the killing blow, the kill
   (xp/loot/credits/quest) is reassigned to the nearest engaged PLAYER, so helping never robs you. **ONE rude
   resident ("in for their own gain")** does NOT reassign — it hogs its kills (and behaves selfishly: grabs
   mobs first, won't heal/assist, antagonistic chat).
4. **Full party** integration (invite → auto-accept → follow → fight/heal for the party).
5. **Ephemeral server residents** (no accounts/DB).
6. **Shared worlds only** for v1 (no joining private Camp/Drill instances yet).

**The 6-resident roster (starting values — tune freely):**
| id | name | class | persona | home | tier | polite |
|---|---|---|---|---|---|---|
| sarge | Sarge | linebacker | Grinder | glitchyard_2 | mid | yes |
| mercy | Mercy | setter | Support (heals) | glitchyard_1 | mid | yes |
| blitz | Blitz | spiker | Raider | glitchyard_boss | high | yes |
| reaper | Reaper | striker | Duelist | arena | high | yes |
| nomad | Nomad | goalkeeper | Wanderer (roams) | home | mid | yes |
| vulture | Vulture | batter | **Rude / self-interested** | glitchyard_4 | high | **no** |

---

## 7. File-hook index (where each change lands)
- Roster data: new `shared/Residents.gd` (or a `server/Server.gd` const) — `{id,name,class,persona,level,tier,home}`.
- Spawn + scale: `server/Server.gd` `_spawn_residents()` (call in `start()` ~L168), `_scale_resident()`
  (mirror `_scale_mob` ~L1535), `_revive` resident branch (~L1512).
- Director: `server/Server.gd` `_tick_residents()` (call in `_physics_process` near `_check_portals` ~L1541).
- Identity in snapshot: `server/Server.gd` `_snapshot_for` fighter block (~L2375) + `_broadcast` pinfo (~L2387).
- Party: `server/Server.gd` `party_invite`/`party_accept`/`_party_key`/`_party_roster`/`_party_set`
  (~L402–507) + a `_resident_party` map + resident cleanup on disconnect/leave.
- Client: `client/Client.gd` nameplate (`_update_ui` ~L1266 already handles team-0 name/level; add a subtle
  resident marker if chosen); no new panels needed for RP0–RP2.
- Determinism gate: `tools/bal_identity.gd` unchanged (residents are structurally excluded — assert this).
