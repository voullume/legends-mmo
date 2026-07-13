# Legends MMO Project Architecture

Analysis date: 2026-07-11

This document describes the repository as it exists now. It is an inspection report, not a target architecture. No live Supabase schema or deployed server was inspected, so database conclusions are based on the checked-in migrations and callers.

## Executive summary

Legends MMO is a Godot 4.6 project with a single scene entry point and two substantially different runtime architectures:

- **Online mode** is a server-authoritative MMO prototype. A headless Godot process owns all simulation and most progression/economy decisions, accepts player intents over ENet RPC, and persists through Supabase REST using a server-only service-role key.
- **Local/account mode** runs the same simulation inside the client and writes position directly to Supabase using the player's token. Practice mode is the same local client without an account.

The design has a sound authority direction online: clients submit commands, the server validates and simulates them, and clients render snapshots. The principal risks are concentration of almost every concern in three very large scripts, divergence between local and online behavior, non-atomic multi-request economy updates, unauthenticated server identity under the current DTLS setup, direct database reads from online clients, and a migration history whose final security posture is difficult to audit without applying it to a clean database.

## Repository map

| Area | Primary files | Responsibility |
|---|---|---|
| Bootstrap | `project.godot`, `Main.tscn`, `Main.gd` | Select runtime mode; construct client, RPC bridge, account UI, or dedicated server |
| Global service | `client/AudioManager.gd` | Only configured autoload; music/SFX buses and persistent audio settings |
| Local client | `client/Client.gd`, `client/Player.gd` | In-process simulation, input, rendering, world construction, UI, FX, local position persistence |
| Online client | `client/NetClient.gd` | Extends `Client`; sends inputs, consumes snapshots, implements online systems/UI, reads player-owned data from Supabase |
| Network contract | `client/Net.gd` | Path-stable RPC façade shared by server and clients |
| Dedicated server | `server/Server.gd` | Authentication, world ownership, fixed-step simulation, validation, sessions, social systems, economy, persistence, snapshots |
| Shared domain/sim | `shared/GameData.gd`, `Sim.gd`, `Abilities.gd`, `Combat.gd`, `AI.gd`, `Geom.gd`, `Rng.gd`, `World.gd`, `Quests.gd` | Content definitions, deterministic combat, world topology, collision, quests |
| Persistence adapter | `client/Supabase.gd` | Auth and PostgREST wrapper used by both client and server despite its directory/name |
| Database | `supabase/migrations/*.sql` | Supabase/Postgres schema, RLS, guard triggers, constraints, and atomic RPC functions |
| Deployment | `Dockerfile`, `fly.toml`, `deploy/`, `play.sh`, `export_presets.cfg` | Headless image, Fly/VPS configuration, local launch modes, client exports |
| Tests/tools | `tools/*.gd`, `TESTING.md` | Headless smoke, balance, collision, instancing, resident, and builder checks |
| Assets/content | `models/`, `audio/`, `data/decals/` | Runtime GLBs, textures, audio, and authored map decoration JSON |

The current concentration is material: `client/Client.gd` is about 3,506 lines, `server/Server.gd` about 4,361, and `client/NetClient.gd` about 5,547. These three scripts contain most rendering, UI, orchestration, domain services, and persistence workflows.

## Entry points and boot modes

Godot starts `Main.tscn`, whose only node runs `Main.gd`. `Main.gd::_ready()` combines engine and user command-line arguments and chooses a mode:

| Mode | Selection | Object graph | Data/authority model |
|---|---|---|---|
| Dedicated zone | `--server` | `Main/Net` + `Main/Supa` + `Main/Server` | Server owns worlds and sim; service-role Supabase writes |
| Explicit online | `--online [ip]` | Account UI, then `Main/Net` + `Main/Client` (`NetClient`) + child `Supa` | Remote server owns sim; client sends intent and renders snapshots |
| Exported public client | no args, non-editor, `PUBLIC_HOST` nonempty | Same as online, fixed IP, DTLS forced | Same as online |
| Account-backed local | no args in editor/source | Account UI, then `Client` + child `Supa` | Client owns sim; client token saves position |
| Practice | `--practice` | `Client` only | Client owns sim; no account or persistence |

Additional flags include `--port`, `--bind`, `--dtls`, debug `--token`/`--refresh`, `--autowalk`, and screenshot automation.

There is no separate server scene or separate Godot project. The same project and root scene are shipped into the container, and `--server` selects the headless branch at runtime.

### Autoloads

`AudioManager` (`client/AudioManager.gd`) is the only `[autoload]` entry. Everything else is instantiated manually by `Main.gd`. The global UI helper classes (`Palette`, `Widgets`, `UITheme`, `WorldUI`) use `class_name` but are not autoloads.

## Major systems

### Shared deterministic simulation

`shared/Sim.gd` is the central state-transition engine. It depends on `Rng`, `GameData`, `Geom`, `Combat`, `Abilities`, and `AI`. The state is dictionary-based rather than a typed domain model. Controlled fighters consume an intent seam; local `Player.gd` writes that intent directly, while online `Server.gd` translates peer input into the same shape.

- `GameData.gd`: classes, abilities, stats, mobs, balance/content constants.
- `Abilities.gd` and `Combat.gd`: ability execution and damage/event pipeline.
- `AI.gd`: target selection and bot/mob behavior.
- `Rng.gd`: deterministic RNG.
- `Geom.gd`: arena geometry helpers.
- `World.gd`: maps, portals, spawn points, obstacles, instances, and decal collision loading.
- `Quests.gd`: quest definitions and progression rules.

This is the cleanest architectural seam in the repository: both local and server modes use the same simulation code.

### Client rendering and presentation

`Client.gd` is both the base renderer and the complete local game. It dynamically constructs the 3D world and HUD; there are few authored scenes. It also owns mesh/animation loading, camera, pooled FX, UI widgets, local input integration, decorator authoring, audio/FX settings, and local save behavior.

`NetClient.gd` inherits the entire class and overrides the mode-specific loop. It adds online input transport, prediction/reconciliation, snapshot caching, disconnect and reauthentication behavior, inventory/equipment UI, shops, forge, parties, chat, quests, bounties, instances, locker building, cosmetics, talents, paragon, leaderboards, and admin UI.

Inheritance gives both modes identical rendering helpers, but also couples online behavior to all local-client state and protected/private-by-convention methods.

### Server world and gameplay services

`Server.gd` owns multiple independent simulation states, one per world/map plus private instances. It runs at a fixed 30 Hz step, with a maximum catch-up of five steps per physics frame. It owns:

- peer authentication and in-memory sessions;
- player spawning, movement, abilities, portals, and respawns;
- world/mob/resident simulation and private instances;
- parties, chat, loot rolls, admin commands;
- inventory, equipment, shop/vendor, forge/crafting;
- quests, bounties, progression, rested XP, talents/paragon;
- cosmetics, leaderboards, locker/build mode;
- periodic/disconnect saves and interest-managed snapshots.

Snapshots are sent per peer. Dynamic state and party data are frequent; quasi-static `meta` is hash/change-detected and resent on a heartbeat. Movement snapshots are `unreliable_ordered`; assignments, inventory notifications, and system results are reliable.

### World authoring

World topology and fallback decals live in `shared/World.gd`. Authored decoration JSON in `data/decals/<map>.json` takes precedence at runtime. `Client.gd` includes an in-game decorator that writes those project files in development. The server loads collision corresponding to the same decal JSON. Locker-room decoration is different: it is owned inventory data persisted in Supabase and delivered in snapshot metadata.

## Networking flow

### Connection and authentication

1. Account UI authenticates directly with Supabase Auth and retains access and refresh tokens in a `Supa` node.
2. `Main.gd` creates an `ENetMultiplayerPeer`. With `--dtls`, the client calls `TLSOptions.client_unsafe()`; the connection is encrypted but the server certificate/identity is not verified.
3. Both processes create `Net.gd` at the exact path `/root/Main/Net`, which Godot high-level RPC routing requires.
4. On connect, `NetClient` sends the short-lived Supabase access token through `Net.authenticate`. The refresh token remains client-side.
5. `Server.authenticate()` asks Supabase for the token owner's character. On success it creates a server session and fighter, then asynchronously loads materials, progression, rested XP, cosmetics, equipment, quests, season state, and admin status.
6. The server sends the assigned fighter ID and initial catalogs/state. Invalid/no-character clients are disconnected.
7. Every 25 minutes the client refreshes with Supabase and sends a new access token. The server verifies that the replacement token resolves to the same character before storing it.

### Runtime command/state flow

```text
Player input
  -> NetClient (camera-relative intent, target IDs, ability sequence)
  -> Net.gd RPC façade
  -> Server.gd validation/rate limit/session lookup
  -> shared/Sim.gd fixed-step state mutation
  -> Server interest filtering + per-peer snapshot/meta
  -> Net.gd receive RPC
  -> NetClient snapshot cache/prediction/rendering/UI
```

Movement is capped client-side to 30 sends/sec and clamped/normalized server-side. Ability messages are reliable and monotonically sequence-numbered, with server deduplication and unlock checks. The server uses `multiplayer.get_remote_sender_id()` rather than accepting a peer ID from payloads, which is the correct identity binding.

Economy/social RPCs follow the same façade but generally invoke async server workflows rather than the deterministic sim. Most have per-player busy flags and cooldowns. The canonical public network surface is the roughly 60 RPC methods in `client/Net.gd`; changing method names, annotations, argument shapes, or the `/root/Main/Net` path is a protocol change.

## Database and server boundaries

### Supabase roles

- The anon key is embedded in `client/Supabase.gd`, as expected for a Supabase client. Security therefore depends on RLS, grants, triggers, and server-side validation—not secrecy of that key.
- Client account/auth flows use the player's access token.
- The dedicated server loads `SUPABASE_SERVICE_KEY` from its environment. The service role bypasses RLS and is used for authoritative writes and restricted reads.
- The server still carries each player's access token for ownership-scoped reads (`get_inventory_as`, progression/cosmetic/quest reads). Service-role writes usually add explicit character/item filters.

### Data ownership by table/domain

| Domain | Client access | Server access/authority |
|---|---|---|
| Auth | Sign up, sign in, refresh directly against Supabase Auth | Validates access tokens indirectly by token-scoped character reads |
| `characters` | Own row create/read; own position fields remain writable for local mode | Persists position, XP, level, credits, tokens, locker state using service role |
| `inventory` | Read own rows for UI | Only writer; service-role insert/update/delete; DB gear cap and shape constraints |
| `materials`, `progression`, `character_cosmetics`, `character_quests` | Read own rows | Service-role writes, often through DB functions |
| `admins`, `leaderboards`, `bot_reports` | No direct privileged path intended | Service-role checks/reads/writes; leaderboards returned through game RPC |

The migrations progressively harden an initially permissive schema. In particular, inventory client write policies are later dropped and grants revoked; character progression columns are pinned by triggers for non-service-role requests; and later features use service-role-only database functions.

### Transaction boundary

The strongest persistence paths are database functions such as material addition, progression unlock/spend/respec, rested XP, paragon, leaderboard submission/rank/claim, and bounty claim. These make related mutations atomic in Postgres.

Other workflows remain application-level sequences of multiple REST calls and absolute-value session saves. Equipment toggle/slot trimming, some purchases/refunds, item creation plus currency changes, and disconnect saves can cross several requests. Busy flags serialize a single process/session, but they are not a database transaction and do not protect against process death, retries, or multiple simultaneous sessions for the same character.

## Player data flow

### Account creation and entry

1. `Account.gd` creates `Supabase.gd`, signs in/up, and calls `get_character()`.
2. A new character is inserted with name/class. Database defaults and insert guards establish safe progression values.
3. `Account` emits `entered(supa, character)`.
4. `Main.gd` reparents the live Supabase node under the selected client so tokens survive removal of the account UI.

### Online load

1. Client sends only the access token to the zone.
2. Server resolves the one-character row and clamps level/currencies on load.
3. Server creates the fighter and an in-memory `_session` record.
4. Related tables are loaded asynchronously.
5. Equipment is read and authoritative derived stats are applied to the fighter.
6. Quest/progression/cosmetic/admin state is incorporated into session state and pushed through reliable RPCs or snapshot metadata.

There is a partial-join interval: the fighter/session is created and assignment is sent before every dependent load finishes. Each continuation checks that the session still exists, but the client can observe progressively populated state.

### Online play and save

- Position/combat state lives in server memory and the shared sim.
- Economy/progression actions update Supabase and then reconcile the in-memory session.
- Server snapshots expose a presentation subset of authoritative state.
- Periodic and disconnect saves write character position/map and progression fields. Private instance map keys are normalized to a safe persistent destination.
- On graceful client logout, `Main.gd` closes ENet so peer-disconnect persistence runs, then reloads the root scene and clears token-bearing nodes.
- A crash or hard server termination can lose changes since the last completed persistence point; not every fire-and-forget async disconnect call is awaited.

### Local mode

`Client.gd` creates and ticks the sim locally, uses `Player.gd` to mutate the controlled fighter intent, restores saved position, and directly patches allowed character position fields with the user's token. It does not exercise the online server validation, progression, economy, interest management, or snapshot code. Practice mode omits Supabase entirely.

## Dependencies

### Runtime

- Godot 4.6 project; Docker currently defaults to Godot `4.6.3-stable`.
- GDScript only; no conventional package manifest or third-party code dependency manager.
- Godot ENet/high-level MultiplayerAPI and optional DTLS.
- Supabase Auth + PostgREST/Postgres at a hard-coded project URL.
- Imported GLB/PNG assets, runtime-loaded animation resources, OGG audio, and JSON decal files.
- Server secret: `SUPABASE_SERVICE_KEY`.
- UDP/7777 by default and a directly reachable host; no lobby, relay, gateway, or matchmaking layer.

### Build/development

- Docker downloads a Godot binary from GitHub at build time and installs Debian runtime libraries.
- `play.sh` assumes `~/.local/bin/godot` unless overridden.
- Asset workflow documentation references external `gltf-transform` and Meshy, but neither is a runtime dependency.

## Findings

### 1. Architectural risks

#### Critical/high

1. **God scripts and change blast radius.** `Server.gd`, `Client.gd`, and `NetClient.gd` combine lifecycle, domain logic, persistence, networking, rendering, and UI. This makes review difficult, encourages shared mutable dictionaries, and makes unrelated feature changes likely to collide.
2. **Local and online modes are behaviorally different products.** The default editor/source path runs local simulation, while exported builds run online. A feature can appear correct under F5 yet bypass all online authority, persistence, timing, and protocol behavior. The README/quick-start language reinforces this trap.
3. **Application-level economy transactions.** Many workflows span several PostgREST operations and in-memory updates. Per-peer busy flags prevent simple click races but cannot guarantee atomicity across crashes, timeouts, retries, or concurrent sessions.
4. **No single-session-per-character lease.** Authentication does not reject a second peer for the same character. Two sessions can hold stale absolute balances/progression and overwrite or race one another despite per-peer locks.
5. **Protocol is implicit and path-coupled.** `Net.gd` is a hand-maintained RPC list with unversioned dictionaries. Server and client must be deployed compatibly, and a node rename/path change can break every call.

#### Medium

6. **Stringly typed, mutable domain state.** Simulation, sessions, snapshots, items, and transforms are dictionaries. Missing keys/type drift are mostly found at runtime and schema ownership is distributed across client/server/constants/SQL.
7. **Content constants are duplicated.** Prices, rarity ranks/multipliers, salvage yields, caps, slot rules, and some formulas are mirrored between `Server.gd`, `NetClient.gd`, `GameData.gd`, and SQL checks. Comments explicitly warn they must match.
8. **Partial asynchronous login.** Assignment occurs before all related rows and equipment are loaded. It is guarded against disconnects, but there is no explicit `AUTHENTICATING -> LOADING -> READY` state or timeout/rollback for partial failures.
9. **Single-process scaling model.** All worlds, players, residents, persistence callbacks, and snapshots share one Godot process/main loop. There is no zone ownership/lease model, gateway, cross-process party/chat, or horizontal session routing.
10. **Persistence adapter location and scope are misleading.** `client/Supabase.gd` contains both public client auth and highly privileged server methods. Correctness relies on `service_key` never being set in a client, and the mixed API makes accidental boundary violations easier.
11. **Dynamic UI/world construction limits editor validation.** Most scene structure is code-generated, so layout, ownership, and resource issues are discovered only by executing relevant branches.
12. **Operational configuration is compiled/hard-coded.** Supabase URL, anon key, public server IP, ports, and public-build behavior live in code/config rather than a typed environment/profile layer.

### 2. Duplicate or conflicting systems

1. **Two simulation hosts:** `Client.gd` hosts a complete local sim; `Server.gd` hosts the online sim. Sharing `Sim.gd` reduces rules drift, but orchestration, spawning, persistence, progression, and world behavior differ.
2. **Two input adapters:** `Player.gd` writes directly to a local intent dictionary; `NetClient.gd` constructs similar movement/ability data for RPC. They are intentionally parallel but can drift in key mapping, targeting, unlocks, and cadence.
3. **Two persistence paths:** local mode calls client-token `save_character`; online mode calls service-role `save_character_as`. Keeping client-writable position columns exists primarily to support the former and enlarges the production database surface.
4. **Two inventory read paths:** online UI reads Supabase directly through inherited `supa`, while server equipment/economy logic also reads the inventory. This can produce stale UI and makes the game server not quite the sole online data boundary.
5. **Two decoration sources:** `World.gd` contains fallback constants while `data/decals/*.json` overrides them. This is a deliberate authoring fallback, but edits in the wrong source may appear ignored.
6. **Mirrored gameplay/economy constants:** client preview/display logic duplicates server rarity, salvage, upgrade, and item logic. The server remains authoritative, but UI can lie when values drift.
7. **Settings ownership is distributed:** `AudioManager`, `Client`, `NetClient`, and `Widgets` all load/save sections of the same `user://settings.cfg`, relying on read-modify-write discipline.
8. **Historical documentation conflicts with current code:** `README.md` describes a scaffold at Phase 1 and calls the server/client skeletons, whereas `TESTING.md`, `CLAUDE.md`, and the code describe all original phases as implemented. `HANDOFF.md` is explicitly historical but still includes obsolete original paths/status.

### 3. Security and authority problems

#### Confirmed issues

1. **DTLS does not authenticate the server.** Clients use `TLSOptions.client_unsafe()`. Encryption prevents passive token capture but does not prevent an active man-in-the-middle or a malicious server endpoint from receiving the Supabase access token.
2. **DTLS is optional in explicit online/local launches.** `--online` without `--dtls` sends the access token over unencrypted ENet. Exported public clients force DTLS, but developer/user flags can expose credentials.
3. **Client-writable location is trusted only after defensive cleanup.** Authenticated users may patch their own position/map for local-mode compatibility. The server validates known maps, rejects instance keys, rechecks gates, and clamps positions, which mitigates escalation; nevertheless, production position remains client-tamperable and may permit travel within allowed non-instance/non-gated maps unless every transition constraint is revalidated.
4. **Service-role compromise has total database impact.** This is inherent to the role, but the monolithic game process, generic `_http`, and combined Supabase adapter provide a broad blast radius. There is no narrower server credential or backend API boundary.
5. **Multi-session races are an authority problem.** A user can authenticate the same character more than once. In-memory locks and balances are scoped by peer, so both sessions may independently pass validations against stale state.
6. **Some authoritative operations are not atomic.** Any workflow that debits one resource and separately creates/updates/deletes another can be interrupted between steps. Refund code reduces common failures but is not equivalent to a transaction or idempotency key.
7. **Debug token injection is a credential-footgun.** `--token` and `--refresh` support automation but command-line arguments can be visible to local process inspection/logging. The refresh-token option is especially sensitive even though normal networking never sends it.

#### Positive controls already present

- RPC handlers bind identity to `get_remote_sender_id()` and reject unauthenticated sessions.
- Movement is clamped; ability keys are type/unlock checked and sequence-deduplicated.
- Chat and many economy/social operations have rate limits and/or busy guards.
- Reauthentication verifies the new token maps to the current character.
- Inventory client writes are revoked by later migrations; economy/progression character columns are pinned for non-service-role requests.
- Item ownership is re-read and character-scoped before mutation in key paths.
- Admin status is read server-side from a restricted table and rechecked for commands.
- Private-instance restored map values and post-load gates receive explicit defensive validation.
- Several critical mutations use atomic Postgres functions and DB constraints.

### 4. Files that appear obsolete or stale

No gameplay file is safe to delete solely from static reference analysis. The following are candidates for review, not deletion recommendations:

| Candidate | Assessment |
|---|---|
| `README.md` | **Stale documentation.** Its status/roadmap says Phase 1/scaffold despite the implemented online MMO systems. Update or redirect it before relying on it for onboarding. |
| `HANDOFF.md` | **Historical by its own banner.** Valuable provenance/reference, but its original project paths, line counts, status, and roadmap are obsolete. Keep under a clearly historical name or archive area. |
| `docs/*-kickoff.md` and `docs/*-handoff.md` | **Historical implementation records.** Likely useful archaeology, but not current architecture/source of truth. Consider an indexed `docs/history/` later. |
| Early inventory policies in `20260621160000...` and `20260621170000...` | **Superseded behavior, not obsolete migration files.** The next migration drops those policies. Never delete applied migrations; squash only through a deliberate new baseline process. |
| Client-token server fallbacks in `Supabase.gd` | **Legacy/dev compatibility risk.** Some methods accept/fallback to player tokens even though production writes are service-role-only. Audit call sites and fail closed before removal. |
| `Client.gd` local account mode and `Player.gd` | **Still referenced and functional.** They may be outside the future production product, but are not obsolete today; they power default editor/local and practice modes. |
| `World.gd` fallback decal data | **Possibly shadowed per map, but intentional fallback.** Compare each map against `data/decals/*.json` before consolidating. |
| `.uid` files | **Godot metadata, not obsolete.** Do not bulk-delete merely because they contain no gameplay logic. |

Documentation should distinguish current source-of-truth documents from historical handoffs. Today `CLAUDE.md`, `TESTING.md`, migrations, and code are more current than `README.md`/`HANDOFF.md`, but no single checked-in architecture document previously reconciled them.

## Safest implementation order for future work

The safest sequence reduces authority and observability risk before adding gameplay surface:

1. **Establish a reproducible baseline.** Run parse/import checks and existing headless smoke suites; record which tests require no live database, a local database, or deployed Supabase. Add a clean-migration verification job so final RLS/grants/triggers are auditable.
2. **Define production mode explicitly.** Decide whether account-backed local mode is a supported product or a developer sandbox. Make online behavior the default integration-test path, clearly label practice/local, and prevent local-only success from qualifying online work.
3. **Close transport identity risk.** Use a real certificate/public key trust strategy or a trusted VPN/gateway, remove `client_unsafe()` for production, and refuse plaintext online auth outside an explicit development profile. Replace refresh-token command-line injection where possible.
4. **Enforce one active session or add concurrency control.** Add a server/DB character session lease or optimistic versioning before further economy work. Define reconnect/takeover semantics.
5. **Move remaining multi-step economy mutations into atomic, idempotent DB functions.** Start with purchases, inventory/currency exchanges, equip-slot enforcement, salvage/craft, and refund paths. Include request IDs or database uniqueness guards for retries.
6. **Make the server the complete online data boundary.** Stop `NetClient` from reading gameplay inventory/progression directly from Supabase; deliver read models through authenticated server messages. Keep client Supabase access limited to Auth/account bootstrap if possible.
7. **Split the privileged persistence adapter.** Separate client auth/account API from server repository/services. Require the service role at server startup for production instead of running partially authoritative with known persistence failures.
8. **Version and type the network contract.** Add a protocol version during authentication, central schemas/validators for intents and snapshots, payload size limits, and compatibility rejection. Preserve `/root/Main/Net` until migration is deliberate.
9. **Extract server services behind narrow interfaces.** In low-risk order: chat/party, snapshot builder, persistence repositories, inventory/economy, quests/progression, instance/world director. Keep `Server.gd` as orchestration while tests pin existing behavior.
10. **Extract client presentation modules.** Move independent panels/controllers out of `NetClient.gd`, then rendering/FX/world construction out of `Client.gd`. Prefer composition over extending the full local game for online mode.
11. **Centralize shared definitions.** Put item schemas, slot capacities, rarity/cost data, and snapshot/read-model definitions in one server/shared source. Generate or validate client display data and SQL constraints from it where practical.
12. **Add new gameplay features last.** Implement each feature server-first: authoritative domain rule and atomic persistence, RPC/schema, client presentation, abuse tests, reconnect/failure tests, then local/practice adaptation only if that mode remains supported.

## Change checklist for future features

Before merging a networked gameplay feature, verify:

- The client sends an intent/identifier, never an authoritative result, price, reward, position, or stat total.
- The server validates authentication, ownership, location, state, bounds, rate, and replay/idempotency.
- Related durable mutations commit atomically or have a proven recovery invariant.
- The operation behaves correctly under duplicate requests, disconnect, timeout, second login, and server restart.
- Snapshot/RPC payloads are bounded and version-compatible.
- RLS and grants deny the equivalent direct client mutation.
- Local/practice behavior is either intentionally equivalent or explicitly unsupported.
- Headless tests cover the rule without requiring presentation code, and an online integration test covers the boundary.

## Architectural source-of-truth recommendation

Treat the following as the current authority hierarchy until documentation is consolidated:

1. Applied database state (which must be verified) and ordered `supabase/migrations/`.
2. `Main.gd`, `client/Net.gd`, `server/Server.gd`, `client/NetClient.gd`, and shared scripts.
3. `project.godot`, deployment configuration, and `TESTING.md`.
4. Current feature handoffs and `CLAUDE.md`.
5. `README.md` and historical `HANDOFF.md` only for provenance.

This document should be updated whenever boot modes, autoloads, trust boundaries, protocol shape, persistence ownership, or supported runtime modes change.
