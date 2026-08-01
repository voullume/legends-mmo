#!/usr/bin/env python3
"""Snapshot / verify / restore the LIVE player-data tables.

WHY THIS EXISTS
    Player progress (levels, gear, credits, quests) lives only in Supabase. The `characters_guard_*`
    triggers stop a *client* from rewriting progression, but they explicitly let `service_role`
    change anything — and the zone server, the MCP connection, and any agent holding the service key
    are all service_role. Before this script there was no way to answer "can we get it back?".
    Now: take a snapshot before anything risky, and you can always roll back to that point.

SAFETY MODEL
    snapshot / verify  — READ-ONLY. Safe to run any time, unattended, on a schedule.
    restore            — DESTRUCTIVE. Overwrites live rows. Requires --yes-restore-live-player-data
                         AND prints a row-by-row preview first. Never run it without owner approval.

USAGE
    python3 tools/backup_player_data.py snapshot            # -> backups/<utc-timestamp>/
    python3 tools/backup_player_data.py verify  <dir>       # re-check checksums of a snapshot
    python3 tools/backup_player_data.py list               # show snapshots on disk
    python3 tools/backup_player_data.py diff    <dir>       # what changed live since that snapshot
    python3 tools/backup_player_data.py restore <dir> --table characters --yes-restore-live-player-data

Credentials: SUPABASE_SERVICE_KEY from .env (never printed). Snapshots land in backups/, which is
gitignored — they contain real user data and must never be committed.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

PROJECT = "reaiolskmzorymnrbtab"
BASE = f"https://{PROJECT}.supabase.co/rest/v1"
ROOT = Path(__file__).resolve().parent.parent
BACKUP_DIR = ROOT / "backups"

# Everything a player would be upset to lose. bot_reports is deliberately EXCLUDED: it is the
# resident playtest stream (57k+ rows, regenerates itself, not player progress).
PLAYER_TABLES = [
    "characters",
    "inventory",
    "character_quests",
    "character_cosmetics",
    "progression",
    "materials",
    "leaderboards",
    "economy_ops",
    "admins",
]


def service_key() -> str:
    env = ROOT / ".env"
    if not env.exists():
        sys.exit("ERROR: .env not found — cannot reach Supabase.")
    for line in env.read_text().splitlines():
        if line.startswith("SUPABASE_SERVICE_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("ERROR: SUPABASE_SERVICE_KEY missing from .env")


def fetch(table: str, key: str) -> list:
    """Read every row of a table via PostgREST, paging so nothing is silently truncated."""
    out, offset, page = [], 0, 1000
    while True:
        req = urllib.request.Request(
            f"{BASE}/{table}?select=*&limit={page}&offset={offset}",
            headers={"apikey": key, "Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            chunk = json.loads(r.read().decode())
        out.extend(chunk)
        if len(chunk) < page:
            return out
        offset += page


def digest(rows: list) -> str:
    return hashlib.sha256(
        json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def cmd_snapshot(_args) -> None:
    key = service_key()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest = BACKUP_DIR / stamp
    dest.mkdir(parents=True, exist_ok=True)
    manifest = {"taken_utc": stamp, "project": PROJECT, "tables": {}}
    print(f"snapshot -> {dest.relative_to(ROOT)}")
    for t in PLAYER_TABLES:
        try:
            rows = fetch(t, key)
        except Exception as e:                      # one unreadable table must not lose the rest
            print(f"  !! {t}: FAILED ({e})")
            manifest["tables"][t] = {"error": str(e)}
            continue
        (dest / f"{t}.json").write_text(json.dumps(rows, indent=1, sort_keys=True))
        h = digest(rows)
        manifest["tables"][t] = {"rows": len(rows), "sha256": h}
        print(f"  {t:22} {len(rows):6} rows  {h[:12]}")
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2))
    failed = [t for t, v in manifest["tables"].items() if "error" in v]
    if failed:
        sys.exit(f"INCOMPLETE snapshot — failed: {', '.join(failed)}")
    print("snapshot complete + verified readable")


def load_snapshot(d: str):
    dest = Path(d)
    if not dest.is_absolute():
        dest = ROOT / d
    man = dest / "manifest.json"
    if not man.exists():
        sys.exit(f"ERROR: no manifest.json in {dest}")
    return dest, json.loads(man.read_text())


def cmd_verify(args) -> None:
    dest, manifest = load_snapshot(args.dir)
    bad = 0
    for t, meta in manifest["tables"].items():
        if "error" in meta:
            print(f"  {t:22} recorded as FAILED at snapshot time")
            bad += 1
            continue
        rows = json.loads((dest / f"{t}.json").read_text())
        h = digest(rows)
        ok = h == meta["sha256"] and len(rows) == meta["rows"]
        print(f"  {t:22} {len(rows):6} rows  {'OK' if ok else 'CORRUPT'}")
        bad += 0 if ok else 1
    sys.exit(bad and f"{bad} table(s) failed verification" or 0)


def cmd_list(_args) -> None:
    if not BACKUP_DIR.exists():
        print("no snapshots yet")
        return
    for d in sorted(BACKUP_DIR.iterdir()):
        man = d / "manifest.json"
        if not man.exists():
            continue
        m = json.loads(man.read_text())
        total = sum(v.get("rows", 0) for v in m["tables"].values())
        print(f"  {d.name}   {total:6} rows across {len(m['tables'])} tables")


def cmd_diff(args) -> None:
    """What has changed LIVE since this snapshot — the 'did something eat player data?' check."""
    dest, manifest = load_snapshot(args.dir)
    key = service_key()
    print(f"live vs {dest.name}")
    drift = False
    for t, meta in manifest["tables"].items():
        if "error" in meta:
            continue
        live = fetch(t, key)
        d = len(live) - meta["rows"]
        same = digest(live) == meta["sha256"]
        flag = "same" if same else ("ROWS LOST" if d < 0 else "changed")
        if not same:
            drift = True
        print(f"  {t:22} snapshot {meta['rows']:6} -> live {len(live):6}  ({d:+d})  {flag}")
    print("\nno drift" if not drift else "\ndrift present — inspect before assuming it is expected")


def cmd_restore(args) -> None:
    if not args.yes_restore_live_player_data:
        sys.exit(
            "REFUSED: restore overwrites LIVE player data.\n"
            "Re-run with --yes-restore-live-player-data, and only with the owner's explicit approval."
        )
    dest, manifest = load_snapshot(args.dir)
    t = args.table
    if t not in manifest["tables"]:
        sys.exit(f"ERROR: {t} is not in this snapshot")
    key = service_key()
    rows = json.loads((dest / f"{t}.json").read_text())
    live = fetch(t, key)
    print(f"RESTORE {t}: live {len(live)} rows -> snapshot {len(rows)} rows ({dest.name})")
    print("  this UPSERTS every snapshot row over live values. Rows created after the snapshot")
    print("  are NOT deleted (a restore never destroys newer characters).")
    if input("  type the table name to confirm: ").strip() != t:
        sys.exit("aborted")
    body = json.dumps(rows).encode()
    req = urllib.request.Request(
        f"{BASE}/{t}",
        data=body,
        method="POST",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        print(f"  HTTP {r.status} — restored")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("snapshot").set_defaults(fn=cmd_snapshot)
    sub.add_parser("list").set_defaults(fn=cmd_list)
    v = sub.add_parser("verify"); v.add_argument("dir"); v.set_defaults(fn=cmd_verify)
    d = sub.add_parser("diff"); d.add_argument("dir"); d.set_defaults(fn=cmd_diff)
    r = sub.add_parser("restore")
    r.add_argument("dir")
    r.add_argument("--table", required=True)
    r.add_argument("--yes-restore-live-player-data", action="store_true")
    r.set_defaults(fn=cmd_restore)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
