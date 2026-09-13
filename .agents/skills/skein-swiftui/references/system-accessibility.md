# Accessibility

Making a view usable by VoiceOver, Voice Control, Dynamic Type and the accessibility
settings. Companion to **view/theming** (color as a carrier of meaning), **view/animation**
(what Reduce Motion replaces) and **system/localization** (labels are user-facing strings —
localize them).

**The first rule is to use the real control.** A `Button`, `Toggle`, `Slider` or `Picker`
arrives with a label, a trait, focus handling, keyboard access and Voice Control support
already attached. Almost every accessibility modifier below exists to repair something a
stock control would have given you for free.

## Use controls, not gestures

```swift
Button("Delete", systemImage: "trash") { delete() }        // ✓
Text("Delete").onTapGesture { delete() }                   // ✗ invisible to VoiceOver
```

Reach for `onTapGesture` only when you genuinely need tap *location* or *count*. When you
must, restore the semantics by hand:

```swift
.onTapGesture(count: 2) { zoom() }
.accessibilityAddTraits(.isButton)
.accessibilityLabel("Zoom to fit")
```

## Every control carries text, even when it shows an icon

```swift
Button("Add item", systemImage: "plus", action: add)       // ✓
Button(action: add) { Image(systemName: "plus") }          // ✗ VoiceOver reads "plus"
Menu("Options", systemImage: "ellipsis.circle") { … }      // ✓ same rule for Menu
```

SwiftUI usually picks the right label style from context — a toolbar button renders
icon-only on its own. When a button must stay visually icon-only somewhere else, apply
`.labelStyle(.iconOnly)`: the text stays in the accessibility tree, only the pixels go away.

**Give volatile labels a stable Voice Control phrase.** A button labelled
"AAPL $271.68" cannot be spoken. `.accessibilityInputLabels(["Apple", "AAPL"])` gives the
user something sayable while the visible label keeps changing.

## Dynamic Type

Use the built-in text styles (`.largeTitle` … `.caption2`); they scale, and they scale
*correctly* per platform. Never hard-code a point size for body content.

```swift
Text("Inbox").font(.title2)
Text("Article").font(.custom("SourceSerif4-Semibold", size: 28, relativeTo: .title2))
Text("Nudged").font(.body.scaled(by: 1.1))   // iOS 26 / macOS 26
```

`Font.custom(_:size:relativeTo:)` pins a custom face to a text style so it tracks the
user's preferred size; the two-argument form scales relative to `.body`.

For everything that is *not* text — padding, icon frames, avatar sizes — use
`@ScaledMetric`, or the layout falls apart at large sizes while the text grows around it:

```swift
struct StatusRow: View {
    @ScaledMetric(relativeTo: .body) private var iconSize = 18.0

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").font(.system(size: iconSize))
            Text("Synced")
        }
    }
}
```

Test at the accessibility sizes, not just the largest standard one. `HStack`s of fixed-width
columns are the usual casualty — prefer `ViewThatFits` or a `@Environment(\.dynamicTypeSize)`
check that stacks vertically when `.isAccessibilitySize`.

## Images

Decide whether the image *means* something:

```swift
Image(decorative: "confetti")                              // asset, no meaning
Image(systemName: "sparkles").accessibilityHidden(true)    // symbol, no meaning
Image("receipt").accessibilityLabel("Receipt")             // meaning → label it
```

An asset-catalog name is not a label. `Image(.newBanner2026)` read aloud as
"new banner 2026" is a bug, whichever of the three lines above fixes it.

## Grouping

By default each `Text` in a row is its own VoiceOver stop, so a three-label cell costs
three swipes. Collapse it:

| Modifier | Effect |
|---|---|
| `.accessibilityElement(children: .combine)` | One element; child labels joined with commas |
| `.accessibilityElement(children: .ignore)` + `.accessibilityLabel(…)` | One element with a label you write |
| `.accessibilityElement(children: .contain)` + `.accessibilityLabel(…)` | Keeps children; names the container VoiceOver enters |

```swift
HStack {
    Text(item.name)
    Spacer()
    Text(item.price)
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("\(item.name), \(item.price)")
```

Use `.ignore` whenever the joined order would read awkwardly, or a child is decorative.

## Custom controls

**Describe it as the control it imitates.** `accessibilityRepresentation` swaps the whole
subtree for a stock control in the accessibility tree — the cheapest correct fix:

```swift
HStack {
    Text(label)
    Toggle("", isOn: $isOn)
}
.accessibilityRepresentation { Toggle(label, isOn: $isOn) }
```

**Anything with steps gets an adjustable action**, so VoiceOver's swipe-up/down works:

```swift
PageControl(selectedIndex: $index, pageCount: count)
    .accessibilityElement()
    .accessibilityValue("Page \(index + 1) of \(count)")
    .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: if index < count - 1 { index += 1 }
        case .decrement: if index > 0 { index -= 1 }
        @unknown default: break
        }
    }
```

Use `.accessibilityAddTraits` / `.accessibilityRemoveTraits` for state
(`item.isSelected ? [.isSelected, .isButton] : .isButton`), `.accessibilityValue` for the
current reading, and `.disabled(true)` rather than a custom "unavailable" label — it
announces "Dimmed" for free. For a hand-built label/field pair, `accessibilityLabeledPair`
in a shared `@Namespace` tells the system which is which.

## Respect the settings

Read them from the environment and change the *design*, not just the timing.

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
@Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency
```

- **Reduce Motion** — replace movement, scaling, parallax and blur with a cross-fade or
  opacity change. Do not merely shorten the animation.
- **Differentiate Without Color** — if color carries meaning (valid/invalid, up/down,
  online/offline), add a second channel: an SF Symbol, a stroke, a pattern.
- **Reduce Transparency** — swap `.ultraThinMaterial` backgrounds for an opaque fill.

## macOS specifics

The same APIs apply, plus:

- **Everything must be reachable by keyboard.** Test with Full Keyboard Access on; use
  `.focusable()`, `@FocusState` and `.focusSection()` for custom hit areas, and give
  destructive or primary actions a `.keyboardShortcut`.
- **Help tags are accessibility text.** `.help("Archive this thread")` feeds both the
  tooltip and VoiceOver.
- **Hover is not an affordance on its own** — anything revealed only on hover needs a
  keyboard/VoiceOver route to the same action.

## Audit checklist

- [ ] Tappable things are `Button`s; stray `onTapGesture` has `.isButton` + a label
- [ ] Icon-only buttons and menus still carry text; volatile labels have input labels
- [ ] Text uses text styles or `relativeTo:` custom fonts; non-text metrics use `@ScaledMetric`
- [ ] Layout survives `.isAccessibilitySize`
- [ ] Every image is decorative, hidden, or labelled — never read as an asset name
- [ ] Multi-label rows are combined or given one written label
- [ ] Custom controls have a representation, a value, and an adjustable action if steppable
- [ ] Reduce Motion, Differentiate Without Color and Reduce Transparency each change something
- [ ] macOS: full keyboard reachability, `.help` on icon controls
