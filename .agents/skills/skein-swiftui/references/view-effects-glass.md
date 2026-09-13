# Liquid Glass

Applying the system's control material to custom views: `.glassEffect`,
`GlassEffectContainer`, morphing between glass shapes. Companion to **view/effects**
(materials, shadows and the ordering rules that still apply) and
**navigation/transitions** (the cross-screen zoom transitions glass bars participate
in).

Liquid Glass blurs what is behind it, reflects surrounding color and light, and reacts to
touch and pointer in real time. Standard components already use it. This file is only
about *custom* components.

## Do you need it at all?

| Situation | Do |
|---|---|
| Bars, tab bars, sheets, standard buttons | nothing — they are already glass |
| A custom floating control or toolbar over content | `.glassEffect()` |
| A custom button | `.buttonStyle(.glass)` / `.glassProminent` |
| Several glass controls near each other | wrap in `GlassEffectContainer` |
| A card or panel of *content* | a material — see **view/effects** |

**Glass is for controls floating above content, not for content.** Making every card
glass flattens the layer hierarchy the material exists to express, and costs a render
pass each.

## Applying the effect

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect()                              // regular variant, capsule shape

Label("Filters", systemImage: "line.3.horizontal.decrease")
    .padding()
    .glassEffect(in: .rect(cornerRadius: 16))   // larger components want a rect

Button { … } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
    .glassEffect(.regular.tint(.orange).interactive(), in: .circle)
```

- **Apply `.glassEffect` last.** It captures the content beneath it in the chain and hands
  it to the container to render. Font, foreground style, padding and frame all go first.
- **Three variants exist: `.regular`, `.clear`, `.identity`.** There is no `.prominent`.
  For emphasis, tint (`.regular.tint(.accent)`) or use `.buttonStyle(.glassProminent)`.
  `.identity` is the no-op, useful as a conditional branch.
- **`.interactive()` only on things that take input.** It adds the system's press/hover
  reaction. On static content it promises an affordance that isn't there.
- **Capsule for small controls, `.rect(cornerRadius:)` for large ones.** A capsule on a
  big panel reads as a mistake. Keep one shape family per feature.
- **Tint means meaning, not decoration.** In the new design toolbar icons are monochrome
  by default; a tint signals a call to action or a state.

## Containers

`GlassEffectContainer` renders the glass of everything inside it as one set of shapes.

```swift
GlassEffectContainer(spacing: 20) {
    HStack(spacing: 20) {
        ToolButton("pencil")
        ToolButton("eraser")
        ToolButton("trash")
    }
}
```

- **Glass cannot sample glass.** The material samples a region larger than itself; two
  glass views in different containers sample each other's *output* and drift visually. One
  container per cluster is a correctness requirement, not an optimization — though it is
  also the main performance lever.
- **Match the container's `spacing` to the layout's spacing.** The container spacing is the
  distance at which shapes begin to blend. A container spacing larger than the `HStack`'s
  makes shapes merge at rest, which usually isn't what you meant.
- **Don't nest containers,** and don't create one per element. Too many containers, or too
  many effects outside any container, is the documented way to lose frames.
- Use `.glassEffectUnion(id:namespace:)` when several views should read as a *single*
  capsule while at rest — dynamically generated chips, or views that aren't siblings in
  one stack. Views sharing an id, shape and variant merge into one shape.

```swift
GlassEffectContainer(spacing: 20) {
    HStack(spacing: 20) {
        ForEach(symbols.indices, id: \.self) { i in
            Image(systemName: symbols[i])
                .frame(width: 80, height: 80)
                .glassEffect()
                .glassEffectUnion(id: i < 2 ? "weather" : "phases", namespace: namespace)
        }
    }
}
```

## Morphing

Give each effect a stable id in a shared `Namespace` and SwiftUI morphs the shapes as
views enter and leave the hierarchy.

```swift
@State private var isExpanded = false
@Namespace private var namespace

GlassEffectContainer(spacing: 40) {
    HStack(spacing: 40) {
        Image(systemName: "scribble.variable")
            .frame(width: 80, height: 80)
            .glassEffect()
            .glassEffectID("pencil", in: namespace)

        if isExpanded {
            Image(systemName: "eraser.fill")
                .frame(width: 80, height: 80)
                .glassEffect()
                .glassEffectID("eraser", in: namespace)
        }
    }
}

Button("Toggle") { withAnimation { isExpanded.toggle() } }
    .buttonStyle(.glass)
```

- **`glassEffectID` and `glassEffectTransition` only do anything during a hierarchy change
  or animation.** They are inert at rest; the effect must be added or removed.
- **Two transitions, chosen by distance.** `.matchedGeometry` (the default) morphs shapes
  into one another and is right when the views sit within the container's spacing.
  `.materialize` fades the content and animates the material in or out without matching —
  use it when the views are farther apart than the spacing. `.identity` disables the
  change. Stick to these two so the motion matches the rest of the system.
- **Stable ids.** A `UUID()` recreated per render, or an id derived from selection state,
  breaks the match silently — the shapes cross-fade instead of morphing. Key off the
  model's identity. Same rule as `matchedTransitionSource`; see
  **navigation/transitions**.
- **Drive it with `withAnimation`.** The morph animates because the hierarchy change is
  inside an animation transaction, not because of the modifier.

## Buttons

```swift
Button("Share") { … }.buttonStyle(.glass)
Button("Continue") { … }.buttonStyle(.glassProminent)
```

Use the styles before hand-rolling `.glassEffect(.regular.interactive(), in: .capsule)` on
a `Button` — they carry the correct metrics, press behaviour and prominence for free.
Build it by hand only when the shape or layout genuinely differs.

## Fitting in with the system

- **Remove custom backgrounds behind bars.** The system's scroll edge effect blurs and
  fades content under toolbars to keep controls legible; a custom darkening layer fights
  it and produces a double edge.
- **Drop `presentationBackground` on sheets.** Partial-height sheets are glass by default.
- **Don't hand-build glass out of materials and strokes.** `.ultraThinMaterial` plus a
  gradient border is not Liquid Glass — it does not react to light or touch, and it will
  look wrong next to real system chrome.
- **Check Reduce Transparency.** As with materials, read
  `@Environment(\.accessibilityReduceTransparency)` and fall back to an opaque token
  surface. See **view/effects** and **system/accessibility**.
