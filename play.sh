#!/usr/bin/env bash
# Legends MMO launcher.  Usage:
#   ./play.sh            single-player: log in -> your character -> local world  (easiest)
#   ./play.sh zone       multiplayer demo: headless server + two player windows
#   ./play.sh server     just the dedicated zone server (headless, no window)
#   ./play.sh online [ip] one player joining a zone (default 127.0.0.1)
#
# Demo login that already has a character:  legends_smoke1@testmail.dev / Testpass1234!
# (or click "Sign Up" to make your own — it logs you straight in, no email needed.)
set -e
GODOT="${GODOT:-$HOME/.local/bin/godot}"
DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-local}" in
  local)
    exec "$GODOT" --path "$DIR" ;;
  server)
    exec "$GODOT" --headless --path "$DIR" -- --server ;;
  online)
    exec "$GODOT" --path "$DIR" -- --online "${2:-127.0.0.1}" ;;
  zone)
    echo "starting headless zone server…"
    "$GODOT" --headless --path "$DIR" -- --server & SRV=$!
    trap 'kill $SRV 2>/dev/null' EXIT
    sleep 2
    echo "opening two player windows — log in with a DIFFERENT account in each"
    "$GODOT" --path "$DIR" -- --online 127.0.0.1 &
    "$GODOT" --path "$DIR" -- --online 127.0.0.1 &
    wait ;;
  *)
    echo "usage: $0 {local|zone|server|online [ip]}"; exit 1 ;;
esac
