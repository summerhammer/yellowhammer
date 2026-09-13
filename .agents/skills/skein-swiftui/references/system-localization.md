# Localization

Every string the user reads. Companion to **system/accessibility** (labels are user-facing
strings too), **view/layout** (translations change size) and **view/theming**.

**The rule that prevents most bugs: pass the literal, resolve nothing yourself.** `Text`,
`Button`, `Label`, `.navigationTitle`, alert titles and every other SwiftUI initializer
that takes `LocalizedStringKey` localizes a string literal on its own, *at display time*,
in the view's locale.

```swift
Text("start_workout")                          // ✓ key, resolved in \.locale
Text(String(localized: "start_workout"))       // ✗ resolved eagerly, ignores \.locale
```

Keys may be opaque (`"start_workout"`) or English source text (`"Start Workout"`) — follow
whatever the project already does. `Text(verbatim:)` opts a literal out. A `String`
*variable* passed to `Text` hits the `StringProtocol` overload and is never localized.

## Where strings live

String Catalogs (`.xcstrings`) are the format; each build syncs new keys from code into
one, but Xcode will not create the catalog for you. Don't migrate a project that still
uses `.strings`/`.stringsdict` as a side effect of other work.

**Inside a framework or Swift package, `bundle: #bundle` is mandatory.** Without it the
lookup goes to `Bundle.main`, misses silently, and ships the untranslated string.

```swift
Text("Save to Favorites", bundle: #bundle,
     comment: "Button to bookmark a recipe.")
```

`#bundle` supersedes `Bundle.module` / `Bundle(for:)`. Apps and app extensions are their
own main bundle and may omit it. `tableName:` routes a group of strings to its own catalog.

## Type user-facing text as `LocalizedStringResource`

`LocalizedStringKey` works inside a view; `LocalizedStringResource` is the one that
survives being *stored* — in a model, a tip, a queued notification, an `AppIntent`. It
defers resolution to display time, so the value renders in the locale that is active when
it is shown, not the one that was active when it was built.

```swift
struct Tip { let headline: LocalizedStringResource }   // ✓
struct Tip { let headline: String }                    // ✗ frozen at creation
```

Same move for a fixed set of runtime values — wrapping a `String` variable in
`LocalizedStringKey(_:)` does nothing, because there is no literal for Xcode to extract:

```swift
enum Category {
    case appetizers, mains, desserts
    var name: LocalizedStringResource {
        switch self {
        case .appetizers: "Appetizers"
        case .mains: "Mains"
        case .desserts: "Desserts"
        }
    }
}

Text(category.name)
```

Adopt this when writing new types or touching the text; don't sweep existing `String`
properties in an unrelated change.

## Never assemble a sentence

Interpolation preserves `LocalizedStringKey` and produces one format string
(`"Welcome, %@"`) that a translator can reorder. `+` produces a plain `String` and is not
localized at all.

```swift
Text("Created by \(authorName)")                                    // ✓
Text(String(localized: "Created by")) + Text(" ") + Text(author)    // ✗ word order
```

**Counts need a plural rule, not an `if`.** Write one interpolated string and vary it by
plural in the String Catalog — `.stringsdict` behaviour, now in the catalog editor. Slavic
and Arabic locales have three to six plural categories; a hand-rolled
`count == 1 ? … : …` is wrong in most of them.

```swift
Text("\(count) items selected")   // → vary by plural on the count argument
```

`^[…](inflect: true)` handles grammatical agreement (gender, case) where the catalog
supports it.

## Formatting

Format styles adapt to the locale; format strings don't.

```swift
Text(workout.date, format: .dateTime.month().day().year())   // ✓ locale picks the order
Text(product.price, format: .currency(code: store.currency)) // ✓
Text("$\(product.price, specifier: "%.2f")")                 // ✗ currency, separators
```

Field components choose *which* fields appear; the locale chooses the order. Use
`Array.formatted()` for lists (locale-correct separators and "and"), `Duration`'s styles
for elapsed time, and `.relative` for "2 hours ago". If `DateFormatter` is truly
unavoidable, use `setLocalizedDateFormatFromTemplate(_:)`, never `dateFormat =`.

## Casing

Bake the case into the string. `.textCase(.uppercase)` forces one casing on every
language, and some scripts have no case at all.

```swift
Text("SECTION HEADER")                              // ✓
Text("Section Header").textCase(.uppercase)         // ✗
```

User-entered text displays as typed. If a transform is unavoidable, use
`.localizedUppercase` / `.localizedCapitalized`.

## Layout that survives translation

- `.leading` / `.trailing`, never `.left` / `.right` — they mirror for RTL. Same for
  `.padding(.leading:)`, edge insets and `HStack` ordering.
- No fixed `width`/`height` on anything containing text. German runs ~35% longer; Thai and
  Devanagari run taller. Use `ViewThatFits` or let the stack wrap.
- Text styles, not point sizes — line height adapts per script.
- Mirror directional SF Symbols automatically (`.arrow.forward`, not `.arrow.right`);
  exempt genuinely non-directional art with `.flipsForRightToLeftLayoutDirection(false)`.

Preview the pathological cases rather than guessing:

```swift
#Preview("German") { ContentView().environment(\.locale, .init(identifier: "de")) }
#Preview("Arabic")  { ContentView().environment(\.locale, .init(identifier: "ar")) }
```

Xcode's **Show non-localized strings** and **Double-Length Pseudolanguage** run schemes
catch the rest. In view code read `@Environment(\.locale)`, not `Locale.current`, so
previews and per-view overrides apply.

## Outside a view

`String(localized:)` — not `NSLocalizedString` (no interpolation; Xcode can't extract an
interpolated key) and not `String(format:)` (always renders 0–9 digits regardless of
locale).

```swift
let title = String(localized: "activity_summary", comment: "Dashboard header")
```

## Comments

Translators see the key and the comment, not your variable names or the screen.

```swift
Text("Edit")                                                    // ✗ noun or verb?
Text("Edit", comment: "Toolbar button that enters editing mode.")
Text("Completed \(count) of \(total)",
     comment: "Progress label — first value is finished items, second is the total.")
```

Keep one source of truth per string: at the call site *or* in the catalog's Comment field.

## Audit checklist

- [ ] Literals go straight to `Text`/`Button`/`Label` — no `NSLocalizedString`, no `String(localized:)` in a view
- [ ] `bundle: #bundle` on every user-facing string in a framework or package
- [ ] Stored user-facing text is `LocalizedStringResource`, not `String`
- [ ] Dynamic text is interpolated; no `+`, no sentence assembly from fragments
- [ ] Counts vary by plural in the catalog, not by `if count == 1`
- [ ] Dates, numbers, currencies and lists use format styles / `.formatted()`
- [ ] Case is in the string, not in `.textCase`
- [ ] `.leading`/`.trailing`, no fixed sizes around text, symbols mirror for RTL
- [ ] `@Environment(\.locale)` for locale logic; RTL and long-language previews exist
- [ ] Ambiguous strings and every interpolated placeholder have a `comment:`
