#!/usr/bin/env bash
# Legends MMO launcher.  Usage:
#   ./play.sh            single-player: log in -> your character -> local world  (easiest)
#   ./play.sh dev        MAP EDITING: headless server + ONE client, in one command (auto-launches both)
#   ./play.sh zone       multiplayer demo: headless server + two player windows
#   ./play.sh server     just the dedicated zone server (headless, no window)
#   ./play.sh online [ip] one player joining a LOCAL zone (default 127.0.0.1, no encryption)
#   ./play.sh join <ip>  join a REMOTE/internet server (encrypted) — e.g. ./play.sh join 159.89.132.86
#   ./play.sh check      parse-check shared/World.gd (your map file) — friendly, no launch
#
# Demo login that already has a character:  legends_smoke1@testmail.dev / Testpass1234!
# (or click "Sign Up" to make your own — it logs you straight in, no email needed.)
set -e
GODOT="${GODOT:-$HOME/.local/bin/godot}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Load local secrets (SUPABASE_SERVICE_KEY for server-side inventory writes) if present.
# Put `SUPABASE_SERVICE_KEY=...` in a gitignored .env next to this script — see .env.example.
[ -f "$DIR/.env" ] && set -a && . "$DIR/.env" && set +a

# Preflight: parse-check the map file so a typo gives ONE friendly line, not an 80-error cascade.
preflight() {
  local out
  out="$("$GODOT" --headless --path "$DIR" --check-only --script res://shared/World.gd 2>&1 | grep -iE "error" | head -3)"
  if [ -n "$out" ]; then
    echo "──────────────────────────────────────────────────────────────"
    echo "✗ shared/World.gd has a syntax error — fix this before launching:"
    echo "$out" | sed 's/^/    /'
    echo "  Most common cause: a MISSING COMMA at the end of the line just"
    echo "  ABOVE a new entry. Open shared/World.gd and check there."
    echo "──────────────────────────────────────────────────────────────"
    return 1
  fi
  echo "✓ maps parse OK"
}

case "${1:-local}" in
  local)
    exec "$GODOT" --path "$DIR" ;;
  check)
    preflight ;;
  dev)
    preflight || exit 1
    echo "starting headless zone server…"
    "$GODOT" --headless --path "$DIR" -- --server & SRV=$!
    trap 'kill $SRV 2>/dev/null' EXIT
    sleep 2
    echo "opening your window — log in (legends_smoke1@testmail.dev / Testpass1234!), press F3 for coords"
    "$GODOT" --path "$DIR" -- --online 127.0.0.1
    ;;
  server)
    preflight || exit 1
    exec "$GODOT" --headless --path "$DIR" -- --server ;;
  online)
    exec "$GODOT" --path "$DIR" -- --online "${2:-127.0.0.1}" ;;
  join)
    [ -n "${2:-}" ] || { echo "usage: $0 join <server-ip>   (e.g. ./play.sh join 159.89.132.86)"; exit 1; }
    exec "$GODOT" --path "$DIR" -- --online "$2" --dtls ;;
  zone)
    preflight || exit 1
    echo "starting headless zone server…"
    "$GODOT" --headless --path "$DIR" -- --server & SRV=$!
    trap 'kill $SRV 2>/dev/null' EXIT
    sleep 2
    echo "opening two player windows — log in with a DIFFERENT account in each"
    "$GODOT" --path "$DIR" -- --online 127.0.0.1 &
    "$GODOT" --path "$DIR" -- --online 127.0.0.1 &
    wait ;;
  *)
    echo "usage: $0 {local|dev|zone|server|online [ip]|join <ip>|check}"; exit 1 ;;
esac
