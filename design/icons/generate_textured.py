#!/usr/bin/env python3
"""Textured app-icon exploration: gradient, grain, and depth on the Dock tile.

This is *not* wired into the shipped icon — `RatchetIcon.swift` stays flat, to
match how status-bar/Dock icons are conventionally drawn. This is purely for
picking a direction on the big (512/1024) Finder/Dock tile, which has room for
more visual richness than a 16px tray glyph does.

Reuses the shipped mark's geometry from `generate.py` (curve bezel, rise 5,
long-thin hands) rather than re-deriving it, so the shape itself can't drift
from what actually ships.

Run:  python3 design/icons/generate_textured.py
"""
import os

import generate as base

OUT = os.path.dirname(os.path.abspath(__file__))

WHITE = base.WHITE
DARK_GREEN = "#1F5A19"   # shadow/grain-dark end of the gradients below


def mark_group(extra_attrs=""):
    """The shipped mark (bezel + hands), white, at the same scale/position
    `app_icon()` uses -- translate(32 32) scale(0.70) translate(-32 -32)."""
    body = base.mark("curve", base.DEFAULT_RISE, "long-thin", WHITE, WHITE)
    return (f'<g transform="translate(32 32) scale(0.70) translate(-32 -32)" {extra_attrs}>\n'
            f'  {body}\n  </g>')


def grain_filter(fid, base_freq=1.1, octaves=2, seed=7):
    """Fine monochrome speckle: turbulence's luminance becomes alpha, RGB
    zeroed, so it composites as black speckle at a controllable opacity."""
    return f'''<filter id="{fid}" x="-5%" y="-5%" width="110%" height="110%">
    <feTurbulence type="fractalNoise" baseFrequency="{base_freq}" numOctaves="{octaves}" seed="{seed}" result="noise"/>
    <feColorMatrix in="noise" type="matrix" values="
      0 0 0 0 0
      0 0 0 0 0
      0 0 0 0 0
      0.6 0.6 0.6 0 -0.2" result="grain"/>
  </filter>'''


def inner_shadow_filter(fid, blur=3.2, dy=1.4, opacity=0.45, color="#000000"):
    """Classic inner-shadow recipe: invert source alpha, blur, offset, flood,
    clip to the offset blur, then clip *that* to the source shape before
    compositing over it -- without this last clip, the inverted alpha (opaque
    everywhere outside the original shape) fills the whole filter region
    instead of staying inside the rounded rect."""
    return f'''<filter id="{fid}" x="-20%" y="-20%" width="140%" height="140%">
    <feComponentTransfer in="SourceAlpha" result="inverted">
      <feFuncA type="table" tableValues="1 0"/>
    </feComponentTransfer>
    <feGaussianBlur in="inverted" stdDeviation="{blur}" result="blurred"/>
    <feOffset in="blurred" dx="0" dy="{dy}" result="offset"/>
    <feFlood flood-color="{color}" flood-opacity="{opacity}" result="color"/>
    <feComposite in="color" in2="offset" operator="in" result="shadow"/>
    <feComposite in="shadow" in2="SourceAlpha" operator="in" result="clippedShadow"/>
    <feComposite in="clippedShadow" in2="SourceGraphic" operator="over"/>
  </filter>'''


def drop_shadow_filter(fid, blur=2.0, dy=1.0, opacity=0.35):
    return f'''<filter id="{fid}" x="-40%" y="-40%" width="180%" height="180%">
    <feDropShadow dx="0" dy="{dy}" stdDeviation="{blur}" flood-color="#000000" flood-opacity="{opacity}"/>
  </filter>'''


def engraved_mark_filter(fid, shadow_color="#1F5A19", shadow_opacity=0.55, shadow_blur=1.0, shadow_dy=1.0,
                          highlight_color="#FFFFFF", highlight_opacity=0.40, highlight_blur=0.8, highlight_dy=-0.6):
    """Makes the white mark look pressed *into* the surface rather than lifted
    off it: a dark inner shadow along its upper inner edge (as if the material
    above it casts a shadow down into the groove) and a faint light catch
    along its lower inner edge (ambient light bouncing back up), both built
    with the same invert/blur/offset/flood/clip recipe as `inner_shadow_filter`
    but run twice -- once dark and downward, once light and upward -- and
    clipped to the mark's own alpha rather than a background rect's."""
    return f'''<filter id="{fid}" x="-30%" y="-30%" width="160%" height="160%">
    <feComponentTransfer in="SourceAlpha" result="inverted">
      <feFuncA type="table" tableValues="1 0"/>
    </feComponentTransfer>
    <feGaussianBlur in="inverted" stdDeviation="{shadow_blur}" result="sBlur"/>
    <feOffset in="sBlur" dx="0" dy="{shadow_dy}" result="sOffset"/>
    <feFlood flood-color="{shadow_color}" flood-opacity="{shadow_opacity}" result="sColor"/>
    <feComposite in="sColor" in2="sOffset" operator="in" result="sRaw"/>
    <feComposite in="sRaw" in2="SourceAlpha" operator="in" result="shadow"/>
    <feGaussianBlur in="inverted" stdDeviation="{highlight_blur}" result="hBlur"/>
    <feOffset in="hBlur" dx="0" dy="{highlight_dy}" result="hOffset"/>
    <feFlood flood-color="{highlight_color}" flood-opacity="{highlight_opacity}" result="hColor"/>
    <feComposite in="hColor" in2="hOffset" operator="in" result="hRaw"/>
    <feComposite in="hRaw" in2="SourceAlpha" operator="in" result="highlight"/>
    <feMerge>
      <feMergeNode in="SourceGraphic"/>
      <feMergeNode in="shadow"/>
      <feMergeNode in="highlight"/>
    </feMerge>
  </filter>'''


def tile_bg(fill_id):
    return (f'<rect x="2" y="2" width="60" height="60" rx="15" fill="url(#{fill_id})"/>')


def svg(defs, body, size=512):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="{size}" height="{size}">
  <defs>
{defs}
  </defs>
  {body}
</svg>
'''


# --------------------------------------------------------------------------
# A. Soft Gradient -- restrained: gentle vertical gradient, faint grain, a
#    light lift shadow under the mark. Closest to the current flat tile.
# --------------------------------------------------------------------------
def variant_soft_gradient():
    # Three-point read: SVG's linearGradient only carries stops along a single
    # axis, so the top-right lighter patch is a second, radial gradient
    # layered on top of the plain vertical one rather than a true 3-stop
    # gradient -- this is the standard way to fake an off-axis highlight.
    defs = f'''
    <linearGradient id="softGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#63C853"/>
      <stop offset="1" stop-color="{base.GREEN_FIELD}"/>
    </linearGradient>
    <radialGradient id="softHighlight" cx="0.80" cy="0.16" r="0.62">
      <stop offset="0" stop-color="#B6F0A6" stop-opacity="0.85"/>
      <stop offset="1" stop-color="#B6F0A6" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="softSideVignette" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#0E2E0B" stop-opacity="0.32"/>
      <stop offset="0.16" stop-color="#0E2E0B" stop-opacity="0"/>
      <stop offset="0.84" stop-color="#0E2E0B" stop-opacity="0"/>
      <stop offset="1" stop-color="#0E2E0B" stop-opacity="0.32"/>
    </linearGradient>
    <clipPath id="softClip">
      <rect x="2" y="2" width="60" height="60" rx="15"/>
    </clipPath>
    {grain_filter("softGrain", base_freq=1.3, octaves=2)}
    {inner_shadow_filter("softEdgeShadow", blur=3.0, dy=3.2, opacity=0.38, color="#0E2E0B")}
    {engraved_mark_filter("softEngrave")}
  '''
    body = (f'<g filter="url(#softEdgeShadow)">{tile_bg("softGrad")}</g>\n  '
            f'<g clip-path="url(#softClip)">\n'
            f'    <rect x="2" y="2" width="60" height="60" fill="url(#softHighlight)"/>\n'
            f'    <rect x="2" y="2" width="60" height="60" fill="url(#softSideVignette)"/>\n'
            f'    <rect x="2" y="2" width="60" height="60" filter="url(#softGrain)" opacity="0.08"/>\n'
            f'  </g>\n  '
            f'{mark_group('filter="url(#softEngrave)"')}')
    return svg(defs, body)


# --------------------------------------------------------------------------
# B. Glass -- stronger gradient, a blurred gloss highlight near the top like
#    old-school glossy icons, grain, mark lifted with a shadow.
# --------------------------------------------------------------------------
def variant_glass():
    defs = f'''
    <linearGradient id="glassGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#7ADB69"/>
      <stop offset="0.55" stop-color="#4CAF3E"/>
      <stop offset="1" stop-color="#2E7A26"/>
    </linearGradient>
    <linearGradient id="glossGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="glassClip">
      <rect x="2" y="2" width="60" height="60" rx="15"/>
    </clipPath>
    {grain_filter("glassGrain", base_freq=1.2, octaves=2)}
    {drop_shadow_filter("glassShadow", blur=1.8, dy=1.0, opacity=0.35)}
  '''
    body = (f'{tile_bg("glassGrad")}\n  '
            f'<g clip-path="url(#glassClip)">\n'
            f'    <ellipse cx="32" cy="10" rx="34" ry="20" fill="url(#glossGrad)"/>\n'
            f'    <rect x="2" y="2" width="60" height="60" filter="url(#glassGrain)" opacity="0.16"/>\n'
            f'  </g>\n  '
            f'{mark_group('filter="url(#glassShadow)"')}')
    return svg(defs, body)


# --------------------------------------------------------------------------
# C. Inset -- the tile reads as a recessed surface (inner shadow at the
#    edges) with the mark sitting slightly proud of it (soft outer glow).
# --------------------------------------------------------------------------
def variant_inset():
    defs = f'''
    <linearGradient id="insetGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#57B848"/>
      <stop offset="1" stop-color="#356B2C"/>
    </linearGradient>
    {grain_filter("insetGrain", base_freq=1.4, octaves=2)}
    {inner_shadow_filter("insetShadow", blur=3.4, dy=1.6, opacity=0.5)}
    <filter id="markGlow" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="1.1" result="blur"/>
      <feFlood flood-color="#FFFFFF" flood-opacity="0.55"/>
      <feComposite in2="blur" operator="in" result="glow"/>
      <feMerge>
        <feMergeNode in="glow"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  '''
    body = (f'<g filter="url(#insetShadow)">{tile_bg("insetGrad")}</g>\n  '
            f'<rect x="2" y="2" width="60" height="60" rx="15" filter="url(#insetGrain)" opacity="0.18"/>\n  '
            f'{mark_group('filter="url(#markGlow)"')}')
    return svg(defs, body)


# --------------------------------------------------------------------------
# D. Deep -- moodier, higher-contrast gradient toward near-black at the
#    bottom, heavier grain, a stronger/longer shadow under the mark.
# --------------------------------------------------------------------------
def variant_deep():
    defs = f'''
    <linearGradient id="deepGrad" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6FD35D"/>
      <stop offset="0.5" stop-color="#3C9430"/>
      <stop offset="1" stop-color="#123510"/>
    </linearGradient>
    {grain_filter("deepGrain", base_freq=1.0, octaves=3)}
    {drop_shadow_filter("deepShadow", blur=2.6, dy=1.8, opacity=0.5)}
  '''
    body = (f'{tile_bg("deepGrad")}\n  '
            f'<rect x="2" y="2" width="60" height="60" rx="15" filter="url(#deepGrain)" opacity="0.22"/>\n  '
            f'{mark_group('filter="url(#deepShadow)"')}')
    return svg(defs, body)


VARIANTS = {
    "soft-gradient": variant_soft_gradient,
    "glass": variant_glass,
    "inset": variant_inset,
    "deep": variant_deep,
}


def main():
    for name, fn in VARIANTS.items():
        path = os.path.join(OUT, f"texture-{name}.svg")
        with open(path, "w") as f:
            f.write(fn())
        print(path)


if __name__ == "__main__":
    main()
