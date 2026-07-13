#!/usr/bin/env python3
"""Generate seamless, tileable ground albedo textures (turf + scrapyard concrete) for the field plane.
Self-authored (no external/CC0 asset) → no license/approval concern. Tileable by construction:
 - low-frequency variation = sum of INTEGER-frequency sinusoids (periodic over the tile, so edges match)
 - fine grain = a hash of (px,py) ONLY (repeats identically when the tile repeats → no seam)
Output: models/meshy/props/ground/{turf,scrapyard}_albedo.png  (per owner: keep textures in the props folder)
"""
import math, os
from PIL import Image

N = 256  # tile resolution

def phash(px, py):
    n = (px * 374761393 + py * 668265263) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return n / 0xFFFFFFFF

def smooth(x, y, octs):
    v = 0.0
    for fx, fy, ph, amp in octs:
        v += amp * math.sin(2.0 * math.pi * (fx * x + fy * y) + ph)
    return v

def build(path, octs, dark, light, stripe_amp=0.0, stripe_freq=4.0, grain=0.28, tint_jitter=0.0):
    amp_sum = sum(o[3] for o in octs)
    img = Image.new("RGB", (N, N))
    px = img.load()
    for j in range(N):
        y = j / N
        for i in range(N):
            x = i / N
            s = (smooth(x, y, octs) / amp_sum) * 0.5 + 0.5          # [0,1] tileable low-freq
            g = phash(i, j)                                          # [0,1] tileable grain
            v = (1.0 - grain) * s + grain * g
            if stripe_amp:                                          # subtle mow stripes (turf)
                v += stripe_amp * math.sin(2.0 * math.pi * stripe_freq * y)
            v = min(1.0, max(0.0, v))
            r = int(dark[0] + (light[0] - dark[0]) * v)
            gg = int(dark[1] + (light[1] - dark[1]) * v)
            b = int(dark[2] + (light[2] - dark[2]) * v)
            if tint_jitter:                                        # per-pixel warm/cool speckle (scrapyard)
                t = (phash(i + 7, j + 13) - 0.5) * 2.0 * tint_jitter
                r = min(255, max(0, int(r + t))); gg = min(255, max(0, int(gg + t * 0.6)))
            px[i, j] = (r, gg, b)
    img.save(path)
    print("wrote", path, img.size)

OUT = os.path.join(os.path.dirname(__file__), "..", "models", "meshy", "props", "ground")
os.makedirs(OUT, exist_ok=True)

# Turf: mown pitch grass — mottled green with faint stripes.
build(
    os.path.join(OUT, "turf_albedo.png"),
    octs=[(1,0,0.3,0.5),(0,1,1.1,0.5),(2,1,2.0,0.3),(1,2,0.7,0.3),(3,2,1.5,0.2),
          (2,3,2.5,0.2),(5,3,0.5,0.13),(3,5,1.9,0.13),(7,6,1.0,0.08),(9,8,2.2,0.06)],
    dark=(38,64,32), light=(96,140,70), stripe_amp=0.06, stripe_freq=5.0, grain=0.30)

# Scrapyard: worn industrial concrete — grey-brown mottle with warm/cool speckle.
build(
    os.path.join(OUT, "scrapyard_albedo.png"),
    octs=[(1,0,0.9,0.5),(0,1,0.2,0.5),(2,1,1.4,0.35),(1,2,2.3,0.35),(3,3,0.6,0.22),
          (4,2,1.8,0.18),(2,5,0.9,0.15),(6,5,2.1,0.10),(8,7,0.4,0.07),(11,9,1.6,0.05)],
    dark=(58,55,50), light=(126,120,110), grain=0.34, tint_jitter=14.0)
