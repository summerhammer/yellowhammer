# Modal

Presenting content over the current context — sheets, full-screen covers and popovers —
and sizing it. Companion to **navigation/transitions** (the motion of arriving and
leaving) and **navigation/tabs** (what a sheet is presented over). `NavigationStack`
pushes *inside* a presentation; `alert` and `confirmationDialog` are not modals in this
sense and follow their own rules.

## Pick a presentation

| Situation | Use |
|---|---|
| A self-contained task the user can abandon | `.sheet` |
| A task that must be finished or explicitly cancelled — onboarding, media, a modal flow | `.fullScreenCover` (iOS only) |
| A small transient panel anchored to the control that opened it | `.popover` |
| Supplementary detail beside the content, not over it | `.inspector` |

## Rules

- **Present data, not a flag.** `.sheet(item:)` binds an `Identifiable?`: the value *is*
  the presentation state and arrives non-optional in the closure. `isPresented:` is for a
  presentation with no payload. Never pair a `Bool` with a separate selection — they drift
  out of sync.
- **One modifier per presenter.** For several sheets from one view, make an `Identifiable`
  enum with a case per destination and drive one `.sheet(item:)` from it. Stacked
  `.sheet` modifiers on the same view conflict; only one wins.
- **Shorthand the single-argument case.** `.sheet(item: $item, content: ItemView.init)`.
- **The modal owns its dismissal.** Read `@Environment(\.dismiss)` inside the presented
  view and call it. Passing `onSave` / `onCancel` closures down from the presenter is
  prop-drilling that ties the view to one call site.
- **Attach the modifier to the trigger.** Put `.popover` / `.sheet` on the button that
  opens it, not on an enclosing container — the presentation animates and anchors from
  its source view.
- **Give a sheet its own `NavigationStack`** when it needs a title, a toolbar or pushes.
  It is a separate hierarchy; never try to reach the presenter's stack from inside.
- **Detents are a set, with a binding for the current one.**
  `.presentationDetents([.medium, .large], selection: $detent)`. Include `.large` when the
  content can grow; a single fixed detent with scrollable content traps the user.
  `.height(_)` and `.fraction(_)` cover fixed sizes, `.custom(_:)` a computed one.
- **A partial-height sheet still blocks the background by default.** Opt in explicitly
  with `.presentationBackgroundInteraction(.enabled(upThrough: .medium))` for a sheet the
  user should be able to work behind, such as a map or player.
- **Size macOS and iPad sheets with `.presentationSizing`** — `.form`, `.page`, or
  `.fitted`. Detents are an iOS-compact concept; frames with hard-coded numbers are not.

## Platform notes

- `fullScreenCover` does not exist on macOS. Write the shared path as a `.sheet` and add
  the cover under `#if os(iOS)`, or accept a sheet everywhere.
- A popover **adapts to a sheet in compact width** unless you say otherwise. Keep the
  adaptation when the content is substantial; force the popover with
  `.presentationCompactAdaptation(.popover)` only for genuinely small panels.
  `.popover(isPresented:attachmentAnchor:arrowEdge:)` places the arrow.
- On iOS 26 / macOS 26 a presentation morphs out of the control that triggered it, so the
  attachment point above is visible, not cosmetic. Let the system draw the material:
  set `.presentationBackground` only when the design genuinely needs a non-glass surface,
  and pair it with `.presentationCornerRadius` if you do.
- Sheets resize with the keyboard on iOS; a `Form` inside one needs no manual avoidance.

## Pitfalls

- The presented closure is built in the *presenter's* context. State it reads must live on
  the presenter or in the environment — `@State` declared inside the closure body is
  recreated on every presentation.
- `.presentationDragIndicator(.visible)` is a cue, not a mechanism: it does not enable
  swipe-to-dismiss, and it is ignored on a full-screen cover.
- Block swipe-to-dismiss with `.interactiveDismissDisabled(true)` when there is unsaved
  work — and always offer a visible Cancel. A cover with neither is a dead end.
- Presenting from within a sheet requires the modifier to be inside that sheet's own view
  tree. A second `.sheet` on the presenter will not show while the first is up.
- `dismiss()` closes the nearest presentation only. From a pushed view inside a sheet it
  pops; to close the whole sheet, dismiss from the sheet's root.
