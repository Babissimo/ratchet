#!/usr/bin/env python3
"""Generate icon variants for Ratchet: a clock face inside a ratchet bezel.

Axes:

  * bezel -- "notch" (teeth sitting on a smooth circle) or "curve" (one
             outline: six straight tooth faces, six curves easing tangentially
             back into the ring).
  * rise  -- tooth height. The ring and inner edge move inward with it so the
             band stays constant, which is why bigger teeth cost face area.
  * hands -- round-capped variants differing in weight, length and pose.

Tracking state is green rim + teeth with white hands.

Run:  python3 design/icons/generate.py
"""
import math
import os

OUT = os.path.dirname(os.path.abspath(__file__))

WHITE = "#FFFFFF"
GREEN = "#4CAF3E"        # FreeAgent-ish mid green, the accent
GREEN_FIELD = "#3E9A31"  # slightly deeper, for large-icon backgrounds

CX = CY = 32.0

R_TIP = 31.0         # tooth tips; the outer limit of the 64x64 grid
BAND = 7.0           # rim thickness, held constant across tooth sizes
N_TEETH = 6
PHASE = -14.0
TOOTH_WIDTH = 0.36   # notch bezel: fraction of a pitch spent ramping up
SLOPE_EASE = 2.6     # curve bezel: higher hugs the ring longer before lifting

RISES = (4.0, 5.0, 6.0, 8.0)
DEFAULT_RISE = 5.0


class Geom:
    """Radii for a given tooth height."""

    def __init__(self, rise):
        self.rise = rise
        self.tip = R_TIP
        self.body = R_TIP - rise
        self.inner = R_TIP - rise - BAND


def polar(r, deg):
    """Point at radius r, angle deg measured clockwise from 12 o'clock."""
    a = math.radians(deg - 90)
    return (CX + r * math.cos(a), CY + r * math.sin(a))


def path(pts, close=True):
    d = "M " + " L ".join(f"{x:.2f},{y:.2f}" for x, y in pts)
    return d + " Z" if close else d


def circle_subpath(r):
    return (f"M {CX - r:.2f},{CY:.2f} "
            f"A {r:.2f},{r:.2f} 0 1,1 {CX + r:.2f},{CY:.2f} "
            f"A {r:.2f},{r:.2f} 0 1,1 {CX - r:.2f},{CY:.2f} Z")


# --------------------------------------------------------------------------
# Bezels
# --------------------------------------------------------------------------
def bezel_notch(g, color):
    """Smooth annulus with triangular teeth drawn on top.

    Tooth bases sink below the ring so the two merge without a seam. The
    angular width grows with tooth height, otherwise taller teeth go spiky.
    """
    pitch = 360.0 / N_TEETH
    span = pitch * TOOTH_WIDTH * (1 + 0.16 * (g.rise - 4.0))
    ring = f"{circle_subpath(g.body)} {circle_subpath(g.inner)}"
    teeth = []
    for i in range(N_TEETH):
        a = PHASE + i * pitch
        teeth.append(path([
            polar(g.body - 1.2, a + pitch - span),
            polar(g.tip, a + pitch - span * 0.20),   # short land keeps the
            polar(g.tip, a + pitch),                 # tip from going needly
            polar(g.body - 1.2, a + pitch),
        ]))
    return (f'<path d="{ring}" fill="{color}" fill-rule="evenodd"/>\n  '
            f'<path d="{" ".join(teeth)}" fill="{color}"/>')


def bezel_curve(g, color, steps=32):
    """One continuous outline: six straight tooth faces, six curved slopes.

    Each slope leaves the ring tangentially -- radius eases off `body` with
    zero initial slope -- so the only hard edges left are the radial faces.
    """
    pitch = 360.0 / N_TEETH
    pts = []
    for i in range(N_TEETH):
        a = PHASE + i * pitch
        pts.append(polar(g.tip, a))       # tip
        pts.append(polar(g.body, a))      # straight radial face
        for j in range(1, steps + 1):     # curved slope out to the next tip
            u = j / steps
            pts.append(polar(g.body + g.rise * u ** SLOPE_EASE, a + pitch * u))
    return (f'<path d="{path(pts)} {circle_subpath(g.inner)}" '
            f'fill="{color}" fill-rule="evenodd"/>')


BEZELS = {"notch": bezel_notch, "curve": bezel_curve}


# --------------------------------------------------------------------------
# Hands -- all round-capped, varying weight, length and pose.
# --------------------------------------------------------------------------
def _stroke(length, deg, width, color):
    x1, y1 = polar(length, deg)
    return (f'<line x1="{CX:.2f}" y1="{CY:.2f}" x2="{x1:.2f}" y2="{y1:.2f}" '
            f'stroke="{color}" stroke-width="{width}" stroke-linecap="round"/>')


# Fractions are where the *visible* tip lands -- the outside of the round cap,
# not the line endpoint. Measured the other way, a 0.94 minute hand overlapped
# the rim by half its stroke width instead of reaching toward it.
HAND_VARIANTS = {
    #  name:        width, hour tip, min tip, hub, hour deg, min deg
    "base":        (4.6, 0.58, 0.86, 0.0, 120.0, 0.0),
    "thin":        (3.9, 0.58, 0.86, 0.0, 120.0, 0.0),
    "bold":        (5.4, 0.58, 0.86, 0.0, 120.0, 0.0),
    "long":        (4.6, 0.70, 0.94, 0.0, 120.0, 0.0),
    "long-thin":   (4.0, 0.70, 0.94, 0.0, 120.0, 0.0),
    "hub":         (4.6, 0.58, 0.86, 3.0, 120.0, 0.0),
    "contrast":    (4.6, 0.52, 0.94, 0.0, 120.0, 0.0),
    "ten-ten":     (4.6, 0.58, 0.86, 0.0, 300.0, 60.0),
}

DEFAULT_HANDS = "base"
FOCUS_HANDS = ("thin", "long", "long-thin")
TIP_CLEARANCE = 0.8   # keep the cap off the rim


def hands(variant, r, color):
    w, hf, mf, hub, hd, md = HAND_VARIANTS[variant]

    def length(frac):
        tip = min(frac * r, r - TIP_CLEARANCE)
        return max(tip - w / 2, 1.0)

    out = [_stroke(length(hf), hd, w, color), _stroke(length(mf), md, w, color)]
    if hub:
        out.append(f'<circle cx="{CX}" cy="{CY}" r="{hub}" fill="{color}"/>')
    return "\n  ".join(out)


# --------------------------------------------------------------------------
def mark(bezel, rise, hand_variant, bezel_c=WHITE, hand_c=WHITE):
    g = Geom(rise)
    return (BEZELS[bezel](g, bezel_c) + "\n  "
            + hands(hand_variant, g.inner, hand_c))


def svg(body, size=64):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" '
            f'width="{size}" height="{size}" fill="none">\n  {body}\n</svg>\n')


def app_icon(bezel, rise, hand_variant):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" '
            'width="512" height="512" fill="none">\n'
            f'  <rect x="2" y="2" width="60" height="60" rx="15" '
            f'fill="{GREEN_FIELD}"/>\n'
            '  <g transform="translate(32 32) scale(0.70) translate(-32 -32)">\n'
            f'  {mark(bezel, rise, hand_variant)}\n  </g>\n</svg>\n')


def main():
    n = 0
    for bezel in BEZELS:
        for rise in RISES:
            stem = f"{bezel}-rise{rise:g}"
            for suffix, body in (
                ("base", mark(bezel, rise, DEFAULT_HANDS)),
                ("green", mark(bezel, rise, DEFAULT_HANDS, GREEN, WHITE)),
            ):
                with open(os.path.join(OUT, f"{stem}-{suffix}.svg"), "w") as f:
                    f.write(svg(body))
            with open(os.path.join(OUT, f"{stem}-app.svg"), "w") as f:
                f.write(app_icon(bezel, rise, DEFAULT_HANDS))
            n += 1

    # Hand studies, both bezels at the default tooth height.
    for bezel in BEZELS:
        for variant in FOCUS_HANDS:
            stem = f"{bezel}-{variant}"
            for suffix, body in (
                ("base", mark(bezel, DEFAULT_RISE, variant)),
                ("green", mark(bezel, DEFAULT_RISE, variant, GREEN, WHITE)),
            ):
                with open(os.path.join(OUT, f"{stem}-{suffix}.svg"), "w") as f:
                    f.write(svg(body))
            with open(os.path.join(OUT, f"{stem}-app.svg"), "w") as f:
                f.write(app_icon(bezel, DEFAULT_RISE, variant))

    print(f"{n} bezel/rise combos, "
          f"{len(BEZELS) * len(FOCUS_HANDS)} hand studies at rise "
          f"{DEFAULT_RISE:g}")


if __name__ == "__main__":
    main()
