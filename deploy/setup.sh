#!/usr/bin/env bash
# Legends MMO — one-shot VPS setup for the dedicated zone server.
# Target: a fresh x86_64 / amd64 Ubuntu 22.04 or 24.04 box. Run as root (or: sudo -E bash setup.sh).
#
# Required env vars:
#   SUPABASE_SERVICE_KEY   Supabase -> Settings -> API -> service_role  (lets the server save loot/equip)
#   REPO_URL               git URL of this repo, e.g. https://github.com/<you>/legends-mmo.git
#                          (private repo? use https://<token>@github.com/...  ·  omit if you uploaded the
#                           repo to APP_DIR yourself)
# Optional: PORT (default 7777), APP_DIR (default /opt/legends-mmo)
#
# Quick start once the repo is on GitHub:
#   export SUPABASE_SERVICE_KEY="eyJ..."
#   export REPO_URL="https://github.com/voullume/legends-mmo.git"
#   curl -fsSL "https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh" | sudo -E bash
# (Or paste this whole script as cloud-init user-data with the two vars hardcoded at the top.)
set -euo pipefail

PORT="${PORT:-7777}"
APP_DIR="${APP_DIR:-/opt/legends-mmo}"
REPO_URL="${REPO_URL:-}"
IMAGE="legends-zone"                                   # local build tag (fallback only)
IMAGE_REF="${IMAGE_REF:-ghcr.io/voullume/legends-mmo:latest}"   # prebuilt image (built off-box by CI)

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo -E bash setup.sh)"; exit 1; }

echo "==> [1/6] Docker"
command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh

echo "==> [2/6] Code"
command -v git >/dev/null 2>&1 || { apt-get update -y && apt-get install -y git; }
if [ -d "$APP_DIR/.git" ]; then
  # re-deploy: update to the latest main from the already-configured remote (no REPO_URL needed)
  git -C "$APP_DIR" fetch --depth 1 origin main && git -C "$APP_DIR" reset --hard origin/main
elif [ -n "$REPO_URL" ]; then
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi
[ -f "$APP_DIR/Dockerfile" ] || { echo "ERROR: no code at $APP_DIR — set REPO_URL (first run), or upload the repo there."; exit 1; }
cd "$APP_DIR"

# Resolve the service key: use the env var if given (and remember it, shell-quoted so re-sourcing
# can't break), else reuse a saved one (tolerating a malformed old .env). Re-runs need no args.
if [ -n "${SUPABASE_SERVICE_KEY:-}" ]; then
  umask 077; printf 'SUPABASE_SERVICE_KEY=%q\n' "$SUPABASE_SERVICE_KEY" > "$APP_DIR/.env"
elif [ -f "$APP_DIR/.env" ]; then
  . "$APP_DIR/.env" 2>/dev/null || true
fi
case "${SUPABASE_SERVICE_KEY:-}" in
  eyJ*) : ;;   # looks like a JWT — good
  *) echo "ERROR: SUPABASE_SERVICE_KEY is missing or invalid (it must be the real service_role JWT,"
     echo "       which starts with 'eyJ' — not a placeholder). Re-run with the real key:"
     echo "         export SUPABASE_SERVICE_KEY=\"eyJ...\""
     echo "         curl -fsSL \"https://raw.githubusercontent.com/voullume/legends-mmo/main/deploy/setup.sh\" | sudo -E bash"
     exit 1 ;;
esac

echo "==> [3/6] Image — pull the CI-built image (fast, no on-box build); build locally only as a fallback"
if docker pull "$IMAGE_REF" >/dev/null 2>&1; then
  IMAGE="$IMAGE_REF"
  echo "    using prebuilt $IMAGE_REF"
else
  echo "    prebuilt image unavailable (registry private/unreachable?) — building on-box instead."
  echo "    (this needs RAM/swap; the droplet now has a swapfile, so it won't OOM, just slower.)"
  docker build -t "$IMAGE" .
fi

echo "==> [4/6] Firewall (allow SSH + UDP $PORT, if ufw is in use)"
if command -v ufw >/dev/null 2>&1; then ufw allow OpenSSH >/dev/null 2>&1 || true; ufw allow "${PORT}/udp" >/dev/null 2>&1 || true; fi

echo "==> [5/6] Persistent DTLS certificate (stabilization P4 — production refuses to start without one)"
CERT_DIR="${CERT_DIR:-/opt/legends-certs}"
if [ ! -f "$CERT_DIR/zone.key" ]; then
  command -v openssl >/dev/null 2>&1 || { apt-get update -y && apt-get install -y openssl; }
  bash "$APP_DIR/deploy/gen_zone_cert.sh" "$CERT_DIR"
  NEW_CERT=1
else
  echo "    reusing existing keypair in $CERT_DIR (rotate with deploy/gen_zone_cert.sh)"
  NEW_CERT=0
fi

echo "==> [6/6] Run (detached, auto-restart on reboot, DTLS + pinned certificate)"
docker rm -f legends-zone >/dev/null 2>&1 || true
docker run -d --name legends-zone --restart unless-stopped \
  -e SUPABASE_SERVICE_KEY="$SUPABASE_SERVICE_KEY" -e PORT="$PORT" \
  -v "$CERT_DIR":/certs:ro \
  -e LEGENDS_DTLS_CERT=/certs/zone.crt -e LEGENDS_DTLS_KEY=/certs/zone.key \
  -p "${PORT}:${PORT}/udp" "$IMAGE"

if [ "$NEW_CERT" = "1" ]; then
  echo ""
  echo "!!! NEW certificate generated — clients can only connect once they pin it:"
  echo "    copy $CERT_DIR/zone.crt into the repo as client/zone_cert.pem, commit, and re-export the client builds."
fi

IP="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this-VPS-IP>')"
cat <<EOF

==> Done — zone server running on UDP ${PORT} (DTLS).
    Players connect:    godot --path . -- --online ${IP} --dtls
    Live logs:          docker logs -f legends-zone
    Restart / stop:     docker restart legends-zone   |   docker stop legends-zone
    Update + redeploy:  re-run this script (it pulls latest, rebuilds, restarts).

    NOTE: also open UDP ${PORT} in your provider's firewall / security group (separate from ufw).
EOF
