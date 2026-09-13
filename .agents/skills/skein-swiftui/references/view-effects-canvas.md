# Canvas and shaders

Escape hatches from the view system: `Canvas` for immediate-mode 2D drawing, Metal
shaders for per-pixel work. Companion to **view/effects** (the modifier-level treatments
you should exhaust first).

Reach for these last. Both give up things the view system provides for free —
accessibility, hit testing, and in the shader case the ability to render UIKit/AppKit-backed
content at all.

## Which one

| Situation | Use |
|---|---|
| A handful of shapes, each interactive | `Shape` / `Path` views |
| Hundreds of primitives, no per-element interaction | `Canvas` |
| A chart, sparkline or waveform | `Canvas` (or Swift Charts if it fits) |
| A per-pixel color transform of existing content | `.colorEffect` |
| Warping or displacing existing content | `.distortionEffect` |
| Reading neighbouring pixels — glow, custom blur, pixelate | `.layerEffect` |
| A generated pattern or gradient as a fill | `Shader` as a `ShapeStyle` |

## Canvas

```swift
Canvas { context, size in
    let rect = CGRect(origin: .zero, size: size)
    context.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 4)
}
.frame(width: 300, height: 200)
```

`GraphicsContext` supports fills, strokes, images, text, layers, masks, filters,
transforms and blend modes. The `symbols:` initializer lets you resolve real SwiftUI views
and draw them repeatedly.

- **A canvas has no accessibility and no per-element hit testing.** Everything inside is
  one opaque view. Add `.accessibilityLabel` / `.accessibilityValue` describing the whole
  drawing, or supply a parallel accessible representation. See **system/accessibility**.
- **Use it for volume, not for text.** Apple's own guidance: a canvas helps for complex
  drawings over dynamic data, and does not help for drawings that are primarily text or
  need interactive elements.
- **The renderer closure runs on every redraw.** Do no work in it beyond drawing — no
  parsing, no formatting, no date math, no state writes. Precompute into a value type and
  pass it in.
- **Resolve once, reuse.** `context.resolve(_:)` for text and images, and
  `context.resolveSymbol(id:)` for symbols, produce a reusable resolved object. Resolving
  inside a per-item loop is the usual reason a canvas is slow.
- **Scope with layers.** `context.drawLayer { … }` isolates opacity, blend mode, clipping
  and filters to a sublayer, the same way `.compositingGroup()` does for views. Mutating
  `context.transform` or `context.opacity` directly leaks into everything drawn after it —
  pass a copy of the context instead.
- **Redraw only when the data changes.** A canvas driven by `TimelineView(.animation)`
  redraws every frame by design; drive it from a value that actually changes and use
  `.periodic` or a paused schedule when idle.
- `opaque: true` skips the alpha channel; set it when the canvas fills its bounds.
- Hit testing is yours: overlay transparent views for interaction, or map the tap location
  back to your model yourself.

```swift
Canvas { context, size in
    let symbol = context.resolveSymbol(id: 0)!
    for point in points {
        context.draw(symbol, at: point.position(in: size))
    }
} symbols: {
    Circle().fill(.tint).frame(width: 6, height: 6).tag(0)
}
```

## Metal shaders

A `Shader` is a reference to a `[[ stitchable ]]` function in the app's default Metal
library, plus its bound uniforms. Three view modifiers consume one, and a shader can also
act as a `ShapeStyle` fill.

```swift
// Shaders.metal
[[ stitchable ]] half4 tintRamp(float2 position, half4 color, float amount) {
    return half4(color.r, color.g * (1 - amount), color.b, color.a);
}
```

```swift
Image(.hero)
    .colorEffect(ShaderLibrary.tintRamp(.float(amount)))
```

| Modifier | Signature the function must have | What it can do |
|---|---|---|
| `.colorEffect` | `half4 f(float2 position, half4 color, …)` | recolor one pixel at a time |
| `.distortionEffect(_:maxSampleOffset:)` | `float2 f(float2 position, …)` | move pixels |
| `.layerEffect(_:maxSampleOffset:)` | `half4 f(float2 position, SwiftUI::Layer layer, …)` | sample neighbours via `layer.sample(_:)` |
| `ShapeStyle` fill | `half4 f(float2 position, …)` | generate a pattern for a shape or text |

- **`maxSampleOffset` is a contract.** It declares the farthest the function reads from
  the destination pixel. Too small and you get clipped or undefined edges; needlessly
  large costs area on every pass. State it honestly.
- **Return premultiplied color** in the destination color space (usually extended sRGB).
  Non-premultiplied output shows as dark or bright fringes on antialiased edges.
- **`.layerEffect` cannot rasterize UIKit/AppKit-backed views.** Maps, web views, video
  players and most complex controls log a warning and render a placeholder. Apply the
  effect to something SwiftUI draws itself.
- **Uniforms are positional.** `ShaderLibrary.name(.float(a), .float2(b), .color(c))`
  binds in order, and there is no compile-time check against the Metal signature — a
  mismatch is a runtime artefact, not an error. Wrap each shader in a small Swift function
  so the argument order lives in exactly one place.
- **Precompile before first use.** `shader.compile(as:)` is async and avoids the hitch on
  the frame the shader first renders. Do it when the screen appears, not when the
  animation starts.
- **Set `dithersColor` on smooth gradients.** Without it, generated ramps band visibly.
- **Animate by passing time in as a uniform**, driven by `TimelineView(.animation)` —
  shader arguments are not `Animatable`, so SwiftUI will not interpolate them for you.
- **Shaders bypass accessibility and Dynamic Type entirely.** Anything load-bearing —
  text, state, affordance — must exist as a real view underneath or alongside.
- **Honour Reduce Motion and Reduce Transparency** by disabling the effect:
  every modifier takes `isEnabled:` for exactly this.

```swift
.layerEffect(
    ShaderLibrary.ripple(.float2(origin), .float(elapsed)),
    maxSampleOffset: CGSize(width: 12, height: 12),
    isEnabled: !reduceMotion
)
```
