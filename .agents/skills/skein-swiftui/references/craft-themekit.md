# ThemeKit (Theming)

**Mandatory.** All design tokens on iOS/macOS come from
[ThemeKit](https://github.com/rozd/theme-kit). Do not hand-roll a theming layer.
Companion to **view/theming** (how a view consumes tokens) and **view/effects**
(treatments built from them).

## Rules

- **Never** define an ad-hoc `Theme`/`AppColors` struct, a `Color` extension palette
  (`Color.brandPrimary`), an `@Environment` colour wrapper, or read tokens via
  `@Environment(\.theme)` inside a view body.
- **Never** branch on `colorScheme` to pick a colour. Adaptivity belongs in the token,
  not the view.
- Asset-catalog colour sets are not the token source; `theme.json` is.
- Tokens are used as ordinary `ShapeStyle` values — `.foregroundStyle(.onSurface)`,
  `.fill(.surface)` — with **zero imports** in view files.

## Setup

1. Add `https://github.com/rozd/theme-kit` as an SPM dependency.
2. Declare token *names* (no values) in `theme.json` at the project root; use the
   [Configurator](https://rozd.github.io/theme-kit/) rather than hand-editing.
   ```json
   {
     "$schema": "https://raw.githubusercontent.com/rozd/theme-kit/main/theme.schema.json",
     "styles": {
       "colors": ["surface", "onSurface", { "name": "primary", "style": "primaryColor" }],
       "gradients": [{ "name": "primary", "style": "primaryGradient" }]
     },
     "config": { "outputPath": ".", "shouldGeneratePreview": true }
   }
   ```
   Use the `{ "name": …, "style": … }` form when a name collides with a SwiftUI built-in
   (`primary`, `tint`).
3. Generate: right-click the project in Xcode → **Generate Theme Files**. Generated
   files are committed but **never hand-edited** — the next generation overwrites them.
   Change `theme.json` and regenerate, put values in `Theme+Defaults.swift`, or extend
   the generated types from a separate file.
4. Fill `Theme+Defaults.swift` with real values.

```swift
nonisolated extension ThemeColors {
    static let `default` = ThemeColors(
        surface:   .init(light: Color(hex: 0xF7F5EC), dark: Color(hex: 0x1A1A1A)),
        onSurface: .init(light: Color(hex: 0x2D2D2D), dark: Color(hex: 0xF0F0F0)),
        primary:   .init(light: Color(hex: 0x1B8188), dark: Color(hex: 0x3DBCC4))
    )
}
```

## Usage

```swift
Text("Hello").foregroundStyle(.onSurface)
RoundedRectangle(cornerRadius: 12).fill(.surface)
RoundedRectangle(cornerRadius: 12).fill(.surface.card)   // token + shadow token
```

Token variants beyond light/dark:

```swift
.init(compact: …, regular: …)                  // size class
.init(value: …)                                // constant
.init(resolver: .init(id: "high-contrast") { env in … })  // any EnvironmentValues axis
```

Give custom resolvers a stable `id` — it drives `Equatable` and lets SwiftUI skip
redraws.

## Runtime switching

Tokens resolve against `Theme.default` implicitly. Override only to switch themes:

```swift
ContentView().environment(\.theme, theme)      // @State private var theme: Theme = .default
```

Build alternates with the generated `copyWith`; `Theme` is `Codable`, so remote/bundled
themes decode directly.
