---
name: skein-swiftui
description: Comprehensive SwiftUI engineering reference for iOS, iPadOS and macOS, split into lazily-loaded topic files covering state (@Observable, bindings, injection, AsyncSequence streams, unidirectional flow), navigation (stack, tabs, split view, sheets, transitions), views (layout, List and Table, scrolling, forms, animation, gestures, effects, Liquid Glass, Canvas, Metal shaders), theming, accessibility, localization, haptics, SwiftData persistence, networking, media, widgets and App Intents, macOS windows and menus, and the project's mandatory ThemeKit / FormsKit / StreamUI / UserKit packages. Use this skill whenever Swift or SwiftUI code is written, reviewed, refactored or debugged — building or restyling a screen, picking a state wrapper or a container, fixing a layout, animation, scrolling or performance problem, adopting a modern API, or auditing accessibility — even when the user names no framework and only shows a `.swift` file or asks why a view will not update.
license: Proprietary
compatibility: Designed for Claude Code and similar agents. Content assumes Xcode with current iOS/macOS SDKs, Swift 6 language mode, and the four in-house packages listed below.
metadata:
  author: rozd
  version: "1.0"
---

# SwiftUI

Detailed guidance lives in `references/`, one file per topic, loaded on demand. This
file is the router: read it, pick the one or two files the task actually needs, and load
those.

## Assumptions that hold for every file

These are stated once here so no reference file repeats them.

- **Latest iOS, iPadOS and macOS only.** Use current API directly. No `if #available`
  shims, no back-deployment fallbacks, no deprecated API kept "for safety". Nothing here
  is validated for watchOS, tvOS or visionOS — those platforms differ in containers,
  input and layout idioms, so treat any advice carried over to them as unverified.
- **Swift 6 language mode**, strict concurrency, `@MainActor`-isolated UI state.
- **Observation, not Combine.** `@Observable` classes are the state. There is no
  `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject`, and no
  `ViewModel` layer.
- **Four in-house packages are mandatory**, not options to weigh: ThemeKit (design
  tokens), FormsKit (validated forms), StreamUI (`AsyncSequence` → view), UserKit
  (session and auth). Hand-rolling any of these is a defect — see the `craft/*` files.

## How to load a reference file

Files are named `references/<area>-<topic>.md`. Inside them, a bold cross-reference like
**state/primitives** means the sibling file `references/state-primitives.md` — treat it
as a load instruction. Plain text or backticks (`NavigationStack`, `scenePhase`) name a
SwiftUI concept with no file behind it; do not go looking for one.

Each file opens with a one-line scope statement and a *Companion to* line naming its
neighbours, so you can start from a rough guess and navigate from there rather than
loading broadly.

Two economising habits:

- **Load the narrowest file that answers the question**, usually one or two. Loading a
  whole area wastes context; the routing table below is specific for that reason.
- **Some areas split decision from recipe.** `view/lists`, `view/scroll` and
  `view/animation` hold the container choice and the rules; `view/lists-patterns`,
  `view/scroll-patterns` and `view/animation-advanced` hold worked implementations. Read
  the base file first — the patterns files assume it. If the task *is* a known recipe
  ("stretchy header", "infinite list"), the patterns file opens with a lookup table; jump
  straight to that row.

`references/index.md` is the full annotated map, with the symbols and phrasings that
should send you to each file. Read it when the routing table below does not obviously
resolve the task, or when the task spans several areas.

## Routing table

| Task | Read |
|---|---|
| Choosing `@State` / `@Binding` / `@Bindable` / `@Environment`; view won't update; `@Observable` model shape | **state/primitives** |
| Where a model or service comes from; composition root; `@Environment` for app-lifetime values; previews and tests | **state/injection** |
| Mutation discipline, intents, in-flight and error state, optimistic updates, multi-step flows | **state/flow** |
| Consuming `AsyncSequence`; live/streaming data into a view | **state/streams**, then **craft/streamui** |
| Stacks, grids, flow layout, sizing, safe areas, alignment guides | **view/layout** |
| Cutting a screen into view types; what re-renders; `@ViewBuilder` containers; UIKit/AppKit bridging | **view/composition** |
| `List`, `Table`, `LazyVStack`, `LazyVGrid`; identity, rows, sections, swipe actions, reordering | **view/lists** |
| A specific list recipe — empty state, search, selection, outline, infinite scroll, skeletons, sortable table | **view/lists-patterns** |
| `ScrollView` configuration, scroll position, targets, indicators | **view/scroll** |
| A specific scroll recipe — stretchy hero, paging, carousel, threshold chrome, pagination sentinel | **view/scroll-patterns** |
| Data entry, `Form` + `Section`, focus traversal, validation, submission | **view/forms**, then **craft/formskit** |
| Colors, gradients, spacing, shadows, typography, dark mode, design tokens | **view/theming**, then **craft/themekit** |
| Animating values; where `.animation` goes; springs; what not to animate | **view/animation** |
| Phase and keyframe animators, transactions, custom `Animatable`, time-driven motion | **view/animation-advanced** |
| Views entering or leaving; `matchedGeometryEffect`; cross-screen zoom; interactive dismiss | **navigation/transitions** |
| Materials, blur, shadow, mask, clipping, blend modes, geometry-driven effects | **view/effects** |
| Liquid Glass — `.glassEffect`, `GlassEffectContainer`, morphing | **view/effects-glass** |
| Immediate-mode drawing or per-pixel work — `Canvas`, Metal shaders | **view/effects-canvas** |
| Tap, drag, magnify, rotate; combining gestures; `@GestureState` | **view/gestures** |
| Sheets, full-screen covers, popovers, presentation sizing and detents | **navigation/modal** |
| Top-level sections, `TabView`, tab roles, sidebar adaptation | **navigation/tabs** |
| `NavigationSplitView`, sidebar-plus-detail on iPad and Mac | **navigation/split** |
| SwiftData models, queries, migrations, CloudKit, `@AppStorage`, `UserDefaults` | **data/persistence** |
| HTTP and WebSocket clients, `URLSession`, request/response lifecycle | **data/networking** |
| Images, video, audio — loading, downsampling, playback, recording | **data/media** |
| VoiceOver, Dynamic Type, labels, traits, Reduce Motion, accessibility audit | **system/accessibility** |
| User-facing strings, String Catalogs, `LocalizedStringResource`, formatting, pluralisation | **system/localization** |
| Permissions, notifications, background execution, keychain, biometrics | **system/capabilities** |
| Widgets, controls, Live Activities, Siri, Shortcuts, share extensions, App Intents | **system/extensions** |
| `.sensoryFeedback`, haptics | **system/haptic** |
| Multiple windows, menu bar, `Settings` scene, pointer and keyboard, AppKit interop | **system/macos** |
| Session, sign-in, current user, auth | **craft/userkit** |
| Formatting, lint, strict-concurrency settings, secrets policy, testing discipline, review conventions | **craft/hygiene** |

## Working rules

**Load before writing, not after.** SwiftUI has a long deprecated surface and a lot of
plausible-looking API that these files rule out. Code written from memory and then
checked against a file usually has to be rewritten; the cheap order is to read the one
file that owns the decision, then write once. This matters most where your instinct is
strongest — state wrappers, list identity, where `.animation` goes.

**Answer with the doc's decision, not a survey.** Most files open with a decision table
(*Pick a container*, *Pick a wrapper*, *Pick a tier*) ordered so the first match wins.
Apply it and move on; do not present the user a menu the doc already resolved.

**The `craft/*` files are mandates.** Where they say *never*, that is a project decision
already taken, not a trade-off to re-open. If a task seems to require hand-rolling
something a package owns, the likely answer is that you have not found the package's
API yet.

**Most files end in a *Pitfalls* section** naming the failure and its cause. When
debugging — a view that won't update, a broken animation, a scroll that jumps, a list
that loses state — read that section before theorising; the bug is usually already
described there.

**Match the file's era.** These docs assume current API deliberately. If you catch
yourself reaching for `NavigationView`, `ObservableObject`, `UIImpactFeedbackGenerator`
or an availability check, a current replacement exists and the relevant file names it.

## Not covered here

No file covers these; use Apple's documentation and general SwiftUI knowledge, and stay
consistent with the conventions above. `NavigationStack` and navigation destinations;
`alert` and `confirmationDialog`; app and scene lifecycle (`App`, `ScenePhase`); one-shot
concurrency (`.task`, `TaskGroup`, actors) beyond what **state/streams** and
**state/flow** need; `Codable` and coder configuration; `FileManager` and document types;
response caching; testing, profiling and telemetry.
