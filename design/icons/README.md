# Ratchet icon variants

**Shipped:** the curve bezel, tooth-rise 5, `long-thin` hands — reimplemented
in Swift at `Sources/RatchetCore/RatchetIcon.swift` and used by
`StatusItemController` for the tray glyph and dialog icons. This directory's
`generate.py` remains the design-exploration tool (many bezel/hand/rise
combinations as SVG); it is not read at runtime and the two are kept in sync
by hand — see the doc comment atop `RatchetIcon.swift`.

Also produced from the same Swift code, via `swift run IconExporter`:

- `Resources/AppIcon.icns` (repo root) — built by piping the exporter's
  `.iconset` output through `iconutil`; wired into `scripts/build-app.sh`.
- `freeagent-icon.png` in this directory — the green-tile treatment at 512px,
  for use in FreeAgent's own UI (a connected-app listing, etc.). Chosen over a
  transparent mark-only asset because it's self-contained and safe on any
  background; ask if a transparent version is needed instead.

Regenerate with:

```bash
python3 design/icons/generate.py
```

`preview.html` shows every variant at 16/18/22/32/64, idle and tracking, with
Dock tiles and a simulated menu bar.

## The mark

A clock face inside a ratchet bezel, on a 64×64 grid. Tracking state is
**green rim and teeth, white hands**.

Files:

- `<bezel>-<hands>-<state>.svg` — the current focus: both bezels at rise 5,
  with `thin` / `long` / `long-thin` hands
- `<bezel>-rise<n>-<state>.svg` — tooth-height reference, with `base` hands

State is `base` (idle), `green` (tracking) or `app` (Dock tile).

## Bezels

Both keep six teeth, tips at r 31.0, and a constant rim band of 7.0. Tooth
height (`rise`) pushes the ring and the inner edge inward together, so bigger
teeth are paid for out of face area — at rise 8 the face is r 16, half the
icon, and the hands get noticeably small.

- **`notch`** — a plain annulus with triangular teeth sitting on it, so there
  is a corner where each tooth meets the ring. Static, mechanical. The teeth
  widen with height; at fixed angular width, taller teeth go spiky.
- **`curve`** — one continuous outline: six straight radial tooth faces and
  six curved slopes that leave the ring tangentially, so the faces are the only
  hard edges. Reads as motion rather than machinery.

Rise 5 is the current setting (`DEFAULT_RISE`). Rise 4-6 all hold up; at
rise 8 the notch bezel looks ragged at 16px and the curve bezel's hooks close
up the ring between teeth, which defeats the smooth-outline idea.

`SLOPE_EASE` (curve only) sets how long a slope hugs the ring before lifting.
Below ~2.0 the teeth merge and the smooth ring disappears; 2.6 leaves the
clearest run of ring.

## Hands

All round-capped. Lengths in `HAND_VARIANTS` are fractions of the face radius
at which the **visible tip** lands — the outside of the round cap, not the line
endpoint. Measured the other way, a 0.94 minute hand overlapped the rim by half
its stroke width instead of reaching toward it. `TIP_CLEARANCE` holds a gap
between cap and rim regardless of the fractions given.

`FOCUS_HANDS` picks which variants get emitted for both bezels; the rest of
`HAND_VARIANTS` (`base`, `bold`, `hub`, `contrast`, `ten-ten`) stay defined and
can be swapped in there.

| Variant | Width | Hour / minute tip |
|---|---|---|
| `thin` | 3.9 | 0.58 / 0.86 |
| `long` | 4.6 | 0.70 / 0.94 |
| `long-thin` | 4.0 | 0.70 / 0.94 |

Below about 32px these converge — hand choice is largely a Dock-size decision.

## Palette

| Token | Hex | Role |
|---|---|---|
| body | `#FFFFFF` | The mark |
| accent | `#4CAF3E` | Rim + teeth when tracking |
| field | `#3E9A31` | Dock tile background |

## Light menu bars

The idle mark ships as a template image (`isTemplate = true`), so macOS
handles light/dark contrast automatically. The tracking variant can't be a
template — the green would be flattened away — so it needs the hand color
picked explicitly: **fixed**, `StatusItemController.isDarkMenuBar` reads
`statusItem.button.effectiveAppearance` and picks white hands on a dark bar,
black on a light one, via a KVO observer that redraws the icon if the user
flips System Appearance while a timer is running.

## The Dock tile texture

`RatchetIcon.appTile` (used for the `.icns`, the dialog icon, and
`freeagent-icon.png`) has a gradient/grain/engraved-mark treatment, ported by
hand from `generate_textured.py`'s "soft gradient" SVG variant rather than
rasterized from it — **cairosvg can't render the SVG's filter chain**
(`feComponentTransfer`, `feTurbulence`), so a direct rasterize comes out flat.
`generate_textured.py` remains the design reference for tuning this further;
`RatchetIcon.swift`'s texture section is the thing that actually ships.

One CoreGraphics gotcha worth knowing if you touch this: **`CGContext.setShadow`'s
`offset`/`blur` don't scale with the CTM** the way fills, strokes, and gradients
do. Every shadow-based effect here (`drawInsetShadow`, used for both the tile's
edge shading and the mark's engraving) is drawn inside a scaled coordinate
space (grid units × `size/64`), so its `offset`/`blur` are pre-multiplied by
that same scale before being passed to `setShadow` — skip that and the effect
renders as a near-invisible fraction of a device pixel at real icon sizes,
despite looking correct in isolated testing at 1:1 scale.
