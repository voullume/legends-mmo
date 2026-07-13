# Legends MMO architecture analysis (current-state report)

Analysis date: 2026-07-12

## Scope and confidence

This report maps the checked-out Godot project without changing gameplay code. It is based on `project.godot`, runtime scripts, SQL migrations, deployment files, tests, and existing documentation. The live Supabase schema and deployed zone were not queried, so migration application state, secrets, certificates in production, and runtime infrastructure remain unverified.

The worktree already contained unrelated untracked files, including `docs/PROJECT_ARCHITECTURE.md`; this report does not assume those files are committed or deployed. “Obsolete” below means demonstrably stale documentation or a candidate with no current runtime reference, not permission to delete it.

## Executive summary

Legends MMO is one Godot 4.6 project that boots into several products from a single scene:

- an account-backed local game;
- an unauthenticated practice sandbox;
- an online client; or
- a headless authoritative zone server.

The online authority direction is fundamentally sound. Clients send intent through a path-stable RPC façade; the server binds calls to the remote peer, validates them, advances `shared/Sim.gd` at 30 Hz, and sends interest-filtered snapshots. Supabase Auth establishes identity. The dedicated server holds the service-role key, loads player records, owns gameplay/economy writes, and uses database functions for the most important currency/item exchanges.

The principal architectural hazard is concentration: `client/Client.gd` (about 3.5k lines), `client/NetClient.gd` (about 5.6k), `server/Server.gd` (about 4.8k), and `server/ServerRepo.gd` (about 0.5k) contain most orchestration, domain rules, UI, networking, and persistence. The next largest risks are local/online divergence, online clients reading inventory directly from Supabase, asynchronous login without an explicit ready state, unversioned database deployment state, unauthenticated peers with no visible authentication deadline, and hard-coded deployment identity/configuration.

Recent stabilization work materially improves the older architecture picture:

- `shared/NetTrust.gd` pins the zone certificate in normal clients and fails production closed on plaintext/missing persistent server credentials.
- `shared/Protocol.gd` gates authentication on a shared protocol version.
- `server/Server.gd` rejects a second active peer for the same character.
- `server/ServerRepo.gd` separates privileged server methods from the public client adapter.
- `20260714000000_stab_atomic_economy.sql` supplies transactional, idempotent economy operations and an operation ledger.

These controls are code-level facts; they still depend on correct exports, environment variables, and applied migrations.

## Top-level runtime map

| Layer | Main files | Responsibility |
|---|---|---|
| Bootstrap | `project.godot`, `Main.tscn`, `Main.gd` | Select boot mode and construct the runtime object graph |
| Global service | `client/AudioManager.gd` | Only autoload; audio buses, music/SFX, audio settings |
| Account/public data adapter | `client/Account.gd`, `client/Supabase.gd` | Login/signup/refresh, character creation, own-character and own-inventory calls |
| Local client | `client/Client.gd`, `client/Player.gd` | Local simulation host, input, world rendering, UI, FX, local position save |
| Online client | `client/NetClient.gd` | Extends local client; sends commands, predicts/renders snapshots, online feature UI |
| RPC contract | `client/Net.gd`, `shared/Protocol.gd` | Godot RPC façade and compatibility handshake |
| Transport trust | `shared/NetTrust.gd`, `client/zone_cert.pem` | Production/development DTLS and plaintext policy |
| Zone authority | `server/Server.gd` | Sessions, worlds, fixed-step simulation, validation, social/gameplay services, snapshots |
| Server persistence | `server/ServerRepo.gd` | Service-role and token-scoped server queries; atomic economy RPC wrapper |
| Shared simulation/domain | `shared/GameData.gd`, `Sim.gd`, `Abilities.gd`, `Combat.gd`, `AI.gd`, `Geom.gd`, `Rng.gd`, `World.gd`, `Quests.gd` | Content, combat transitions, AI, geometry, maps, quests |
| Database | `supabase/migrations/*.sql` | Tables, RLS/grants, guards, constraints, progression functions, economy transactions |
| Deployment | `Dockerfile`, `fly.toml`, `deploy/`, `export_presets.cfg`, `play.sh` | Server image/hosting, client exports, local launcher |
| Verification/tooling | `tools/*.gd`, `TESTING.md` | Smoke, balance, authority, session, trust, protocol, and economy tests |
| Content/assets | `models/`, `audio/`, `data/decals/` | Imported models/textures/audio and authored decoration JSON |

## Entry points and object graphs

Godot always starts `Main.tscn`. Its only node runs `Main.gd`, whose `_ready()` merges normal and user command-line arguments and selects the runtime.

| Boot mode | Selection | Constructed graph | Effective authority |
|---|---|---|---|
| Dedicated zone | `--server` | `Main/Net`, `Main/Supa` (`ServerRepo`), `Main/Server` | Server owns simulation and persistence |
| Explicit online | `--online [host]` | `Account`, then `Main/Net`, `Main/Client` (`NetClient`) with child `Supa` | Remote zone owns gameplay; client owns credentials/presentation |
| Exported public client | no args outside editor and `PUBLIC_HOST` set | Same as explicit online; DTLS forced | Remote zone owns gameplay |
| Account local | no args from editor/source | `Account`, then `Client` with child `Supa` | Client owns local simulation and saves location |
| Practice | `--practice` | `Client` only | Client owns ephemeral local simulation |

Other meaningful flags are `--port`, `--bind`, `--dtls`, development-only `--insecure`, `--insecure-dtls`, `--token`, and `--refresh`, plus automation flags such as `--autowalk` and screenshot capture.

There is no separate server scene/project. The server and client scripts/assets are in the same Godot resource pack/container; confidentiality of the service-role key depends on loading it only from the server environment, never on file separation.

### Autoloads and global classes

`AudioManager` is the only configured autoload. All networking, account, repository, client, and server nodes are manually created by `Main.gd`. UI helpers (`Palette`, `Widgets`, `UITheme`, `WorldUI`) are globally registered script classes rather than autoloaded stateful services.

### Path-sensitive construction

Both online sides create the RPC node at `/root/Main/Net`. Godot high-level RPC matching makes that node path, each RPC name/signature, annotation, transfer mode, and payload meaning part of the network contract. `Protocol.VERSION` detects declared incompatibility, but it works only if developers bump it when making a breaking change.

## Major systems

### Shared simulation

`shared/Sim.gd` is the central state-transition engine. It depends on deterministic `Rng`, content/stat definitions in `GameData`, geometry, combat, abilities, and AI. State is primarily nested dictionaries. A controlled fighter consumes an intent dictionary: `Player.gd` supplies it locally, while `Server.gd` converts network commands into the same seam online.

This shared seam is the best-defined architectural boundary in the project. It reduces combat-rule drift between practice/local and online play, but it does not unify spawning, timing orchestration, persistence, progression, portals, social systems, or online validation.

### World and content

`shared/World.gd` defines map IDs, spawns, portals, obstacles, instance templates, and fallback decoration. `data/decals/<map>.json` overrides fallback decal data when present. The client renders that authored content and the server derives corresponding collision from it. Private locker decoration is a separate system: owned build inventory rows and transforms are loaded by the server and exposed in snapshot metadata.

`GameData.gd` is the principal code-defined content database for classes, abilities, mobs, stats, unlocks, talents, and related constants. `Quests.gd` separately defines quest content/rules. Server economy, loot, camps, bounties, residents, and leaderboard constants remain embedded in `Server.gd`.

### Local client and presentation

`Client.gd` is simultaneously:

- a base presentation class for the online client;
- a complete local game/simulation host;
- a 3D world and HUD builder;
- asset/animation/FX/audio integration;
- developer decoration authoring; and
- local position persistence.

Most scene/UI structure is built dynamically rather than authored as `.tscn` resources. This makes reuse quick but reduces editor validation and makes feature ownership difficult to see.

`NetClient.gd` inherits all of `Client.gd` and adds networking, interpolation/prediction, snapshot caches, reauthentication, disconnect/logout UI, and most MMO feature presentation (inventory/equipment, chat, party, quests, shop, forge, bounties, camps, cosmetics, talents, paragon, leaderboards, admin, and locker building).

### Zone server

`Server.gd` owns one simulation dictionary per static world and creates private instance worlds on demand. It runs a fixed 30 Hz simulation step with bounded catch-up, then builds per-peer interest-filtered snapshots. It also owns authentication/session claims, player/mob/resident lifecycle, portals, parties/chat, loot, inventory/equipment, economy, progression, quests/bounties, camps, cosmetics, leaderboards, admin commands, persistence scheduling, and operational health logging.

Snapshots use unreliable ordered delivery for frequent state and reliable RPCs for assignments, results, catalogs, and state changes. Quasi-static metadata is hash/change detected and resent on a heartbeat so one dropped packet does not permanently strand client state.

### Persistence adapters

`client/Supabase.gd` now contains the public adapter: the embedded anon key, email/password auth, token refresh, the user's character operations, and RLS-scoped inventory reads.

`server/ServerRepo.gd` extends that class and adds `service_key` plus every privileged server query/write. It also wraps Postgres economy functions, generating idempotency keys in `Server.gd` and retrying one transport-ambiguous request with the same operation ID. This is a useful logical split, although inheritance still gives the privileged adapter the entire public auth API.

## Networking and authentication flow

### Connection/authentication sequence

1. `Account.gd` authenticates directly against Supabase Auth and owns access/refresh tokens in a `Supabase.gd` node.
2. `Main.gd` creates ENet. Exported public clients force DTLS; source/editor connections obey the trust policy in `NetTrust.gd`.
3. Normal DTLS clients load and pin `client/zone_cert.pem`, verifying the expected `legends-zone` common name. Production servers require a persistent certificate/key and refuse plaintext.
4. Client and server both place `Net.gd` at `/root/Main/Net`.
5. On connection, `NetClient` calls `authenticate` with the short-lived access token and `Protocol.hello()`.
6. Server checks the protocol before doing token/database work, then resolves the character through a token-scoped Supabase query.
7. Server atomically claims the character in `_char_peer`; a second live connection for that character is rejected.
8. Server creates the fighter/session, sends the fighter ID/catalogs, and asynchronously loads materials, progression, rested XP, cosmetics, equipment, quests/bounties, season state, and admin status.
9. Roughly every 25 minutes the client refreshes locally and sends a replacement access token. The server resolves it and accepts it only if it maps to the already-bound character.

The refresh token stays client-side during the normal protocol. Development CLI token injection is explicitly disabled in exported builds.

### Command/state sequence

```text
physical input
  -> Player intent collection in NetClient
  -> /root/Main/Net RPC (movement, ability, or feature command)
  -> remote-sender peer identity
  -> Server session/rate/shape/proximity/ownership validation
  -> shared Sim or an asynchronous server service workflow
  -> in-memory authoritative state + Supabase mutation where needed
  -> interest-filtered snapshot or reliable result RPC
  -> NetClient cache/prediction/reconciliation
  -> Client rendering, UI, audio, and FX
```

Movement is client-capped and server-clamped/normalized. Ability presses are reliable, sequence-numbered, deduplicated, and checked against unlock state. Server RPCs derive identity from `multiplayer.get_remote_sender_id()` through `Net.gd`; payloads do not choose their own peer identity.

### Protocol boundary

`client/Net.gd` is the canonical public network surface (roughly 60 command/result methods). `shared/Protocol.gd` makes compatibility explicit, but snapshot dictionaries and feature payloads remain informal schemas. Additive optional fields can coexist; required field/semantic changes require a version bump and coordinated server-first deployment.

## Database/server boundary

### Trust roles

- The Supabase anon key is embedded in `client/Supabase.gd`; this is public by design. RLS, grants, triggers, constraints, and function permissions provide security.
- Player access tokens authorize account creation/own-row operations and are also used by the server for some owner-scoped reads.
- `SUPABASE_SERVICE_KEY` exists only on the runtime `ServerRepo` instance and bypasses RLS. Production boot checks that it can read the inventory table and schedules shutdown if missing/invalid.
- Atomic economy functions are `SECURITY DEFINER`, revoke public/anon/authenticated access, and grant execute to `service_role`.

### Domain ownership

| Domain | Direct client capability | Zone/server capability |
|---|---|---|
| Auth/session tokens | Signup/signin/refresh | Validate access token through owner-scoped character lookup |
| Character identity | Create/read own one-character row | Load identity/class; bind it to a peer |
| Location | Local mode patches own allowed location fields | Online mode validates/restores position and saves location |
| Combat/world state | Render and predict only online | Exclusive online simulation authority |
| Inventory | Read own rows directly | Exclusive mutations; derives equipment stats and ownership |
| Credits/tokens/materials | Display mirrored values | Awards/debits and authoritative persistence |
| Progression/quests/cosmetics | Mostly receives server state; some own reads exist through adapter | Validates and writes, often through guarded DB functions |
| Admin/leaderboards/reports | Requests through game RPC | Privileged reads/writes and filtered responses |

### Transaction model

The latest migration introduces `economy_ops` plus transactional functions for awards, purchases, bulk sell/salvage, forge operations, crafting, cosmetics, locker unlock, and talent respec. Each operation locks the character, checks a server-generated UUID, records the result, and safely returns the original result on retry. Production refuses legacy economy operations when the functions are unavailable.

Other database workflows use a mix of atomic functions, guarded conditional PATCHes, and multi-call application workflows. Therefore “economy is atomic” should not be generalized to every progression, equipment, quest, builder, leaderboard, or logout write. The live database must have every migration applied in filename order for the intended boundary to hold.

Important deployment caveat: the analysis date is 2026-07-12, while migrations named `20260713000000_leaderboard_seasons.sql` and `20260714000000_stab_atomic_economy.sql` are future-dated. The filenames are ordering keys, not evidence that those migrations are live. Production code already expects the latter and fails economy operations closed until its probe succeeds.

## Player data flow

### Account creation

1. `Account.gd` constructs `Supabase.gd` and signs in/up.
2. It reads the account's character; if absent, it inserts name/class.
3. Database defaults/guards establish protected progression values.
4. `Account` emits `entered(supa, character)`.
5. `Main.gd` reparents the live `Supa` node beneath the selected client before removing the account UI, preserving tokens without copying the refresh token into networking code.

### Online load/play/save

1. The server resolves the token to a character and acquires the single-active-session claim.
2. It clamps loaded values, creates a fighter, and establishes session dictionaries.
3. It immediately assigns the fighter and then progressively loads related rows.
4. Equipment is re-read server-side and converted into authoritative derived stats.
5. During play, combat/position live in server memory; persistence workflows update Supabase and reconcile session mirrors.
6. Currency awards are bucketed and flushed through idempotent delta functions. Disconnected in-flight award packets enter an orphan retry queue.
7. Every 15 seconds and on disconnect, the server saves relevant state. Instance keys are normalized before persistent location is written.
8. Graceful logout closes ENet, triggering peer-disconnect cleanup/save, then reloads the root scene to destroy token-bearing nodes.

There is an observable partial-load window: fighter assignment occurs before all awaited data loads finish. Most continuations guard `_session.has(pid)`, but there is no explicit `AUTHENTICATING -> LOADING -> READY` state that blocks commands/snapshots until the complete player aggregate is ready.

### Local/practice flow

Local mode creates the shared sim in `Client.gd`, and `Player.gd` writes directly into the controlled fighter's intent dictionary. Account local mode restores and patches position using the player's token; practice mode has no persistence. Neither route exercises online session claims, protocol compatibility, server validators, snapshot transport, economy functions, asynchronous aggregate loading, or server saves.

## Dependencies and operational assumptions

### Runtime/build dependencies

- Godot 4.6 project format; Docker defaults to `4.6.3-stable`.
- GDScript only; no language package manager or conventional dependency manifest.
- Godot high-level MultiplayerAPI/ENet and DTLS.
- Supabase Auth, PostgREST, and PostgreSQL functions at a hard-coded project URL.
- Runtime/imported GLB, PNG, audio, `.res`, and JSON assets.
- Server environment: `SUPABASE_SERVICE_KEY`; production DTLS certificate/key paths or PEM contents; optional bind/port.
- UDP 7777 and a directly reachable zone host; no gateway, relay, lobby, or matchmaking service.
- Docker build-time network access to Debian mirrors and GitHub's Godot release artifact.

### Coupling graph

```text
Main
├── Account -> public Supabase adapter
├── Client -> Player + Sim + World + presentation
├── NetClient -> Client + Net + public Supabase adapter + Protocol
└── Server -> Net + ServerRepo + Sim + World + Quests + NetTrust + Protocol

Sim -> GameData + Geom + Combat + Abilities + AI + Rng
Abilities/AI/Combat/Geom -> GameData and combat/geometry helpers
ServerRepo -> public Supabase adapter -> Supabase HTTP APIs
ServerRepo -> Postgres functions/migrations (runtime contract)
```

## Findings

## 1. Architectural risks

### High

1. **Four concentrated change hotspots.** Client base, online client, server, and server repository combine unrelated features and state. A feature change commonly crosses thousands of lines, informal dictionaries, RPCs, and SQL. This increases merge conflicts, hidden coupling, and regression scope.
2. **Local/editor success is weak evidence for online correctness.** F5/source defaults to an account-backed local architecture while exports default online. Local mode bypasses the authority, protocol, timing, persistence, and failure paths that matter in production.
3. **No explicit player readiness state.** The server exposes a session/fighter before the aggregate is fully loaded. Commands or snapshots can observe defaults for materials, progression, equipment, quests, cosmetics, and admin state; load failures do not converge through one readiness/error policy.
4. **Online data authority has a split read model.** `NetClient.gd` calls `supa.get_inventory()` from multiple UI workflows while the zone independently reads/mutates the same inventory. RLS protects ownership, but stale reads, timing races, extra credentials-to-database exposure, and duplicated DTO interpretation remain.
5. **Database schema deployment is an implicit runtime dependency.** There is no checked-in generated schema snapshot/version handshake with the zone. Boot probes cover service-key access and atomic economy only; other missing/out-of-order functions/columns may surface after players connect.
6. **Unauthenticated connection lifecycle is under-specified.** Connected peers wait for auth, but no authentication deadline or explicit unauthenticated peer cap/rate limiter is visible in `Server.gd`. ENet's finite peer slots can therefore be held by clients that connect and never authenticate, creating a straightforward availability risk.

### Medium

7. **Dictionary schemas are pervasive and informal.** Fighters, worlds, sessions, items, RPC payloads, snapshots, and DB results are mutable dictionaries. Type/key/semantic drift is detected mainly at runtime.
8. **Protocol safety depends on manual discipline.** `Protocol.VERSION` is valuable but does not calculate compatibility. A forgotten bump still permits incompatible client/server builds.
9. **Single-process vertical scaling.** Every zone, instance, resident, simulation tick, snapshot, and async persistence continuation shares one Godot main loop. There is no zone lease, cross-process session routing, or horizontal social-state layer.
10. **Configuration is embedded or loosely environmental.** Public host IP, Supabase URL/anon key, certificate CN/path, port defaults, and export behavior are spread across scripts/config/deployment. Environment identity mistakes can point a build at the wrong database/server.
11. **Dynamic scene/UI construction reduces static validation.** Most presentation structure is procedural. Ownership/layout/resource errors require running the correct branch and viewport.
12. **Privileged repository inherits the public auth client.** The split is substantially safer than the old combined adapter, but inheritance makes inappropriate public-account methods available on the service-role object and keeps HTTP/error semantics coupled.
13. **Persistence remains mixed.** Atomic economy is strong, but logout state, equipment, progression, builder, quest, and leaderboard operations use several concurrency patterns. Each must be audited independently rather than relying on one global transaction model.
14. **Graceful disconnect is not a durability guarantee.** Periodic saves limit loss, and award retries help, but process death can still occur between in-memory state change and durable writes. Some disconnect persistence calls are intentionally fire-and-forget.

## 2. Duplicate or conflicting systems

1. **Two simulation hosts:** `Client.gd` hosts local/practice simulation; `Server.gd` hosts online simulation. Combat transitions share `Sim.gd`, but lifecycle, spawn, persistence, world services, and validation differ.
2. **Two input adapters:** `Player.gd` writes local intent; `NetClient.gd` serializes similar intent/ability commands. Key mapping, targeting, cadence, and gating can drift.
3. **Two location persistence paths:** local client-token `save_character()` versus zone service-role `save_character_as()`. Keeping direct location writes supports local mode but broadens the production database surface.
4. **Two online inventory readers:** the client reads its RLS-owned inventory for UI, and the server reads it for authority/equipment. Mutation notifications reduce staleness but do not make one canonical read model.
5. **Two decoration sources:** fallback arrays/constants in `World.gd` and overriding `data/decals/*.json`. This is intentional, but edits to the fallback can appear ineffective when JSON exists.
6. **Mirrored calculations:** forge price functions in `NetClient.gd` explicitly “MUST match” server calculations. Other display catalogs/caps are partly pushed by the server and partly duplicated in client/shared constants, yielding inconsistent ownership.
7. **Legacy item fields coexist with the deeper item model:** server comments retain `bonus_*` alongside `primary_*` for compatibility. This transitional shape increases branching and should have a removal version/date.
8. **Settings are shared across several owners:** audio and client/UI systems read/write sections of `user://settings.cfg`. This relies on every writer preserving unrelated sections.
9. **Documentation conflicts:** `README.md` still calls the project a Phase 1 scaffold/server skeleton, while current code implements the full online zone and stabilization layers. `deploy/README.md` still says DTLS does not verify server identity, which conflicts with current certificate pinning in `NetTrust.gd`.

## 3. Security and authority problems

### Confirmed/current concerns

1. **Unauthenticated peer exhaustion:** no visible auth timeout means transport slots can be consumed without completing authentication.
2. **Player access tokens cross two trust boundaries:** account clients talk directly to Supabase and send the access token to the zone. Pinned DTLS protects the normal exported path, but source/editor development overrides can intentionally allow plaintext or unverified DTLS. Real credentials must never be used with those overrides.
3. **Location remains client-writable for local-mode compatibility.** Database guards pin progression/economy columns, and the server defensively validates maps/gates/positions, but any client-writable field must be assumed attacker-controlled during online restore.
4. **Service-role blast radius is broad.** A compromise of the zone process/environment grants the generic `ServerRepo` extensive database access. SQL functions narrow individual operations, but the process still possesses a key that bypasses RLS.
5. **Direct online client inventory reads bypass the game-server API boundary.** They are ownership-scoped by RLS, not an immediate privilege escalation, but they increase database exposure and make server/client authorization models overlap.
6. **Boot readiness is asynchronous.** `start()` begins service-key and economy probes without awaiting a unified ready gate. Production eventually quits/refuses unsafe economy, but a transport can begin accepting peers before every dependency check completes.
7. **CLI credential injection remains a development footgun.** Command-line access/refresh tokens can be visible to process inspection and shell history. Exported builds reject token injection, which limits the exposure.
8. **Database hardening is migration-order dependent.** Early migrations are permissive and later ones revoke inventory writes/pin columns. A partially migrated environment can have a much weaker authority boundary than the current source implies.
9. **No external abuse perimeter is visible.** The zone is a direct UDP endpoint with in-process rate limits but no gateway-level connection throttling, IP reputation, DDoS protection contract, or authentication admission service represented in the repository.

### Strong controls already present

- Production server refuses plaintext and missing/invalid persistent DTLS configuration.
- Normal clients pin a public certificate and expected common name; exported clients fail closed.
- RPC identity is derived from the remote sender, not a client-provided player ID.
- Protocol compatibility is checked before token/database work.
- Reauthentication must resolve to the same character.
- One active peer per character is claimed without an `await` race window.
- Movement, ability sequence/unlocks, proximity, ownership, admin status, and many payloads are revalidated server-side.
- Chat/economy/social actions generally have cooldown and/or in-flight guards.
- Inventory client mutations are revoked by later migrations; protected character columns are pinned for non-service-role calls.
- Critical economy operations are transactionally guarded, service-role-only, and idempotent by operation UUID.
- Item mutations commonly scope by both item ID and character ID, and conditional updates prevent duplicate state transitions.

## 4. Files that appear obsolete or transitional

Do not delete these based only on this report; verify ownership/history and run exports/tests first.

| File/group | Assessment | Evidence/action |
|---|---|---|
| `README.md` | Obsolete status/quick-start text | Says Phase 1/scaffold/server later, contradicting current implemented server and online systems; rewrite first |
| `deploy/README.md` security reminder | Obsolete security statement | Claims DTLS lacks identity verification; current normal path pins `zone_cert.pem` and expected CN |
| `HANDOFF.md` and many `docs/*-kickoff.md` / `*-handoff.md` | Historical/transitional, not runtime docs | Valuable provenance but easy to mistake for current architecture; move under a clearly labeled history area or add banners/index |
| `docs/PROJECT_ARCHITECTURE.md` | Untracked prior report | Not currently tracked and contains superseded claims about unsafe DTLS, missing protocol version, multi-session races, and combined Supabase adapter; retain only as dated history if desired |
| Legacy `bonus_*` item fields and compatibility branches (code/schema, not a single file) | Transitional | Server explicitly says they are kept for one release; define the removal migration/protocol version before deleting |
| Local account-backed mode in `Client.gd` | Potentially obsolete product path, not dead code | It is still the source/editor default and justifies client-writable location. Decide product intent before removal |
| Fallback decals in `shared/World.gd` for maps with JSON | Shadowed candidates | Runtime JSON takes precedence; retain only if fallback/test/dev behavior is intentional |
| Old balance/smoke/tuning scripts in `tools/` | Candidate archive set | They are manual entry points and not runtime-referenced. Classify by current CI/runbook coverage before pruning |
| `.uid` files | Not obsolete by default | Godot metadata; untracked `.uid` files likely accompany new scripts and should be handled consistently, not bulk-deleted |
| `docs/ideas-not-in/` | Deliberately non-runtime | Name indicates rejected/unimplemented material; keep outside production export or archive if repository size matters |

No core runtime `.gd` file was conclusively dead: every script under `client/`, `server/`, and `shared/` is reached from bootstrap/runtime code or an active domain dependency.

## 5. Safest implementation order for future work

The safest sequence is boundary-first and behavior-preserving. Do not begin by splitting the large scripts while authority/readiness contracts are still implicit.

1. **Freeze and verify the current baseline.** Apply all migrations to a clean disposable database, record the actual schema version, run import/parse plus stabilization and gameplay smoke suites, and capture local/online golden flows. Update README/deployment truth so engineers launch the right mode.
2. **Add admission/readiness states.** Introduce server boot `STARTING -> READY -> FAILED` and peer `CONNECTED -> AUTHENTICATING -> LOADING -> READY -> DISCONNECTING` states. Await dependency probes before accepting gameplay, add authentication/load deadlines, cap unauthenticated peers, and reject commands before `READY`.
3. **Make database compatibility explicit.** Add one schema-version function/table checked at server boot, fail production closed on mismatch, and document a server-first/database-first rollback-compatible deployment sequence. Treat the future-dated atomic migration as required infrastructure, not optional source.
4. **Lock down regression tests around boundaries.** Test auth timeout, duplicate login, reauth identity, command-before-ready, disconnect during every awaited load/economy operation, migration mismatch, idempotent retries, snapshot compatibility, and client/server version mismatch.
5. **Choose the local-mode product policy.** Either keep it as an explicit offline product with documented divergence, or make editor F5 connect to a local authoritative zone. Only after that decision should client-writable location and the second persistence/input orchestration path be removed or formalized.
6. **Move online reads behind the zone.** Have the server provide canonical inventory/equipment DTOs and revisions; stop `NetClient` from querying Supabase during online play. Keep Supabase direct access in account/login only (and explicitly in offline mode if retained).
7. **Extract typed contracts before feature services.** Define validated item, session, snapshot, intent, and DB-result schemas/builders at current seams. Centralize shared calculations such as forge costs and remove “MUST match” copies. Bump protocol only where compatibility actually breaks.
8. **Decompose the server incrementally.** Extract one service at a time behind tests: admission/session registry, snapshot publisher, persistence coordinator, inventory/economy, social/party/chat, progression/quests/bounties, instances/world director. Keep `Server.gd` as composition root until behavior is stable.
9. **Decompose presentation incrementally.** Separate local simulation host from reusable renderer, then extract online feature controllers/views from `NetClient.gd`. Prefer small scenes/resources for UI that benefits from editor validation.
10. **Narrow privileged database access.** Favor dedicated service-role-only functions for authoritative operations; separate server auth validation/read repositories from mutation repositories. Consider a narrower backend credential/API when operational maturity requires it.
11. **Externalize environment profiles.** Define dev/staging/production configuration for Supabase project, zone host, certificate pins, port, protocol build ID, and feature flags. Add safeguards that prevent a dev client/server from reaching production data accidentally.
12. **Archive proven-obsolete material last.** Once docs, tests, exports, and runtime reference checks agree, archive historical handoffs/tools and remove compatibility fields/fallbacks through explicit migrations and protocol/version windows.

## Practical change rules until refactoring

- Treat `/root/Main/Net`, every `@rpc` signature/annotation, `Protocol.VERSION`, and snapshot meaning as one deployable contract.
- Treat Supabase migrations and `ServerRepo.gd` callers as one deployable contract; source presence does not mean the database is ready.
- Never trust restored/client-readable values merely because they came from Supabase; validate again at the zone boundary.
- Do not add a new currency/item exchange as multiple REST calls. Add an idempotent transactional database function and test retry ambiguity.
- Do not add online-only state to local `Client.gd` merely for reuse; prefer a shared pure helper or explicit presentation component.
- Do not add another direct Supabase read to `NetClient.gd`; route new online data through the authoritative server.
- Any new awaited login step must handle disconnect and must participate in the future readiness gate.
- Keep service-role secrets out of project resources, exports, logs, command lines, and client-visible error payloads.

## Validation gaps for the next audit

The following cannot be concluded from repository inspection alone:

- which migrations are applied to each live Supabase environment;
- whether current RLS/grants exactly match a clean migration replay;
- whether the deployed server certificate matches the pinned client certificate and rotation procedure;
- whether Fly/VPS UDP behavior and supervisor restarts match documentation;
- capacity under real player/snapshot/DB latency;
- whether all manual `tools/` scripts pass against Godot 4.6.3 and a disposable database;
- whether export filters unintentionally package development/history/source-only assets.

Those checks should be completed before security certification, destructive cleanup, or large gameplay expansion.
