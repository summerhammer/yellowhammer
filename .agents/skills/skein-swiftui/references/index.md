# Reference index

The annotated map of this directory. `../SKILL.md` routes common tasks directly; come
here when the task is broad, spans areas, or you are unsure which file owns a symbol.

Each entry gives the file, what it owns, and the **triggers** — symbols and phrasings
that should send you to it. Search this page for the API name in front of you.

**Notation.** Inside the reference files, a bold **area/topic** is a load instruction
pointing at the sibling file `area-topic.md`. Plain backticks (`NavigationStack`,
`scenePhase`) name a SwiftUI concept with no file behind it. Every file opens with its
scope plus a *Companion to* line, so you can navigate between neighbours without
returning here.

**Shape of a file.** Most open with a decision table (*Pick a container* / *Pick a
wrapper* / *Pick a tier*), first match wins, and close with *Pitfalls* — the failure, and
what causes it. When debugging, read *Pitfalls* first.

---

## state — what a view declares and how it changes

Start at **state/primitives** unless the question is clearly about one of the others.

| File | Owns | Triggers |
|---|---|---|
| `state-primitives.md` | Choosing a property wrapper; `@Observable` model shape; bindings; custom environment values | `@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable`, `@ObservationIgnored`, `EnvironmentKey`, "view isn't updating", "state resets", `Equatable` conformance for state |
| `state-injection.md` | How a model or service *reaches* a view: composition root, constructor injection, environment for app-lifetime values, scoping, previews and tests | "dependency injection", "where do I create this", `@Environment(Model.self)`, singleton, service locator, "shared instance", preview data, test doubles |
| `state-flow.md` | Mutation discipline: one writer, intent → effect → state, in-flight and error state, optimistic updates and rollback, multi-step flows | "unidirectional", "who owns this state", loading/error flags, "two places write the same value", wizard, retry, rollback |
| `state-streams.md` | Consuming `AsyncSequence` in a view; the three tiers from view-owned to model-owned | `AsyncSequence`, `AsyncStream`, `for await`, `.task(id:)` over a stream, debounce, live updates, socket feed, `AsyncAlgorithms` |

## navigation — moving between and over screens

`NavigationStack` itself is not covered here (see *Gaps*); these files cover the roots,
the presentations and the motion between them.

| File | Owns | Triggers |
|---|---|---|
| `navigation-tabs.md` | Top-level sections | `TabView`, `Tab`, `TabRole`, `tabViewStyle`, sidebar adaptation, "bottom bar", "tab doesn't keep its stack" |
| `navigation-split.md` | Sidebar-plus-detail roots on iPad and Mac | `NavigationSplitView`, `columnVisibility`, three-column, "sidebar", manual `HStack` columns |
| `navigation-modal.md` | Content presented *over* the current context, and its sizing | `.sheet`, `.fullScreenCover`, `.popover`, `presentationDetents`, `presentationDragIndicator`, "half sheet", "modal won't dismiss", "sheet is blank" |
| `navigation-transitions.md` | Views entering and leaving, and element continuity across a change | `.transition`, `AnyTransition`, `matchedGeometryEffect`, `NavigationTransition`, `.zoom`, `matchedTransitionSource`, "hero animation", "shared element", interactive dismiss |

## view — everything on screen

Three areas split a decision file from a recipe file. Read the decision file first; the
recipe file assumes it.

| File | Owns | Triggers |
|---|---|---|
| `view-layout.md` | Arranging and sizing: stacks, grids, flow, safe areas, alignment guides | `HStack`, `VStack`, `ZStack`, `Grid`, `LazyVGrid`, `ViewThatFits`, `Layout` protocol, `frame`, `fixedSize`, `layoutPriority`, `safeAreaInset`, `alignmentGuide`, `GeometryReader`, "won't size correctly", "content clipped" |
| `view-composition.md` | Cutting a screen into view types and what that costs at update time; `@ViewBuilder` containers; UIKit/AppKit bridging | "extract a subview", "body too long", computed property vs view struct, `@ViewBuilder`, `AnyView`, `ViewModifier`, `EquatableView`, `UIViewRepresentable`, `NSViewRepresentable`, "re-renders too much", "slow scrolling" |
| `view-lists.md` | Row-shaped data — the container choice, identity rules, row chrome, sections, selection, swipe, reordering | `List`, `Table`, `ForEach`, `LazyVStack`, `id:`, `Identifiable`, `listStyle`, `listRowInsets`, `listRowBackground`, `swipeActions`, `onMove`, `onDelete`, `EditButton`, "rows lose state", "wrong row animates" |
| `view-lists-patterns.md` | **Large — use its lookup table.** Worked list and table recipes | empty state, `searchable`, `refreshable`, batch selection, persisted reorder, swipe-to-delete with undo, pinned sections, `DisclosureGroup`, outline, adaptive grid, infinite scroll, skeleton rows, sortable/adaptive `Table` |
| `view-scroll.md` | Choosing and configuring a scrolling container | `ScrollView`, `scrollPosition`, `scrollTargetBehavior`, `scrollTargetLayout`, `scrollIndicators`, `scrollDisabled`, `scrollClipDisabled`, `ScrollViewReader`, `scrollBounceBehavior` |
| `view-scroll-patterns.md` | **Large — use its lookup table.** Worked scroll recipes | pinned to bottom, jump to anchor, threshold chrome, stretchy hero, `scrollTransition`, paging, snapping carousel, pagination sentinel, restored position, scroll progress readout |
| `view-forms.md` | Data entry: `Form` + `Section` structure, focus traversal, and the hand-off to FormsKit | `Form`, `Section`, `TextField`, `SecureField`, `@FocusState`, `submitLabel`, `onSubmit`, `keyboardType`, `textContentType`, validation, submit button state |
| `view-theming.md` | Design tokens — colors, gradients, spacing, shadows, typography — and how a view consumes them | `Color`, `Gradient`, `ShapeStyle`, `.font`, `colorScheme`, dark mode, "brand colors", "hardcoded hex", spacing scale, `@Environment(\.theme)` |
| `view-animation.md` | Animating a view that stays in the tree: trigger choice, where `.animation` goes, springs, what not to animate | `withAnimation`, `.animation(_:value:)`, `.spring`, `.easeInOut`, `Animation`, `animation(_:body:)`, "animation fires on every change", "whole screen animates" |
| `view-animation-advanced.md` | Sequences, the transaction system, custom interpolation | `PhaseAnimator`, `KeyframeAnimator`, `Transaction`, `transaction`, `Animatable`, `AnimatableData`, `TimelineView`, animation completion |
| `view-effects.md` | Visual treatment of an already-laid-out view | `.background`, `Material`, `.blur`, `.shadow`, `.mask`, `.clipShape`, `.blendMode`, `.compositingGroup`, `.visualEffect`, `.drawingGroup`, `.containerBackground`, "shadow clipped", "blur is slow" |
| `view-effects-glass.md` | The system control material on custom views | `.glassEffect`, `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `.buttonStyle(.glass)`, Liquid Glass, morphing glass shapes |
| `view-effects-canvas.md` | Escape hatches below the view system | `Canvas`, `GraphicsContext`, `.colorEffect`, `.distortionEffect`, `.layerEffect`, Metal shader, `ShaderLibrary`, "draw thousands of items" |
| `view-gestures.md` | Recognising touch, pointer and trackpad input | `TapGesture`, `DragGesture`, `LongPressGesture`, `MagnifyGesture`, `RotateGesture`, `@GestureState`, `simultaneously`, `sequenced`, `exclusively`, `highPriorityGesture`, "gesture conflicts with scroll" |

## data — where data comes from and where it goes

| File | Owns | Triggers |
|---|---|---|
| `data-persistence.md` | On-device storage: store choice, SwiftData models, container and context, queries, migrations, CloudKit, small values | `@Model`, `@Query`, `ModelContainer`, `ModelContext`, `SortDescriptor`, `Predicate`, `SchemaMigrationPlan`, `@AppStorage`, `@SceneStorage`, `UserDefaults`, CloudKit sync, "where do I save this" |
| `data-networking.md` | HTTP and WebSocket APIs: client shape, `URLSession`, the request/response lifecycle | `URLSession`, `URLRequest`, `JSONDecoder`, status-code handling, retry, auth headers, `URLSessionWebSocketTask`, OpenAPI generated client, "API client" |
| `data-media.md` | Images, video, audio: loading, downsampling, playback, recording, previewing | `Image(uiImage:)`, `AsyncImage`, `CGImageSource`, downsample, `AVPlayer`, `VideoPlayer`, `AVAudioSession`, `PhotosPicker`, camera capture, "memory spike on images" |

## system — the app's relationship with the OS

| File | Owns | Triggers |
|---|---|---|
| `system-accessibility.md` | Usability via VoiceOver, Voice Control, Dynamic Type and the accessibility settings; includes an audit checklist | `accessibilityLabel`, `accessibilityValue`, `accessibilityHint`, `accessibilityAddTraits`, `accessibilityElement(children:)`, `AccessibilityRepresentation`, `dynamicTypeSize`, `ScaledMetric`, `accessibilityReduceMotion`, `accessibilityDifferentiateWithoutColor`, "a11y", "VoiceOver reads it wrong" |
| `system-localization.md` | Every string the user reads; includes an audit checklist | String Catalog, `.xcstrings`, `LocalizedStringKey`, `LocalizedStringResource`, `String(localized:)`, `AttributedString`, `.formatted()`, `Text(_:format:)`, pluralisation, RTL, "hardcoded string", "translation breaks layout" |
| `system-capabilities.md` | What the app must ask for, or does unobserved: permissions, notifications, background work, keychain, biometrics; includes a checklist | `Info.plist` usage description, authorization status, `UNUserNotificationCenter`, APNs, `BGTaskScheduler`, `backgroundTask`, `SecItemAdd`, `kSecAttrAccessible`, `LAContext`, Face ID, "permission denied", "token storage" |
| `system-extensions.md` | Surfaces outside the app process: widgets, controls, Live Activities, Siri, Shortcuts, share sheet | `AppIntent`, `WidgetKit`, `TimelineProvider`, `ControlWidget`, `ActivityKit`, `AppShortcutsProvider`, app group, shared container, "widget won't update", "extension can't see my data" |
| `system-haptic.md` | Feedback the user feels | `.sensoryFeedback`, `SensoryFeedback`, `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, haptics, vibration |
| `system-macos.md` | What a Mac app has that an iPhone app does not; includes a checklist | `WindowGroup`, `Window`, `Settings`, `MenuBarExtra`, `.commands`, `CommandMenu`, `keyboardShortcut`, `windowStyle`, `.onHover`, `NSViewRepresentable`, sandbox entitlements, `fileImporter`, "Mac version", Catalyst |

## craft — project mandates

These are decisions already taken. Where they say *never*, do not re-open the trade-off;
find the package's API instead.

| File | Owns | Triggers |
|---|---|---|
| `craft-themekit.md` | Design tokens come from ThemeKit | ad-hoc `Theme` struct, `Color.brandPrimary` extension, `@Environment(\.theme)`, branching on `colorScheme` to pick a colour |
| `craft-formskit.md` | Validated forms come from FormsKit | per-field `@State var emailError`, `isValid` computed over raw `@State`, form view model, regex check in a body, `@Validated`, `FormController`, `ValidatableForm` |
| `craft-streamui.md` | Long-lived `AsyncSequence` reaches views through StreamUI | hand-rolled subscription plumbing, manual `Task` + `for await` in a model, `@Streamed` |
| `craft-userkit.md` | Current user and session come from UserKit | sign-in, sign-out, session refresh, `currentUser`, auth state, "am I logged in", token refresh |
| `craft-hygiene.md` | Tooling, CI and review conventions | `swiftformat`, `swiftlint`, zero-warning policy, strict concurrency settings, `Sendable` domain types, `@unchecked Sendable`, secrets policy, DocC, `#Preview` coverage, Swift Testing (`@Suite`, `@Test`, `#expect`) |

---

## Gaps

If the symbol you are looking for is not on this page, this directory does not cover it —
`../SKILL.md` § *Not covered here* lists the known omissions and what to do instead.
Do not invent a reference file for them.

---

*Maintaining this directory: `python3 scripts/validate.py` checks the frontmatter against
the agentskills.io spec and verifies the conventions above — that every **area/topic**
resolves, every file opens with a scope line, and nothing is unreachable from `../SKILL.md`
or this page. Run it after adding or renaming a file.*
