# Changelog

Every deployed version of Legends MMO, newest first. Each `vX.Y.Z` has a matching
git tag and a `ghcr.io/voullume/legends-mmo:vX.Y.Z` image — exact saved copies of
what shipped. Cut a new version with `deploy/release.sh [patch|minor|major] "note"`.

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
