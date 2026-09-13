# macOS

What a Mac app has that an iPhone app does not: many windows, a menu bar, a Settings
window, a pointer and a keyboard. Companion to **navigation/split** (the sidebar layout
that dominates Mac windows), **system/capabilities** (entitlements and the sandbox) and
**view/theming**.

**The Mac idioms are SwiftUI scenes, not AppKit.** `Settings`, `MenuBarExtra`,
`UtilityWindow` and `Commands` give you the preferences window, the status item, a
floating palette and the menu bar without touching `NSWindow`, `NSStatusItem` or an app
delegate. Reaching for AppKit first is the most common mistake in a Mac SwiftUI app.

Gate everything Mac-only with `#if os(macOS)` — a multiplatform target compiles the whole
`App` body for both.

## Scenes

| Scene | Use for | macOS-only |
|---|---|---|
| `WindowGroup` | The primary scene. Many windows, tabbing, automatic Window menu | no |
| `Window` | A supplementary *singleton* — a console, an activity panel | no |
| `UtilityWindow` | A floating inspector / tool palette | yes |
| `Settings` | Preferences, wired to ⌘, automatically | yes |
| `MenuBarExtra` | A persistent status-bar item | yes |
| `DocumentGroup` | Document apps — brings the whole File menu with it | no |

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        Settings { SettingsView() }

        Window("Console", id: "console") { ConsoleView() }

        UtilityWindow("Inspector", id: "inspector") { InspectorView() }

        MenuBarExtra("Status", systemImage: "bolt") { StatusMenu() }
            .menuBarExtraStyle(.window)
        #endif
    }
}
```

- **`WindowGroup` keeps the app alive when its last window closes; a lone `Window` quits
  with it.** That is the whole difference, and it decides which one your main scene is.
- **`openWindow` is the way in.** `@Environment(\.openWindow)` then `openWindow(id:)` for a
  `Window`/`UtilityWindow`, `openWindow(value:)` for a `WindowGroup` declared
  `for:`. Both bring an existing window forward rather than duplicating it. `dismissWindow`
  is the mirror.
- **`UtilityWindow` reads `@FocusedValue` from whichever main window is focused** — that is
  what makes an inspector track the front document with no wiring of your own. It floats,
  hides when the app deactivates, and closes on Escape.
- **A menu-bar-only app** is `MenuBarExtra` as the sole scene plus `LSUIElement = true`.
  `.menuBarExtraStyle(.window)` gives a popover panel instead of a menu; give its content an
  explicit `.frame(width:)`.

## Settings

```swift
struct SettingsView: View {
    @AppStorage("showPreviews") private var showPreviews = true

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") {
                Form { Toggle("Show previews", isOn: $showPreviews) }
            }
            Tab("Advanced", systemImage: "slider.horizontal.3") {
                Form { /* … */ }
            }
        }
        .scenePadding()
        .frame(maxWidth: 420, minHeight: 240)
    }
}
```

- **Settings is flat.** `TabView` of `Form`s. No `NavigationStack`, no toolbar, no
  full-screen iOS settings layout ported across; if the hierarchy is genuinely deep, one
  `NavigationSplitView` with a category sidebar, nothing more.
- **Give the window a size.** The scene sizes to its content, so an unconstrained `Form`
  produces a window of the wrong shape. `.scenePadding()` + a `maxWidth`/`minHeight`.
- **In-app entry points:** `SettingsLink` for a button, `@Environment(\.openSettings)` when
  you must open it from code.

## Window chrome

```swift
WindowGroup {
    ContentView().frame(minWidth: 600, minHeight: 400)
}
.defaultSize(width: 900, height: 600)
.defaultPosition(.center)
.windowResizability(.contentMinSize)
.windowStyle(.hiddenTitleBar)          // media players, custom chrome
.windowToolbarStyle(.unified)          // .unifiedCompact, .expanded
```

- **Minimums live on the content `.frame`; `.windowResizability(.contentMinSize)` enforces
  them.** `.contentSize` freezes the window entirely and kills the zoom button — use it only
  for genuinely fixed panels.
- `.unified` or `.unifiedCompact` for almost everything; `.expanded` only when a separate
  title row buys you toolbar space.
- `windowIdealPlacement { context in … }` when placement must be computed from the display
  geometry.

## Menu bar and keyboard

```swift
.commands {
    CommandGroup(after: .newItem) {
        Button("New from Template…") { }
    }
    CommandMenu("Tools") {
        Button("Run Analysis") { }
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}
```

- `CommandMenu` adds a top-level menu; `CommandGroup(before:/after:/replacing:)` slots into
  a system one (`.newItem`, `.saveItem`, `.sidebar`, `.toolbar`, `.help`).
- **Commands act on the focused window**, so they read state through `@FocusedValue` /
  `FocusedValueKey`, not a global. The same `.commands` block also produces key commands on
  iPad, so it is not wasted on a multiplatform app.
- `.keyboardShortcut` surfaces in the menu item and in button tooltips automatically — a Mac
  user expects one on every repeatable action.

## Views that differ on the Mac

- **`NavigationSplitView` for sidebar-driven navigation**; `HSplitView` / `VSplitView`
  (macOS-only) only for IDE-style panes that are equal peers. Size columns with
  `.navigationSplitViewColumnWidth(min:ideal:max:)`.
- **`.inspector(isPresented:)`** is the trailing panel, resizable via
  `.inspectorColumnWidth(min:ideal:max:)` — prefer it over a hand-rolled trailing column.
- **`Table`** is a real multi-column table here: `.tableStyle(.bordered(alternatesRowBackgrounds: true))`,
  `.inset`, `.tableColumnHeaders(.hidden)`. Design the first column to carry the row's
  identity, because it is what survives when the same `Table` renders compact on iOS.
- **`PasteButton` does not auto-validate the pasteboard on macOS** as it does on iOS;
  `CopyButton(item:)` (macOS-only) is the copy half.
- **Drag and drop crosses app boundaries** — a `.draggable` item can land in Finder or Mail,
  and `.dropDestination` accepts from anywhere. Conform to `Transferable`; `NSItemProvider`
  is the legacy spelling.
- **Hover and pointer are real inputs.** `.onHover`, `.pointerStyle`, `.help("…")` tooltips
  and context menus are expected affordances, not extras.

## Files and the sandbox

```swift
.fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf]) { result in
    guard case .success(let urls) = result, let url = urls.first else { return }
    guard url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }
    // read url
}
.fileDialogMessage("Choose a document to import")
.fileDialogConfirmationLabel("Import")
```

- **URLs from `fileImporter` are security-scoped.** Without the
  `start`/`stopAccessingSecurityScopedResource()` pair the read fails in a sandboxed app —
  and it *works* in a debug build outside the sandbox, which is how this ships broken.
- To reopen a file later, store a **security-scoped bookmark**
  (`url.bookmarkData(options: .withSecurityScope)`), not the path.
- `fileDialogMessage`, `fileDialogConfirmationLabel` and `fileExporterFilenameLabel` are
  macOS-only polish on the standard panels.

## AppKit interop

`NSViewRepresentable` / `NSViewControllerRepresentable` wrap AppKit going in;
`NSHostingView` / `NSHostingController` embed SwiftUI going out. Same shape as the UIKit
pair — a `Coordinator` for delegate callbacks, and **never set `frame` or `bounds` on the
managed view**, SwiftUI owns layout.

Use it only for what SwiftUI genuinely lacks. Wrapping `NSWindow`, `NSStatusItem` or
`NSOpenPanel` by hand means you missed the scene that already does it.

## Checklist

- [ ] Mac-only scenes and modifiers behind `#if os(macOS)`
- [ ] `WindowGroup` primary; `Window` only for singletons; `openWindow` used to surface them
- [ ] `Settings` scene present, flat, and explicitly sized
- [ ] Content minimums + `.windowResizability(.contentMinSize)` + `.defaultSize`
- [ ] `Commands` and keyboard shortcuts for every repeatable action, reading `@FocusedValue`
- [ ] Security-scoped access paired around every imported URL; bookmarks for persistence
- [ ] Hover, tooltips and context menus wired for pointer users
