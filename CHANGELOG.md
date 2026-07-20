# Changelog

Every deployed version of Legends MMO, newest first. Each `vX.Y.Z` has a matching
git tag and a `ghcr.io/voullume/legends-mmo:vX.Y.Z` image — exact saved copies of
what shipped. Cut a new version with `deploy/release.sh [patch|minor|major] "note"`.

## v1.10.0 — 2026-07-20

- The Arrowbound Howler claims the sideline — the Wildlife Expanse roster is complete (all 7 wild creatures live). Update your client to face the new boss.

_(rolls up commits since the previous tag; base 2f0929f)_

## v1.9.2 — 2026-07-20

- Splinterback elite prowls the Reclaimed Stadium (Wildlife Expanse W4b) — update your client to see it

_(rolls up commits since the previous tag; base 90365e1)_

## v1.9.1 — 2026-07-20

- Emerald Warfrog elite anchors the Overrun Gauntlet (Wildlife Expanse W4) — update your client to see the new elite

_(rolls up commits since the previous tag; base 7783b2b)_

## v1.9.0 — 2026-07-20

- Wildlife Expanse: the away zones' camps are now wild creatures (netvine skink, tacklehorn grazer, scrapmask forager, rallywing magpie) with new attack mechanics; zones re-themed. Update your client — old clients show placeholder capsules for the new creatures.

_(rolls up commits since the previous tag; base 04f2a7e)_

## v1.8.4 — 2026-07-20

- Netvine Skink vertical slice, ships dark (Wildlife Expanse W2) — admin-spawn only, no player-visible change

_(rolls up commits since the previous tag; base ac66b35)_

## v1.8.3 — 2026-07-20

- 64 full-color ability icons on all 8 class hotbars (client-only); rolls up the Quest Giver/Journal live-refresh fix

_(rolls up commits since the previous tag; base 35c51a1)_

## v1.8.2 — 2026-07-17

- Hybrid-Cutout SVG UI icon system (client-only): icons replace emoji / two-letter status chips / currency glyphs across HUD, windows, buttons, toasts, and world markers

_(rolls up commits since the previous tag; base 808a326)_

## v1.8.1 — 2026-07-17

- Part A nameplate + overhead statuses

_(rolls up commits since the previous tag; base 12d8c10)_

## v1.8.0 — 2026-07-16

- UI consistency pass: theme now renders (CanvasLayer fix), buff/debuff status icons on all unit frames, world-label clutter fade, sports-tech chrome on all main windows

_(rolls up commits since the previous tag; base 06c1bbd)_

## v1.7.0 — 2026-07-15

- 8-skill class expansion: every class gets a full basic + 6 specials + ultimate kit, new combat primitives (buffs/dispels/guards/casted projectiles), retuned FORMAT_MODS[5] balance

_(rolls up commits since the previous tag; base c6f6631)_

## v1.6.0 — 2026-07-15

- The world gets solid: every object now has real collision (walls block shots too!) — and the maps sit in rolling terrain with a horizon instead of floating in the void

_(rolls up commits since the previous tag; base 30df68b)_

## v1.5.1 — 2026-07-15

- Raid integrity: AI companions now wait outside the Head Coach arenas (bring a real team) — plus release-pipeline hardening

_(rolls up commits since the previous tag; base 6623d90)_

## v1.5.0 — 2026-07-15

- Phase 8 complete: the Away Circuit fully dressed — new landmark props across all seven zones, and meet Scout, Roadie & Champ, the road-trip residents

_(rolls up commits since the previous tag; base dbecb34)_

## v1.4.0 — 2026-07-14

- The Finals are open! Championship district zones for levels 17-25 — the Grand Gallery miniboss, new quests and epic rewards, Practice Tokens across the whole road

_(rolls up commits since the previous tag; base 38ff9e0)_

## v1.3.0 — 2026-07-14

- Beat the Rival! The Away Games chain concludes: Rival Stadium + the Rival Coach boss fight (levels 13-16), the Rival Crimson dye, and mob recolors now render properly

_(rolls up commits since the previous tag; base 78b9847)_

## v1.2.0 — 2026-07-14

- The Away Circuit opens! New 'Away Games' zones for levels 8-16 (north gate at Home) — new quests, rival mobs, bounties, and Practice Tokens on the road

_(rolls up commits since the previous tag; base a008fa7)_

## v1.1.1 — 2026-07-14

- fix: clean-import client build so props load

_(rolls up commits since the previous tag; base 203cfd6)_

## v1.1.0 — 2026-07-14

- Jump! Press Space to hop — now visible to other players (network protocol v2; older clients are prompted to update)

_(rolls up commits since the previous tag; base dde4103)_

## v1.0.1 — 2026-07-13

- props: 21 admin-decor props + tiled turf/scrapyard ground textures (client-only)

_(rolls up commits since the previous tag; base 09d1551)_

## v1.0.0 — 2026-07-13

First formally versioned release — baselines the live game and turns on
version-per-deploy tracking.

- Versioning system: `config/version` in project.godot (shown on the login screen),
  `deploy/release.sh` (bump + tag + push), CI builds a `:vX.Y.Z` image per release tag,
  and this changelog.
- UI: the player-configurable modular HUD (13 modules, F2 edit mode) + full menu-theming
  pass on the sports-tech pattern, fully-opaque data windows, schematic minimap.
- Polish: character sheet → sectioned cards; ability-tooltip / class-preview colors
  centralized into `Palette` semantic tokens.
