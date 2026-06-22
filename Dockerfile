# Headless Legends MMO zone server — a self-contained dedicated server image.
#
#   docker build -t legends-zone .
#   docker run -e SUPABASE_SERVICE_KEY=<service_role> -p 7777:7777/udp legends-zone
#   docker run -e SUPABASE_SERVICE_KEY=<key> -e PORT=8000 -p 8000:8000/udp legends-zone
#
# SUPABASE_SERVICE_KEY is required for loot/equipment to persist (the server writes the inventory
# table; clients can't). Without it the server still runs but warns and loot won't save.
# Players connect with:  godot --path . -- --online <host-ip> --dtls
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
EXPOSE 7777/udp

# DTLS is on by default for an exposed/container deploy; clients must also pass --dtls.
# Set BIND (e.g. fly-global-services) for platforms that require a specific UDP bind address.
CMD ["sh", "-c", "godot --headless --path /app -- --server --dtls --port ${PORT} ${BIND:+--bind ${BIND}}"]
