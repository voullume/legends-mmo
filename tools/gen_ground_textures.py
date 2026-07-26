#!/usr/bin/env python3
"""Generate seamless, tileable ground albedo textures for the field plane.
Self-authored (no external/CC0 asset) → no license/approval concern. Tileable by construction:
 - low-frequency variation = sum of INTEGER-frequency sinusoids (periodic over the tile, so edges match)
 - fine grain = a hash of (px,py) ONLY (repeats identically when the tile repeats → no seam)
Output: models/meshy/props/ground/*_albedo.png  (per owner: keep textures in the props folder)
Two generations of build fn: build() = the original four (turf/scrapyard/rival_clay/court — byte-stable,
do not touch); build_wild() = the Wildlife-Expanse art pass set (adds per-channel speckle + a tileable
multi-octave patch mask for organic trails/worn patches — INTEGER mask freqs only, same seam rule).
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

# Rival clay (Phase 8, the Away Circuit): raked ballpark clay — warm red-brown mottle with faint
# drag-line stripes (the groundskeeper's rake) + a dusty speckle. Reads instantly "not home turf".
build(
    os.path.join(OUT, "rival_clay_albedo.png"),
    octs=[(1,0,0.5,0.5),(0,1,1.7,0.5),(2,1,0.8,0.32),(1,2,1.9,0.32),(3,2,2.6,0.2),
          (2,4,0.4,0.16),(5,4,1.2,0.11),(7,5,2.0,0.08),(9,8,0.9,0.06)],
    dark=(122,64,44), light=(188,120,84), stripe_amp=0.045, stripe_freq=6.0, grain=0.30, tint_jitter=10.0)

# Championship court (Phase 8 S3, the Finals): polished hardwood — warm tan with strong plank
# stripes and a light lacquer speckle. The capstone district reads indoor/prestige.
build(
    os.path.join(OUT, "court_albedo.png"),
    octs=[(1,0,1.1,0.5),(0,1,0.3,0.5),(2,1,2.2,0.3),(1,3,0.9,0.24),(4,2,1.6,0.14),
          (3,5,0.5,0.10),(6,7,1.8,0.07),(10,9,2.4,0.05)],
    dark=(146,100,58), light=(206,160,104), stripe_amp=0.085, stripe_freq=10.0, grain=0.22, tint_jitter=6.0)

# ---- Wildlife Expanse art pass (owner-approved palettes, 2026-07-21) --------------------------------
# build_wild extends the same construction with (a) jitter = PER-CHANNEL speckle amplitudes and
# (b) patch = (dark2, light2, mask_octs, thresh, band): a second palette blended in where a tileable
# multi-octave mask exceeds thresh — smoothstepped over `band` with hash-roughened edges, so trails/
# worn patches read organic instead of as a dot lattice. Mask freqs MUST be integers (seam rule).

def build_wild(path, octs, dark, light, stripe_amp=0.0, stripe_freq=4.0, grain=0.28,
               jitter=(0.0, 0.0, 0.0), patch=None):
    amp_sum = sum(o[3] for o in octs)
    img = Image.new("RGB", (N, N))
    px = img.load()
    for j in range(N):
        y = j / N
        for i in range(N):
            x = i / N
            s = (smooth(x, y, octs) / amp_sum) * 0.5 + 0.5
            g = phash(i, j)
            v = (1.0 - grain) * s + grain * g
            if stripe_amp:
                v += stripe_amp * math.sin(2.0 * math.pi * stripe_freq * y)
            v = min(1.0, max(0.0, v))
            d, l = dark, light
            if patch:
                d2, l2, mask_octs, thresh, band = patch
                masum = sum(o[3] for o in mask_octs)
                m = (smooth(x, y, mask_octs) / masum) * 0.5 + 0.5
                m += (phash(i + 31, j + 57) - 0.5) * 0.10   # roughen the patch edge
                t = min(1.0, max(0.0, (m - thresh) / band))
                w = t * t * (3.0 - 2.0 * t)                 # smoothstep
                if w > 0.0:
                    d = tuple(int(d[k] + (d2[k] - d[k]) * w) for k in range(3))
                    l = tuple(int(l[k] + (l2[k] - l[k]) * w) for k in range(3))
            r = d[0] + (l[0] - d[0]) * v
            gg = d[1] + (l[1] - d[1]) * v
            b = d[2] + (l[2] - d[2]) * v
            if any(jitter):
                t = (phash(i + 7, j + 13) - 0.5) * 2.0
                r += t * jitter[0]; gg += t * jitter[1]; b += t * jitter[2]
            px[i, j] = (min(255, max(0, int(r))), min(255, max(0, int(gg))), min(255, max(0, int(b))))
    img.save(path)
    print("wrote", path, img.size)

# Trampled Range (away_1/2/3): dry herd-trampled savanna — tan-green with meandering green game
# trails (low-freq stripes + patch mask) and a dust speckle. Fits the grazer/Old Bull herds; the tan
# base keeps the green wildlife mobs and loot beams high-contrast.
build_wild(
    os.path.join(OUT, "wildrange_albedo.png"),
    octs=[(1,0,1.9,0.5),(0,1,0.6,0.5),(2,1,1.2,0.32),(1,2,0.2,0.32),(3,3,2.2,0.2),
          (4,2,0.8,0.15),(2,5,1.7,0.11),(6,5,0.3,0.08),(8,7,2.6,0.06)],
    dark=(86,76,40), light=(156,144,88), stripe_amp=0.05, stripe_freq=3.0, grain=0.32,
    jitter=(12.0,8.0,2.0), patch=((52,62,26),(112,124,54),
        [(1,1,0.9,0.5),(2,1,2.0,0.4),(1,3,0.4,0.3),(3,2,1.3,0.25),(5,4,2.4,0.15)],0.62,0.14))

# Howler's Den (away_boss): packed pale dirt with claw drag-lines (the stripe pass reads as drag
# marks, not mowing) + a bone-fleck speckle. Bright enough that telegraphs/hazard zones stay crisp.
build_wild(
    os.path.join(OUT, "howler_den_albedo.png"),
    octs=[(1,0,1.6,0.5),(0,1,0.4,0.5),(2,1,2.7,0.3),(1,2,1.2,0.3),(3,2,0.6,0.2),
          (2,4,1.9,0.15),(5,4,2.3,0.1),(7,6,0.9,0.07)],
    dark=(66,50,36), light=(138,114,84), stripe_amp=0.06, stripe_freq=7.0, grain=0.33,
    jitter=(10.0,10.0,8.0))

# Base Camp (basecamp): packed warm campsite earth — a deliberate clearing in the wilds; maximum
# contrast with the range outside, and the service pads pop against it.
build_wild(
    os.path.join(OUT, "basecamp_albedo.png"),
    octs=[(1,0,2.0,0.5),(0,1,1.3,0.5),(2,1,0.7,0.32),(1,2,1.8,0.32),(3,2,2.4,0.2),
          (2,4,1.0,0.15),(5,4,0.4,0.1),(7,5,1.7,0.07),(9,8,2.2,0.05)],
    dark=(96,76,50), light=(166,138,98), grain=0.32, jitter=(10.0,6.0,2.0))

# Stadium Deck (away_3_concourse / away_3_roof — P4 climb): poured stadium concrete — cool gray
# slabs, expansion-joint seams (integer stripe freq), damp moss-stain patches (the reclamation
# creeping indoors), fine blue-leaning aggregate speckle. One texture serves both layers: the
# concourse tints it cool/dim, the roof near-white (tints live in Client._make_field_material).
build_wild(
    os.path.join(OUT, "stadium_deck_albedo.png"),
    octs=[(1,0,1.4,0.5),(0,1,0.8,0.5),(2,1,2.1,0.30),(1,2,0.5,0.28),(3,3,1.8,0.18),
          (5,3,0.7,0.12),(4,6,2.2,0.09),(8,7,1.1,0.06)],
    dark=(88,90,94), light=(158,160,166), stripe_amp=0.07, stripe_freq=8.0, grain=0.30,
    jitter=(6.0,6.0,8.0), patch=((64,78,58),(118,132,96),
        [(1,1,1.2,0.5),(2,2,0.3,0.4),(3,1,1.9,0.3),(4,3,0.8,0.2),(6,5,2.5,0.14)],0.66,0.12))
