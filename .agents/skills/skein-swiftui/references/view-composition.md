# Composition

How a screen is cut into view types, and what that costs at update time. Companion to
**view/layout** (arranging what composition produced), **state/primitives** (what each
view declares) and **craft/hygiene** (conventions).

## A view type is the unit of invalidation

When an input changes, SwiftUI re-runs the body of the smallest enclosing **view type**
that reads it — every branch, modifier chain and interpolation in that body, not just the
leaf that changed. A computed property or `@ViewBuilder` helper is inlined into its
parent's body, so it shares the parent's boundary and **reduces nothing**; it only moves
code. A separate `View` type with narrow inputs is its own boundary and is skipped when
its inputs compare equal.

```swift
// Shares the parent's boundary — re-runs on every `count` change
var body: some View {
    VStack {
        Button("Tap: \(count)") { count += 1 }
        expensiveSection            // computed property: no boundary
    }
}

// Its own boundary — body skipped while its inputs are unchanged
var body: some View {
    VStack {
        Button("Tap: \(count)") { count += 1 }
        ExpensiveSection(items: items)
    }
}
```

This is why "split the body for readability" is also a performance tool — but only when
the split produces real types.

## Struct, property, or function?

| Shape | Use |
|---|---|
| Reusable, stateful, or its own logical section | `struct` |
| Static fragment used once, no state, cheap | computed property |
| Parameterised fragment whose arguments are *stable* | function |
| Parameterised per call (inside `ForEach`) | `struct` — so inputs can be diffed |
| Branches between different view types | `@ViewBuilder` property or function |

Any fragment that declares `@State`, `@Binding`, `@Environment` or `@FocusState` must be
a `struct` — wrappers only work as stored properties of a view.

**Detail screens are the usual regression.** `header + gallery + description + reviews`
written as four `private var`s is one boundary, so a change to any one re-evaluates all
four. One `View` type per section, each taking only the fields it renders, and a thin
parent that composes them:

```swift
struct ProductDetailView: View {
    let product: Product

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ProductHeader(name: product.name, price: product.price)
                ProductGallery(images: product.imageURLs)
                ProductReviews(average: product.averageStars, count: product.reviewCount)
            }
            .padding()
        }
    }
}
```

`@ViewBuilder` is required only when branches return *different* view types; if every
branch returns the same type, drop it.

## Keep `body` and `init` cheap

`body` can run several times in one layout pass, and `init` runs every time the parent
re-evaluates — many times per second inside `List`, a lazy stack or an animation.

- No `filter` / `map` / `sorted` inline in `body` or in a `ForEach` argument — prepare the
  sequence in the model (see **state/primitives** on cached derived values).
- No formatter construction; use `Text(date, format: .dateTime.day().month())`, which is
  cached and locale-aware.
- `init` is a constant-time copy of inputs into stored properties. No decoding, no file
  access, no large allocation. It is not a setup hook — for one-shot work use `.task`, or
  seed `@State` storage per **state/primitives**.

## Containers take a `@ViewBuilder` property, not a closure

Closures are uncomparable, so a container storing `() -> Content` can never be skipped.

```swift
struct Card<Content: View>: View {
    @ViewBuilder let content: Content   // not `let content: () -> Content`

    var body: some View {
        VStack { header; content }
    }
}
```

The call site is identical; only the stored shape changes.

## Modifiers over branches

A branch creates and destroys identity: state is lost, transitions restart. When the two
sides are two *states of one view*, keep the view and vary a value.

```swift
badge.opacity(isVisible ? 1 : 0)             // same view, two states
label.foregroundStyle(isError ? .red : .primary)
```

Branch only for genuinely different views (`if isLoggedIn { Dashboard() } else { Login() }`)
or optional content (`if let user { … }`). Identity and transitions in
**navigation/transitions**; per-row consequences in **view/lists**.

**Never add an `if`-based `.if { }` view extension.** Its branches return different types,
so identity changes with the condition — the exact bug it looks like it avoids. Reviewing
existing code that has one: flag it, show the ternary, and fix it in its own commit, since
swapping it changes state and animation behaviour.

## Reusable styling

Extract a repeated modifier chain into a `ViewModifier`, a button design into a
`ButtonStyle` (`PrimitiveButtonStyle` only when you need custom interaction), and expose
both through static member lookup so the call site reads like a built-in:

```swift
extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { .init() }   // .buttonStyle(.primary)
}
```

The same pattern works for `ListStyle`, `ToggleStyle`, `LabelStyle`. Values inside the
style come from theme tokens, never literals — see **view/theming**.

## Bridging UIKit / AppKit

- `makeUIView(context:)` runs once; `updateUIView(_:context:)` runs on every redraw.
- The representable *struct* is recreated on every redraw — keep its `init` trivial.
- Use a `Coordinator` for delegates and callbacks back into SwiftUI.
- A `Binding` property must be declared `@Binding`; an undecorated one silently stops
  updating (see **state/primitives**).

## Pitfalls

- **`@ViewBuilder` helpers used as a performance fix.** They are inlined; only a `View`
  type is a boundary.
- **`AnyView`.** It erases the structural identity SwiftUI diffs on and forecloses
  optimisations. Use `@ViewBuilder` branches; reserve it for genuine API type erasure.
- **`Group { OneView() }`.** A single concrete child gains a wrapper type for nothing and
  slows type-checking of the chain. A `Group` around a `ForEach`, siblings or an
  `if`/`else` is doing real work and is fine.
- **`.equatable()` everywhere.** Useful for a small, well-defined input set where the
  comparison is meaningful; as a blanket optimisation the comparison costs more than the
  body it skips.
- **"Unable to type-check this expression in reasonable time."** Almost always one huge
  body: extract subviews, split long modifier chains, hoist inline closures.
- **Debug leftovers.** `Self._printChanges()` / `Self._logChanges()` in a body are
  diagnostics only — remove before merging.
