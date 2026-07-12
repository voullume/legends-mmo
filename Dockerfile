# Headless Legends MMO zone server — a self-contained dedicated server image.
#
# This image is the PRODUCTION profile (LEGENDS_ENV=production below): it REFUSES to start without
# a valid SUPABASE_SERVICE_KEY *and* a persistent operator DTLS certificate (exit 1, so a --restart
# policy surfaces the misconfiguration instead of hiding it). deploy/setup.sh provisions all of it;
# by hand:
#
#   docker build -t legends-zone .
#   deploy/gen_zone_cert.sh /opt/legends-certs        # once per host (CN must stay 'legends-zone')
#   docker run -e SUPABASE_SERVICE_KEY=<service_role> \
#     -v /opt/legends-certs:/certs:ro \
#     -e LEGENDS_DTLS_CERT=/certs/zone.crt -e LEGENDS_DTLS_KEY=/certs/zone.key \
#     -p 7777:7777/udp legends-zone
#
#   # throwaway DEV container (self-signed cert, missing service key only warns):
#   docker run -e LEGENDS_ENV=development -e SUPABASE_SERVICE_KEY=<key> -p 7777:7777/udp legends-zone
#
# Players connect with:  godot --path . -- --online <host-ip> --dtls   (the exported client verifies
# the pinned client/zone_cert.pem; dev clients without the pin need --insecure-dtls).
# (Override the engine version if 4.6.3 isn't the right asset: --build-arg GODOT_VERSION=4.6.2-stable)
FROM debian:bookworm-slim

ARG GODOT_VERSION=4.6.3-stable

# Godot's headless binary still dynamically links a few system libs even without rendering.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget unzip \
        libfontconfig1 libx11-6 libxext6 libxcursor1 libxinerama1 libxrandr2 libxi6 libgl1 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" -O /tmp/godot.zip \
    && unzip -q /tmp/godot.zip -d /tmp \
    && mv "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

WORKDIR /app
# Heavy, rarely-changing assets FIRST so the slow import below stays in Docker's layer cache:
# a code-only update doesn't touch models/, so this layer is reused and the import is skipped.
COPY project.godot ./
COPY models/ ./models/
RUN godot --headless --path /app --import 2>&1 | tail -3 || true

# The code (changes often) — copied after the import so editing it doesn't re-run the import.
COPY . /app

ENV PORT=7777
# Containers are the PRODUCTION profile (stabilization P4): the server refuses plaintext, requires a
# persistent operator DTLS certificate (mount it and set LEGENDS_DTLS_CERT/LEGENDS_DTLS_KEY, or pass
# the PEM contents via LEGENDS_DTLS_CERT_PEM/LEGENDS_DTLS_KEY_PEM), and fails closed on economy ops
# if the atomic-economy migration is missing. Override LEGENDS_ENV=development for a throwaway box.
ENV LEGENDS_ENV=production
EXPOSE 7777/udp

# DTLS is on by default for an exposed/container deploy; clients must also pass --dtls.
# Set BIND (e.g. fly-global-services) for platforms that require a specific UDP bind address.
CMD ["sh", "-c", "godot --headless --path /app -- --server --dtls --port ${PORT} ${BIND:+--bind ${BIND}}"]
