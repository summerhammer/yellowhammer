# Theming

Design tokens — colors, gradients, shadows, spacing — and how a view consumes them.
Companion to **view/layout** (what the spacing is applied to) and **view/effects**
(shadows as a visual treatment rather than a token).

**This project themes with [ThemeKit](https://github.com/rozd/theme-kit).** Assume it is
already integrated. Reach for a literal `Color`, `Gradient` or shadow only when the doc
below says to.

## What ThemeKit is

A code generator plus a thin runtime. You declare token *names* in `theme.json`; a build
plugin generates a `Theme` struct, `ShapeStyle` extensions and environment plumbing into
the project; you fill the actual values into `Theme+Defaults.swift`.

Tokens are `ShapeStyle`s that resolve through `resolve(in:)` — the same mechanism behind
`.primary` and `.tint`. Consequences worth internalising:

- **No import, no `@Environment` in views.** `.foregroundStyle(.onSurface)` just works.
- **Adaptation is the token's job, not the view's.** Each token carries its own variants;
  the right one resolves at render time.
- Generated files live in the repo and are yours to read. **Never hand-edit them** — they
  are overwritten on the next generation. Edit `theme.json` and regenerate, or extend in a
  separate file.

## Use tokens, not literals

| Need | Use | Not |
|---|---|---|
| A fill or foreground color | `.fill(.surface)`, `.foregroundStyle(.onSurface)` | `Color(hex:)`, `.gray`, asset catalog colors |
| A gradient | `.fill(.primaryGradient)` | an inline `LinearGradient(colors:...)` |
| A drop shadow | `.fill(.surface.card)` | `.shadow(radius: 4)` with tuned numbers |
| Light/dark difference | one token with `light:`/`dark:` variants | `if colorScheme == .dark` in the view |
| Compact/regular difference | one token with `compact:`/`regular:` variants | a size-class branch around two literals |

A token name that collides with a SwiftUI built-in is declared with a `style` override in
`theme.json` (`{ "name": "primary", "style": "primaryColor" }`) and used as
`.primaryColor`. Check the generated `ShapeStyle+*.swift` for the actual call-site names
before guessing.

**Adding a token is a config change, not a code change:** add the name to `theme.json`,
regenerate (Xcode → right-click the project → *Generate Theme Files*), fill the value in
`Theme+Defaults.swift`.

## Defining values

In `Theme+Defaults.swift`, each token is a `ThemeAdaptiveStyle` built one of four ways:

```swift
surface: .init(light: Color(hex: 0xF7F5EC), dark: Color(hex: 0x1A1A1A))  // color scheme
surface: .init(compact: .white, regular: Color(hex: 0xF7F5EC))            // size class
surface: .init(value: Color(hex: 0xF7F5EC))                               // constant
surface: .init(resolver: .init(id: "high-contrast") { env in              // any axis
    env.colorSchemeContrast == .increased ? .white : Color(hex: 0xF7F5EC)
})
```

Prefer the first three. A custom resolver is the escape hatch for axes ThemeKit doesn't
model (contrast, accessibility sizes, a custom environment key) — it costs serialization:
resolver-built tokens have no defaults and **cannot be encoded to JSON**.

Always pass a stable `id` to a resolver. `id` drives `Equatable`, and an auto-generated one
differs on every construction, defeating SwiftUI's redraw skipping.

## Shadows compose

Shadow tokens generate an instance property on *any* `ShapeStyle`, so they chain:

```swift
.fill(.surface.card)            // theme color + theme shadow
.fill(.red.card)                // built-in color + theme shadow
.fill(.surface.card.innerGlow)  // several shadows, applied in order
```

This is a fill-time shadow, not the `.shadow(_:)` view modifier — it is clipped to the
shape and does not affect layout. For a shadow around a whole view subtree, the view
modifier is still correct.

## Switching themes

Tokens resolve against `Theme.default` implicitly; nothing needs injecting for the normal
case. To swap at runtime, override the environment at the scene root:

```swift
@State private var theme: Theme = .default
// ...
ContentView().environment(\.theme, theme)
```

Derive variants with `copyWith` rather than re-declaring a whole theme:

```swift
static let ocean = Theme.default.copyWith(
    colors: ThemeColors.default.copyWith(primary: .init(light: .blue, dark: .cyan))
)
```

Every theme type is `Codable`, so a theme can be decoded from a bundled file or a remote
API — subject to the resolver caveat above.

## Typography

For type, prefer the semantic system styles (`.font(.headline)`) over point sizes — they
carry Dynamic Type for free. A custom face belongs in a `Font` extension
(`.font(.appTitle)`), still built on a relative metric so it scales.

## Pitfalls

- **Don't branch on `colorScheme` in a view** to pick a color. That is the token's job; a
  view-level branch splits the design language across files and breaks theme switching.
- **Don't re-add an asset catalog color set** for something that is already a token — two
  sources of truth diverge silently.
- **Don't edit generated files.** Regeneration wipes them.
- `.foregroundColor(_:)` is deprecated and takes a `Color`, not a `ShapeStyle` — tokens
  need `.foregroundStyle(_:)`.
- A token used as a `Color` value (e.g. as a function argument typed `Color`) will not
  compile; tokens are `ShapeStyle`s, so pass them to modifiers that accept one, or read
  the value off `Theme` explicitly.
