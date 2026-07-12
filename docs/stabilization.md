# Production Stabilization Milestone — 2026-07-11

Scope: the security / authority / persistence / maintainability risks called out in
`docs/PROJECT_ARCHITECTURE.md`, addressed **without** touching combat balance, abilities, loot
probabilities, XP rates, item stats, movement, world layout, or the UI. This document is the source
of truth for: the protocol version, networking profiles, the single-session policy, the economy
transaction model, the stabilization test suite, the required manual production steps, and the
risks this milestone deliberately did **not** solve.

---

## 1. What shipped

| Phase | Change | Where |
|---|---|---|
| P1 | Headless invariant test harness (real `Server.gd` + deterministic fake Supabase/Net, failure injection) | `tools/stab_*.gd`, `tools/stab/` |
| P1 | Save failures are observable (counted + logged, never silent) | `Server.gd _save_one`, `_save_fail_n` |
| P1 | Movement input hardened (NaN/Inf/non-numeric neutralized before the sim) | `Server.gd submit_intent` |
| P1 | Fixed: unguarded `_session[pid]` after the admin-lookup await (crash on disconnect-during-auth) | `Server.gd authenticate` |
| P2 | Single active session per character (reject-the-second policy) + `recv_denied` reason RPC | `Server.gd _char_peer`, `Net.gd`, `NetClient.gd` |
| P3 | Atomic + idempotent economy: DB functions + op ledger + server award-flush model | `supabase/migrations/20260714000000_stab_atomic_economy.sql`, `server/ServerRepo.gd`, `Server.gd` |
| P4 | Transport trust profiles: pinned-cert DTLS verification, production fail-closed, explicit dev overrides | `shared/NetTrust.gd`, `Main.gd`, `Server.gd`, `Dockerfile`, `deploy/` |
| P5 | Protocol version handshake (reject old/new/missing before any token work) | `shared/Protocol.gd`, `Net.gd`, `Server.gd`, `NetClient.gd` |
| P6 | Privileged Supabase surface split into a server-only repository; production startup self-checks | `server/ServerRepo.gd`, `client/Supabase.gd`, `Main.gd` |

Deliberate small behavior deltas (all safety-motivated, none gameplay):
- LAN/remote **plaintext** connections now require the explicit `--insecure` flag (loopback is unchanged).
- `--dtls` clients **verify** the server against the pinned `client/zone_cert.pem`; ad-hoc unverified
  DTLS needs the explicit `--insecure-dtls` (source runs only).
- `--token`/`--refresh` only work from source (editor builds) and print a warning — exported builds
  hard-ignore them, same posture as `--insecure-dtls`.
- Selling/salvaging can never consume a **build** item on the atomic path (they were never meant to).
- A second login for an already-online character is refused (see §4).

---

## 2. Protocol version (current: **1**)

`shared/Protocol.gd` holds the single `VERSION` constant. The client sends
`{"protocol": VERSION, "build": BUILD}` alongside its token in `authenticate`; the server rejects a
mismatch **before any token work** with a player-facing reason (`recv_denied`), so no session,
claim, or DB call ever happens for an incompatible client.

**Bump `VERSION` (+1) when:**
- any RPC in `client/Net.gd` changes name / signature / argument shape / `@rpc` annotation, or the
  `/root/Main/Net` path moves;
- the snapshot gains a *required* field or changes the meaning of an existing one (additive optional
  fields old clients ignore do **not** need a bump);
- the semantics of an intent payload change (movement dict keys, ability sequencing);
- the authentication/handshake flow changes;
- an item/progression read model changes incompatibly.

Deploy rule: **server first, then clients.** Old clients get a clean "please update" refusal.
(Pre-stabilization clients send no hello at all — they are refused too, but can only show the
generic disconnect overlay because they predate `recv_denied`.)

---

## 3. Networking profiles (production vs development)

Profile switch: env **`LEGENDS_ENV=production`** (the Docker image sets it; anything else = development).

| Concern | PRODUCTION | DEVELOPMENT |
|---|---|---|
| Server plaintext | **Refuses to start** without `--dtls` | Allowed (local testing) |
| Server DTLS cert | **Requires** the persistent operator cert (`LEGENDS_DTLS_CERT`/`_KEY` file paths or `LEGENDS_DTLS_CERT_PEM`/`_KEY_PEM` contents); refuses to start otherwise | Falls back to an ephemeral self-signed cert (warned) |
| Client DTLS trust | Pinned `client/zone_cert.pem` (CN `legends-zone`), full verification; missing pin ⇒ **fail closed** | Same pin when present; else explicit `--insecure-dtls` (encrypt-only, loud warning) |
| Client plaintext | Loopback only (exported builds never send the token plaintext off-box) | Loopback silently; other hosts need explicit `--insecure` |
| `SUPABASE_SERVICE_KEY` | Missing/invalid ⇒ **server exits 1** | Warns, runs without persistence |
| Atomic economy fns missing | Economy ops **refused** (fail closed) | Legacy application-level fallback (warned once) |
| `--token` / `--refresh` | Ignored | Honored, with a process-list-exposure warning |

**Certificate runbook** (all pieces are in-repo; nothing was provisioned live by this milestone):
1. `deploy/gen_zone_cert.sh /opt/legends-certs` on the host generates `zone.key` (private,
   server-only) + `zone.crt` (public). CN **must** stay `legends-zone` — the client verifies it.
   `deploy/setup.sh` now does this automatically (step 5/6) and mounts the pair into the container.
2. Copy `zone.crt` into the repo as **`client/zone_cert.pem`**, commit (public material — safe), and
   re-export the client builds. The pin ships inside the build.
3. Fly.io: `fly secrets set LEGENDS_DTLS_CERT_PEM="$(cat zone.crt)" LEGENDS_DTLS_KEY_PEM="$(cat zone.key)"`.
4. **Rotation:** generate a new pair → ship the new `zone_cert.pem` in a client update **first**
   (clients pin exactly one cert) → swap the server pair + restart in a maintenance window.
5. Tokens: only the short-lived access token ever crosses the game wire; the refresh token never
   leaves the client; nothing logs either.

---

## 4. Single active session per character

Policy: **reject the second connection** (no takeover flow — deterministic and simplest-safe).
- `Server._char_peer` maps character id → controlling peer. Check-and-claim happens with no `await`
  between lookup and write, and claim→session creation is likewise await-free, so racing
  authentications resolve to exactly one winner (pinned by `tools/stab_sessions.gd`).
- The rejected peer receives `recv_denied("That character is already online …")` before the drop;
  the client shows it on the disconnect overlay (sticky — the generic transport message can't
  overwrite it).
- Disconnect releases the claim; a failed or abandoned authentication never creates one.

**Limitations (honest):**
- Scope is **one server process** — exactly the current topology (one droplet, one zone process).
  Running multiple zone processes against one database would need the DB lease below.
- After a hard client crash, ENet takes seconds (up to ~30s worst case) to notice the zombie peer;
  until then a relogin is refused with the "already online" message.
- A server crash loses the in-memory claims — harmless (fresh process, fresh claims).

**Cross-process DB lease (DESIGNED, NOT APPLIED, NOT WIRED)** — only needed for multi-instance:

```sql
create table public.session_leases (
  character_id uuid primary key references public.characters(id) on delete cascade,
  server_id    text not null,          -- unique per zone process
  heartbeat    timestamptz not null default now()
);
alter table public.session_leases enable row level security;
revoke all on public.session_leases from authenticated, anon;
-- claim (service_role fn): insert … on conflict (character_id) do update
--   set server_id = excluded.server_id, heartbeat = now()
--   where session_leases.heartbeat < now() - interval '90 seconds'
--   returning true;                     -- false/no row = someone else holds a live lease
-- heartbeat: update … set heartbeat = now() where character_id = $1 and server_id = $2
--   (piggyback on the 15 s save cadence)
-- release: delete where character_id = $1 and server_id = $2 (on disconnect)
```
Expiry (90 s ≈ 6 missed heartbeats) covers crashed processes. Wire it inside `authenticate` after
the in-memory claim; keep the in-memory map as the fast path.

---

## 5. Economy: transaction audit + the atomic model

### 5.1 Operation audit

Classification: **A** = atomic in a Postgres function · **G** = single-row atomic via guarded
filter · **R** = multi-request but recoverable · **U** = multi-request and unsafe · **M** = in-memory only.

| Operation | Before | After (migration applied) |
|---|---|---|
| Shop buy / random roll | **U** (mem debit → insert → absolute save; crash ⇒ free item or lost credits) | **A** `econ_buy_item` (idempotent) |
| Practice-vendor buy (tokens) | **U** (same shape) | **A** `econ_buy_item` |
| Sell / bulk sell | **G+U** (guarded per-row delete, but payout only in memory + absolute save) | **A** `econ_sell_items` |
| Salvage | **R** (guarded delete + atomic `mats_add` per item; crash loses ≤1 yield) | **A** `econ_salvage_items` |
| Forge upgrade / reforge | **U** (atomic scrap spend, mem credit debit, guarded patch, app-level refunds) | **A** `econ_forge_upgrade` / `econ_forge_reforge` |
| Craft | **R/U** (atomic scrap spend → insert → refund on fail) | **A** `econ_craft` |
| Cosmetic dye buy | **U** (mem debit → atomic grant → refund) | **A** `econ_buy_cosmetic` |
| Locker-room unlock | **U** (mem debit → gated flip → refund) | **A** `econ_unlock_locker` |
| Talent respec | **U** (mem debit → atomic reset → refund) | **A** `econ_respec_talents` |
| Build-item buy | **U** (mem debit → insert → refund; caps pre-checked fail-closed) | **A** `econ_buy_item` (caps still server-pre-checked) |
| Build place / move / remove | **G** (gated single-row PATCH) | unchanged **G** (already safe) |
| Kill/quest/drill **credit & token awards** | **M+U** (memory + absolute 15 s/kill save; stale-session clobber risk) | **A** `econ_award` deltas via the award-bucket flush |
| Item lock toggle | **G** | unchanged |
| Equip / unequip + slot trim | **R** (multi-PATCH; read-side capacity cap bounds damage) | unchanged **R** — *residual, see §8* |
| Loot / quest-item / admin-give grants | **G** (single insert; loss-not-dupe) | unchanged |
| Scrap add/spend | **A** `mats_add` | unchanged (legacy path only) |
| Pages, Master Key, Intensity, talents spend, paragon, rested, bounty claim, season claim, quest rewards, cosmetics grant/equip, leaderboards | **A** (pre-existing fns) | unchanged |
| XP / level / position persistence | absolute PATCH | unchanged — *residual, see §8* |

### 5.2 The atomic model (server side)

- Every atomic op carries a **server-generated UUIDv4 op id**; the DB records `(op_id → result)` in
  `public.economy_ops`. A replayed id returns the original result (`duplicate: true`) and never
  re-applies. Client-supplied ids are never accepted — clients still send only intents.
- `ServerRepo._econ_rpc` retries **once** on a transport-level failure (outcome unknown) with the
  same op id — safe by the ledger. HTTP-level rejections are not retried.
- Awards (kill credits/tokens etc.) accumulate in a per-session bucket and flush as **one
  idempotent delta** (`econ_award`) on every save; a failed flush keeps its packet and retries the
  same op id later. In atomic mode `_save_one`'s PATCH **no longer carries** `credits`/`practice_tokens`
  (the DB is authoritative; the session holds a display mirror). Credit deltas may be **negative**
  (admin corrections) — the DB floors the balance at 0.
- A per-session **econ gate** serializes every balance-returning DB call (flushes and spends), so
  returned balance snapshots always apply to the mirror in commit order — no transient over/under
  display and no spurious insufficient-funds refusals from an in-flight flush. A **replayed**
  (ledger-duplicate) result never overwrites the mirror (its balance is from the original commit).
- If a session disconnects while its award flush is transport-failed, the packet moves to a
  server-level **orphan retry queue** (retried each save tick with the same op id — ledger-safe;
  dropped with a log after ~10 min of failures).
- Every function that updates `characters` sets the `request.jwt.claims` GUC to `service_role`
  (transaction-local) itself, so the guard triggers behave identically whether the fn is invoked via
  PostgREST, the SQL editor, or psql — manual verification can't silently no-op the currency side.
- The ledger is bounded: every recorded op prunes that character's entries older than 7 days.
- All functions are `SECURITY DEFINER`, `search_path` pinned, `EXECUTE` revoked from
  `public/anon/authenticated`, granted to `service_role` only. Locking order (characters row first)
  is uniform, so concurrent ops serialize instead of deadlocking — and the ledger dedup check runs
  **under** that row lock, so even a timeout-retry racing its own still-executing first attempt
  serializes and sees the recorded result instead of double-applying.
- Fallback: without the migration, development uses the old application-level paths (warned once);
  **production refuses economy ops** (fail closed). The legacy code remains for one burn-in cycle.

### 5.3 Migration / deployment order (NOT applied by this milestone)

1. **Apply** `supabase/migrations/20260714000000_stab_atomic_economy.sql` to the project
   (backward-compatible: the running pre-stabilization server never calls these functions).
2. **Deploy** the stabilization server (`deploy/setup.sh` — it now also provisions the DTLS cert
   and runs the container with `LEGENDS_ENV=production`).
3. **Verify** the boot log: `✓ SUPABASE_SERVICE_KEY valid`, `✓ atomic economy functions live`,
   `[trust] DTLS: operator certificate`, then exercise one shop buy + sell in-game.
4. **Later change** (after burn-in): delete the legacy `_legacy_econ_allowed()` fallback paths from
   `Server.gd`.

Order matters only in one direction: deploying the new server against a production DB **without**
the migration refuses all purchases (fail closed, not unsafe).

---

## 6. Client/server Supabase boundary (P6)

- `client/Supabase.gd` (client-facing): sign-up/sign-in/refresh, own character read/create,
  local-mode position save, own-inventory read. **No `service_key` field, no privileged methods.**
- `server/ServerRepo.gd` (server-only, extends the client adapter for its HTTP plumbing): the
  `service_key`, every `*_as` method, the atomic `econ_*` RPCs, and the boot probe. Only
  `Main.gd _make_zone_server` constructs it.
- Startup self-checks (status only — secrets are never printed): production exits non-zero when the
  service key is missing or invalid, when the DTLS trust material is absent, or when `start()` fails.
- **Export caveat:** Godot exports embed *all* project scripts (`export_filter="all_resources"`),
  so `ServerRepo.gd` ships inside client builds too. The split prevents *accidental use* from client
  code; it does not make an embedded secret safe — the service-role key stays runtime-only (env),
  which is why nothing commits or bakes it.
- The online client still reads its **own inventory** directly (RLS-scoped, read-only) for UI lists
  — moving those reads behind server messages is future work (§8).

---

## 7. Stabilization test suite

All offline — no server process, no network, no live Supabase. They boot the production
`server/Server.gd` against `tools/stab/fake_supa.gd` (deterministic in-memory Supabase with
failure injection + frame-yield latency) and `tools/stab/fake_net.gd` (recording Net). Exit
non-zero on failure.

```
godot --headless --path . --script res://tools/stab_auth.gd         # 36 asserts — auth, reauth, disconnect cleanup, reconnect hygiene
godot --headless --path . --script res://tools/stab_authority.gd    # 29 — movement/ability/ownership/admin/map-restore authority
godot --headless --path . --script res://tools/stab_economy.gd      # 31 — LEGACY economy: dupe-safety, refunds, races, save observability
godot --headless --path . --script res://tools/stab_econ_atomic.gd  # 27 — ATOMIC economy: op ledger, award flush, retry, fail-closed prod
godot --headless --path . --script res://tools/stab_sessions.gd     # 15 — single-session policy incl. the auth race
godot --headless --path . --script res://tools/stab_protocol.gd     # 14 — version handshake (match/missing/older/newer/malformed)
godot --headless --path . --script res://tools/stab_trust.gd        # 16 — DTLS/plaintext trust matrix (prod vs dev)
```

Manual/system checks used for this milestone (repeatable):
```
./play.sh check                                                      # map parse preflight
godot --headless --path . -- --server            # dev boot: expect "online on UDP …", no SCRIPT ERROR
LEGENDS_ENV=production godot --headless --path . -- --server --dtls  # expect refusal, exit 1 (no cert)
```

**Clean-database migration verification** (executed for this milestone against a scratch
Postgres 16.4; also runs in CI): `tools/migration_check/bootstrap.sql` stubs the minimal Supabase
runtime (roles, `auth.users`, `auth.uid()`), then every migration applies in filename order, then
`tools/migration_check/assertions.sql` verifies grants/RLS posture **and** exercises the real plpgsql
(idempotent replay, guarded debits, equipped-item protection, stale-version refusal, gear-cap
rollback, guard-trigger pinning). Exact psql commands are in the assertions.sql header.

**CI** (`.github/workflows/tests.yml`): on every push/PR, a `godot-tests` job runs all 23 headless
suites and a `migration-check` job runs the clean-database verification against a `postgres:16`
service container. Neither touches the live project.

---

## 8. Remaining risks (not solved here — ranked)

1. **XP/level (and position) still persist as absolute PATCHes.** A crash loses progress since the
   last save (≤15 s or last kill); no dupe is possible now that sessions are single. Full fix:
   delta-based or versioned saves.
2. **Equip/unequip slot trimming is still multi-request.** A failure between the equip and the trim
   can leave >capacity rows equipped in the DB; the read-side capacity cap in `_apply_equipment`
   bounds the effect (extras never count toward stats). Full fix: an `econ_equip` DB function.
3. **The online client still reads its own inventory from Supabase directly** (read-only,
   RLS-scoped, 7 call sites). The server is not yet the complete online data boundary.
4. **Session lease is in-process only** — fine for the single-droplet topology; apply §4's DB lease
   before running multiple zone processes.
5. **Crash-recovery for in-flight atomic ops is "loss, never dupe".** A *disconnect* during a
   transport-failed flush is now covered (the orphan retry queue), but a full **server crash** still
   loses any un-flushed award bucket (bounded by the save cadence — one kill's payout at most).
6. **Legacy economy fallback code still exists** (dev-only path). Remove after production burn-in.
7. **CI exists but is unproven on GitHub** — `.github/workflows/tests.yml` (all 23 suites + the
   clean-DB migration check) activates on the first push; watch its first run.
8. **The client's economy display constants** (forge/salvage cost formulas, `RARITY_MULT`) are
   still duplicated from the server and can silently drift (display-only; server re-validates).
9. **Local mode keeps `characters` position columns client-writable by design**; the server
   re-validates gates/instances on login (pinned by `stab_authority.gd`).

## 9. Recommended next milestone

Remove the legacy economy fallback after burn-in, move the client's direct inventory reads behind
server read-models, and add `econ_equip` — in that order. (CI and the clean-DB migration check are
already wired.) After that, the codebase-shape work (extracting services out of the three god
scripts) can proceed on a pinned, observable baseline.
