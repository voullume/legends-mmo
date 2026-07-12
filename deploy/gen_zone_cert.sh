#!/usr/bin/env bash
# Generate the PERSISTENT zone-server DTLS keypair (stabilization P4).
#
# The client PINS the public certificate (committed into the repo as client/zone_cert.pem and baked
# into exported builds), so the CN must stay exactly 'legends-zone' — shared/NetTrust.gd verifies it.
#
#   deploy/gen_zone_cert.sh [out-dir]     # default ./zone-certs; refuses to overwrite an existing key
#
# Produces:
#   <out-dir>/zone.key   PRIVATE key — server-only. Never commit, never ship to clients.
#   <out-dir>/zone.crt   PUBLIC certificate — safe to commit; copy to client/zone_cert.pem.
#
# Rotation: generate a new pair, ship the new zone_cert.pem in a client update FIRST (clients pin a
# single cert), then swap the server's key/cert and restart during a maintenance window.
set -euo pipefail
DIR="${1:-./zone-certs}"
mkdir -p "$DIR"
umask 077
if [ -f "$DIR/zone.key" ]; then
  echo "REFUSING to overwrite existing $DIR/zone.key — rotating? Move the old pair aside first." >&2
  exit 1
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1825 \
  -keyout "$DIR/zone.key" -out "$DIR/zone.crt" \
  -subj "/CN=legends-zone/O=Legends/C=US"
chmod 600 "$DIR/zone.key"
chmod 644 "$DIR/zone.crt"
cat <<EOF

==> Zone DTLS keypair generated in $DIR
    Server (droplet):  keep zone.key + zone.crt on the host and run the container with
                         -v $(cd "$DIR" && pwd):/certs:ro \\
                         -e LEGENDS_DTLS_CERT=/certs/zone.crt -e LEGENDS_DTLS_KEY=/certs/zone.key
    Client (pin):      copy zone.crt into the repo as client/zone_cert.pem, commit it, and
                       re-export the public client builds (the pin ships inside the build).
EOF
