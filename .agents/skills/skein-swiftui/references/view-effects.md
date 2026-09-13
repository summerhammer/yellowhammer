# Effects

Visual treatment applied to a view that is already laid out — materials, blur, shadow,
mask, blend. Companion to **view/theming** (the tokens a treatment is built from),
**view/animation** (animating an effect) and **view/layout** (the geometry being
decorated). Liquid Glass lives in **view/effects-glass**; immediate-mode drawing and
Metal shaders in **view/effects-canvas**.

## Pick a treatment

| Want | Use |
|---|---|
| A translucent surface over app content | `.background(.regularMaterial, in:)` |
| A translucent, light-reactive *control* surface | `.glassEffect(…)` → **view/effects-glass** |
| Lift a card off the background | `.shadow(radius:)` or a `.shadow(.drop(…))` fill |
| Soften a whole view (unfocused, redacted, behind a sheet) | `.blur(radius:)` |
| Clip content to a shape | `.clipShape(_:)` |
| Fade content out along an edge or gradient | `.mask { … }` |
| Punch a hole in a fill / knock text out of a shape | `.blendMode(.destinationOut)` + `.compositingGroup()` |
| An effect whose strength depends on the view's position | `.visualEffect { content, proxy in … }` |
| Mirror a hero image under the sidebar or bars | `.backgroundExtensionEffect()` |
| Draw hundreds of primitives | `Canvas` → **view/effects-canvas** |
| Per-pixel math no modifier expresses | `.colorEffect` / `.layerEffect` → **view/effects-canvas** |

Reach for the cheapest one that fits. Every effect below is a render-time filter: it does
not change layout, and the view keeps the size it had before the modifier.

## Rules

- **Effects are ordered.** A modifier applies to everything below it in the chain.
  `.shadow().clipShape()` clips the shadow away; `.clipShape().shadow()` casts a shadow of
  the clipped shape. `.blur()` before `.opacity()` is not the same picture as after.
- **Decorate with `.background` / `.overlay`, not `ZStack`.** A background never
  participates in sizing, so the decoration cannot push its own content around. A `ZStack`
  makes the decoration a layout sibling and the largest child wins.
- **Shape once, reuse everywhere.** Declare the corner shape as a single `let` and pass it
  to `.background(_:in:)`, `.clipShape` and `.contentShape`. Repeating
  `RoundedRectangle(cornerRadius: 12)` three times guarantees they drift apart.
- **Use `.rect(cornerRadius:)` and `.capsule` shorthand.** Shapes compose as `some Shape`
  in every effect API; the shorthands avoid the generic noise.
- **Concentric corners, not guessed ones.** A nested rounded rect should use
  `.rect(corners: .concentric)` so the inner radius tracks the outer one and the container
  shape the system chose. Hand-tuned inner radii break on every new device metric.
- **`.mask` takes alpha, not color.** The mask view's *opacity* is what survives. A black
  gradient and a white gradient mask identically; only `.opacity`/alpha differ.
- **Group before compositing.** `.opacity`, `.blendMode` and `.shadow` apply to each leaf
  independently unless you insert `.compositingGroup()`. Half-faded overlapping shapes
  showing their seams is the symptom.
- **Effects are not accessibility.** A blur, an overlay or a low-opacity treatment still
  leaves the content in the accessibility tree and still gets read. Pair a "disabled" look
  with `.disabled(true)`, and a decorative layer with `.accessibilityHidden(true)`. See
  **system/accessibility**.
- **Respect Reduce Transparency and Increase Contrast.** Read
  `@Environment(\.accessibilityReduceTransparency)` and swap a material for an opaque
  token fill; heavy translucency over busy content fails contrast.
- **Don't animate a blur or shadow radius per frame.** Both re-rasterize on every value.
  Animate `opacity` between two pre-composed layers instead, or cross-fade. See
  **view/animation**.

## Materials

`Material` is a `ShapeStyle`, so it goes anywhere a fill does — most usefully
`.background(_:in:)`.

```swift
let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

VStack(alignment: .leading, spacing: 4) {
    Text(landmark.name).font(.headline)
    Text(landmark.region).font(.subheadline).foregroundStyle(.secondary)
}
.padding()
.background(.regularMaterial, in: shape)
```

Five thicknesses — `.ultraThin`, `.thin`, `.regular`, `.thick`, `.ultraThick` — plus
`.bar` for toolbar-style chrome. Thicker lets less of the background through, and each
adapts to light and dark on its own.

- **A material blurs your app's content, not the screen behind it.** A widget over the
  Home Screen, or a window over another app, gets nothing to sample. There must be
  something of yours underneath or the material reads as flat grey.
- **Materials give you vibrancy for free — don't throw it away.** Foreground content over
  a material blends for contrast automatically. Setting an explicit
  `.foregroundStyle(Color…)` disables vibrancy; the hierarchical styles (`.primary`,
  `.secondary`, `.tertiary`) keep it. Prefer those.
- **Material or glass?** Material is a *surface* treatment for content that sits over your
  own content — cards, panels, legends, captions over an image. Liquid Glass is the
  *control* material: bars, floating actions, controls the system lifts above content.
  Don't hand-build one out of the other.
- **Never stack materials.** A material over a material compounds the blur into mud and
  re-samples twice. One translucent layer per depth.

## Blur

`.blur(radius:opaque:)` blurs the view itself, in place.

```swift
PreviewGrid()
    .blur(radius: isLocked ? 12 : 0)
    .animation(.smooth, value: isLocked)
```

- `opaque: true` skips the transparency in the blur math — use it when the view fills its
  bounds; it avoids the faded halo at the edges.
- A blur samples outside the view's bounds, so a blurred view inside a clipping container
  shows a soft edge. Clip after blurring if you want a hard one.
- For *censoring* content, prefer `.redacted(reason: .placeholder)` or `.privacySensitive()`
  — a blur is reversible-looking and not a privacy guarantee.

## Shadows

Two forms, and they are not interchangeable:

```swift
// View shadow — shadows the rendered view, including its text and subviews.
card.shadow(color: .black.opacity(0.15), radius: 8, y: 4)

// Style shadow — part of the fill, so it moves and animates with the shape.
shape.fill(.background.shadow(.drop(color: .black.opacity(0.15), radius: 8, y: 4)))
shape.fill(.surface.shadow(.inner(radius: 3, y: 1)))
```

- **Prefer the style shadow on a filled shape.** It is drawn by the fill, composites
  correctly, and `.inner` is only available this way.
- **Always give `y`, rarely `x`.** Light comes from above. A symmetric shadow
  (`radius:` alone) reads as a glow, not elevation.
- **Shadow with the theme, not with literals.** Elevation is a token — see
  **view/theming**. A `radius: 4` sprinkled across the codebase is how an app ends up with
  six elevations.
- **A shadow on a `List`/`LazyVStack` row is a per-row offscreen pass.** For many rows,
  use a background fill with a border instead, or accept one shadow on the container.
- Dark mode usually wants *less* shadow and more surface-color separation; a token with
  light/dark variants handles this, a literal does not.

## Masking and clipping

```swift
// Clip to a shape.
Image(.hero).resizable().scaledToFill()
    .frame(height: 220)
    .clipShape(.rect(cornerRadius: 20))

// Fade out the bottom of a scrolling column.
column.mask {
    LinearGradient(stops: [
        .init(color: .black, location: 0.8),
        .init(color: .clear, location: 1.0),
    ], startPoint: .top, endPoint: .bottom)
}

// Gradient-filled text, via the text as a mask.
LinearGradient(colors: [.pink, .orange], startPoint: .leading, endPoint: .trailing)
    .mask { Text("Summer").font(.largeTitle.bold()) }
```

- `.clipShape` is the fast path for a shape; `.mask` is for gradients, symbols and text.
  Don't mask with a shape you could clip with.
- **`.clipShape` is not `.contentShape`.** Clipping changes pixels, not the hit-test
  region. A clipped view still takes taps in its corners until you set `.contentShape`.
- For text, `.foregroundStyle(anyShapeStyle)` already accepts gradients and shaders —
  reach for the mask only when the fill needs to span views.
- A mask does not clip children's own effects; a shadow drawn below the mask is masked
  too.

## Blend and compositing

```swift
// Knock a shape out of a filled surface.
ZStack {
    Rectangle().fill(.regularMaterial)
    Circle().frame(width: 80).blendMode(.destinationOut)
}
.compositingGroup()
```

- `.compositingGroup()` flattens the subtree into one layer *before* the next effect, so
  `opacity`/`blendMode`/`shadow` treat it as a single image. Without it, `destinationOut`
  punches through everything behind it, not just the sibling.
- Keep blend modes to the few that are legible — `.multiply`, `.screen`, `.overlay`,
  `.destinationOut`, `.plusLighter`. The rest are hard to reason about across light/dark.
- `.drawingGroup()` also rasterizes, but *offscreen via Metal*, and is a performance tool,
  not a compositing one. It only captures views SwiftUI draws itself — text, shapes,
  images. UIKit/AppKit-backed views (map, web, video, most complex controls) render as a
  placeholder inside it. Measure before adding it; on a small tree it is a net loss.

## Geometry-driven effects

`.visualEffect` hands you the view's own `GeometryProxy` without a `GeometryReader`
wrapper and without a layout pass, so it is the right tool for anything that scales with
position.

```swift
card.visualEffect { content, proxy in
    let y = proxy.frame(in: .scrollView).minY
    return content
        .scaleEffect(1 - min(max(-y / 800, 0), 0.1))
        .opacity(1 - min(max(-y / 400, 0), 0.5))
}
```

- Only *effects* are available in the closure — `offset`, `scaleEffect`, `rotationEffect`,
  `opacity`, `blur`, `brightness`, `saturation`, `grayscale`, `hueRotation`, `colorMultiply`,
  `contrast`. No layout modifiers, by design.
- Derive every property from one normalized progress value; parallel expressions drift.
  See **view/scroll-patterns** for the scroll-driven versions, and `.scrollTransition`
  which is usually the better fit inside a scroll view.
- The closure runs on every geometry change. Keep it arithmetic — no allocation, no
  formatting, no state writes.

## Background extension

`.backgroundExtensionEffect()` mirrors and blurs a view into the safe area around it, so
an image can sit under a sidebar, inspector or bar without being cropped or letterboxed.

```swift
NavigationSplitView {
    Sidebar()
} detail: {
    ZStack {
        HeroBanner().backgroundExtensionEffect()
        DetailContent()
    }
}
```

One instance per screen, on a single piece of background content. It duplicates and blurs
the view — applying it to several views, or to interactive content, costs real frames and
looks wrong.

## Performance

- **Effects are per-frame GPU work.** Blur, shadow, mask and blend each add a pass.
  Applied inside a `List` or `LazyVStack` row they are multiplied by the visible row count.
- **Rasterize the stable, animate the cheap.** If an expensive composition never changes,
  `.drawingGroup()` it once and animate a transform on the result.
- **Prefer transform effects when animating.** `scaleEffect`, `offset`, `rotationEffect`,
  `opacity` are draw-time and nearly free; `blur`, `shadow` and `mask` are not.
- Verify with Instruments' SwiftUI and Animation Hitches templates rather than by eye —
  the Simulator does not represent GPU cost.
