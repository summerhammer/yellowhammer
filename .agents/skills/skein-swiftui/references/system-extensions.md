# System extensions

Your app's surfaces *outside* the app: widgets, controls, Live Activities, Siri and
Shortcuts, the share sheet. Companion to `scenePhase` (a separate process has its own
launch), **state/injection** (an extension cannot see your app's object graph) and
**data/persistence** (the shared store is the only channel between them).

**One rule shapes everything below: the `AppIntent` is the API.** Since iOS 17, a widget
button, a Control Center control, a Live Activity action, a Siri phrase, a Spotlight result
and a Shortcuts step all invoke the same intent type. Write the action once as an intent,
and every surface is wiring. Code that reaches an extension any other way — a URL scheme
parsed by hand, a `UserDefaults` flag polled on launch — is re-implementing intents badly.

## Targets and sharing

An extension is a **separate process with its own memory budget** (widgets get roughly
30 MB and are killed, not throttled, past it). Nothing is shared automatically.

| Needs sharing | How |
|---|---|
| Views, models, intents | A Swift package / framework both targets link |
| Stored data | App Group container — `ModelConfiguration(groupContainer:)`, or a shared `URL` |
| Small values | `UserDefaults(suiteName:)`, `@AppStorage(_:store:)` |
| Nothing | `@Observable` app state, singletons, in-memory caches |

Put the intent types in the **shared package**, not in the app target — a widget that
cannot see the intent it references fails at build time in the extension only, which is a
confusing diagnostic. Keep the extension's slice of the package free of heavy dependencies;
it pays the launch cost on every timeline refresh.

## App Intents

```swift
struct MarkTaskDone: AppIntent {
    static let title: LocalizedStringResource = "Mark Task Done"
    static let supportedModes: IntentModes = .background    // iOS 27; .foreground opens the app

    @Parameter(title: "Task") var task: TaskEntity

    @Dependency private var store: TaskStore   // app process only — see below

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await store.complete(task.id)
        return .result(dialog: "Done.")
    }
}
```

- **`@Dependency` is resolved by the app**, via `AppDependencyManager.shared.add(…)` at
  launch. An intent that runs in a widget or App Intents extension has no dependency
  container — such an intent must read the shared store directly. `allowedExecutionTargets`
  (iOS 27) makes that constraint explicit instead of a crash.
- **Expose entities, not strings.** An `AppEntity` + its query is what lets Shortcuts,
  Spotlight and Siri offer your content as a parameter. Add `IndexedEntity` to appear in
  Spotlight; `EntityCollection` (iOS 27) when the set is large enough that resolving every
  identifier would be wasteful.
- **Long work needs `LongRunningIntent`** (iOS 27) and regular `progress` updates —
  background intents otherwise get ~30 s. Pair with `CancellableIntent` for cleanup and
  `UndoableIntent` where the action is destructive.
- **Errors should be legible.** `AppIntentError(description:)` or a
  `CustomLocalizedStringResourceConvertible` error; a bare `throw` surfaces as a generic
  system failure.

### App Shortcuts

```swift
struct Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkTaskDone(),
                    phrases: ["Complete a task in \(.applicationName)"],
                    shortTitle: "Complete Task",
                    systemImageName: "checkmark.circle")
    }
}
```

Every phrase **must** interpolate `\(.applicationName)`, the provider must be in the app
target, and the list is read at install time — `updateAppShortcutParameters()` after
changing the entities a phrase can match.

## Widgets

```swift
@main
struct Widgets: WidgetBundle {
    var body: some Widget { TaskWidget(); TaskControl() }
}

struct TaskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TaskWidget",
                               intent: SelectListIntent.self,
                               provider: Provider()) { entry in
            TaskWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .pushHandler(TaskPushHandler.self)      // iOS 26
    }
}
```

- **`AppIntentConfiguration` over `StaticConfiguration`** whenever the widget has any
  user-facing choice; the configuration UI is generated from a `WidgetConfigurationIntent`.
- **`containerBackground(_:for: .widget)` is mandatory** — without it the widget cannot be
  placed on the Lock Screen, iPad Home Screen or the Mac desktop.
- **The timeline is a budget, not a schedule.** Return several entries covering the next
  few hours and a `.after(_:)` policy; the system decides when to honour it. For
  event-driven freshness use `WidgetCenter.shared.reloadTimelines(ofKind:)` from the app, or
  a `WidgetPushHandler` (iOS 26) so the server pushes the reload.
- **Navigation is `widgetURL(_:)` or `Link`** — one `widgetURL` for the whole widget,
  `Link`s for per-row targets on medium and larger. Prefer URLs your app already handles
  (`URLRepresentableIntent` gives you one for free).
- **Interaction is `Button(intent:)` / `Toggle(isOn:intent:)`.** The system reloads the
  timeline after the intent performs; do not call `reloadTimelines` from inside it.
- **Rendering modes matter.** `.widgetAccentable()` and `WidgetAccentedRenderingMode` (iOS
  26) control how images survive the accented, tinted and Liquid Glass treatments. Check
  `@Environment(\.widgetRenderingMode)` rather than assuming full colour.
- **macOS**: the same widget appears in Notification Center and on the desktop, and an
  iPhone widget shows on the Mac via Continuity — so it must tolerate having *no* app
  installed alongside it.

## Controls

A control is a widget whose body is a single action, for Control Center, the Lock Screen and
the Action button (iOS 18+; watchOS and macOS 26+):

```swift
struct TaskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StartTimer") {
            ControlWidgetToggle("Focus", isOn: FocusState.isOn, action: SetFocus()) { isOn in
                Image(systemName: isOn ? "moon.fill" : "moon")
            }
        }
    }
}
```

The toggle's intent conforms to `SetValueIntent`; its displayed state comes from a
`ControlValueProvider`, read from the shared store. Controls have **no timeline** — they
refresh when the system asks, so the value lookup must be cheap and synchronous-ish.

## Live Activities

```swift
struct DeliveryAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var stage: Stage; var eta: Date }
    let orderNumber: String
}

// In the widget bundle:
ActivityConfiguration(for: DeliveryAttributes.self) { context in
    LockScreenView(state: context.state)          // Lock Screen / banner / Mac menu bar
} dynamicIsland: { context in
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { … }
        DynamicIslandExpandedRegion(.center)  { … }
    } compactLeading: { … } compactTrailing: { … } minimal: { … }
}
```

Start, update and end from the app:

```swift
guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
let activity = try Activity.request(attributes: attributes,
                                    content: .init(state: state, staleDate: .now + 600),
                                    pushType: .token)
await activity.update(.init(state: newState, staleDate: …),
                      alertConfiguration: .init(title: "Arriving", body: "2 minutes away",
                                                sound: .default))
await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 60))
```

- **`ContentState` is the only mutable part** and it travels in a push payload — keep it
  small and `Codable`; anything fixed belongs in the attributes.
- **Always set a `staleDate`** and render the stale case (`context.isStale`). A Live Activity
  showing a wrong ETA forever is worse than one that says it lost contact.
- **Push is the norm, not the exception.** `pushType: .token` plus server updates; the app
  is not guaranteed runtime. `.channel` covers broadcast to many subscribers.
- **Same code, four places.** As of iOS 26 the activity also appears in the **Mac menu bar**
  and **CarPlay** with no extra work, and in the watch Smart Stack — so branch on
  `@Environment(\.activityFamily)` and `\.isLuminanceReduced` rather than designing only for
  the Dynamic Island. `request(…, start:)` schedules one for a future time.

## Share and action extensions

These are the one surface with **no SwiftUI-native scene**. The principal object is still a
`UIViewController` reading `extensionContext?.inputItems` as `NSExtensionItem`s; host your
SwiftUI in a `UIHostingController` and finish with
`extensionContext?.completeRequest(returningItems: nil)`. `ExtensionKit`'s
`AppExtensionScene` is for extensions hosted by *your own* app, not the share sheet.

Two things save most of the work:

- **Load items through `Transferable`/`loadItem(forTypeIdentifier:)` once**, in a helper in
  the shared package, and declare accepted types via `NSExtensionActivationRule` — a rule of
  `TRUEPREDICATE` means your extension appears for content it cannot open.
- **Don't process in the extension.** Write the payload into the App Group container and let
  the app (or a `BGProcessingTask`) do the work; share extensions are killed quickly and
  have no reliable background time.

For the *outbound* direction there is nothing to build: `ShareLink` over a `Transferable`
type is the whole of it.

## Pitfalls

- **Don't put business logic in a timeline provider.** It runs on a tight budget in a
  memory-capped process. Read a prepared value from the shared store; compute in the app.
- **Don't expect `@Observable` state to cross the process boundary.** It cannot. Every
  extension reads the shared container, and every mutation from an extension goes through an
  intent so the app converges on the same data.
- **Don't animate in a widget.** Widget views are rendered as snapshots; only the
  system's own transitions between entries exist. `.contentTransition`/`.numericText()` on a
  changing value is the available tool.
- **Don't ship a widget without `.accessoryRectangular`/`.accessoryCircular` considered** —
  and check `widgetRenderingMode` before relying on colour to carry meaning.
- **Don't test extensions only in the Simulator.** Timeline budgets, push reloads, Live
  Activity alerts and the Action button behave differently on device; a widget that never
  refreshes in the field usually looked fine in the canvas.
- **Don't let an intent silently succeed** when it needed the app. Return the correct
  `IntentModes`/`openAppWhenRun` instead of failing quietly in the background.
- **Version the shared store.** App and extension update together, but an old extension
  process can outlive an app update — decode defensively.
