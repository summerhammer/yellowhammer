# System capabilities

Everything the app must *ask* for, or that runs while nobody is looking: permissions,
notifications, background execution, secrets, biometrics. Companion to `scenePhase` (the
scene phases these hang off), **system/extensions** (a second process with its own
permissions) and **data/persistence** (where the results land).

**Two rules run through all of it.** A capability is *denied by default and revocable at any
moment* — model it as state you re-read, never as a `Bool` you cache at launch. And the
system dialog is the *last* step of a request, not the first: the user has to already want
the thing before the alert appears, or you spend the one prompt you get.

## Shape: one observable per capability

```swift
@Observable
@MainActor
final class NotificationAccess {
    private(set) var status: UNAuthorizationStatus = .notDetermined

    func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Returns the *resulting* status — callers branch on it, they don't assume success.
    @discardableResult
    func request() async -> UNAuthorizationStatus {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
        return status
    }
}
```

Inject it with `.environment(_:)` (see **state/injection**) and `await refresh()` from
`.task` plus on `scenePhase == .active` — the user can revoke in Settings while you are
backgrounded, and nothing tells you. A `PermissionManager` singleton holding every
capability behind `static let shared` is the anti-pattern: it makes previews and tests
impossible and hides which screen actually needs what.

## Asking

| Capability | Ask with | Read status from | Info.plist |
|---|---|---|---|
| Notifications | `requestAuthorization(options:)` | `notificationSettings()` | — |
| Location | `requestWhenInUseAuthorization()` | `CLLocationManager.authorizationStatus` | `NSLocation*UsageDescription` |
| Camera / mic | `AVCaptureDevice.requestAccess(for:)` | `authorizationStatus(for:)` | `NSCamera` / `NSMicrophoneUsageDescription` |
| Photo library | `PHPhotoLibrary.requestAuthorization(for:)` | `authorizationStatus(for:)` | `NSPhotoLibraryUsageDescription` |
| Contacts, Calendar, … | framework's own `request…` | framework's own status | matching usage string |

- **`PhotosPicker` and the camera `.fileImporter` need no permission at all.** They run
  out of process and hand you back only what the user picked. Requesting library access to
  show a grid you built yourself is a downgrade — reach for the system picker first.
- **The usage string is UI.** It is the only sentence in the alert you control; say what the
  user gets, not what the app does ("Find restaurants near you", ✗ "This app uses location").
  A missing string is a launch-time crash, not a denial.
- **`.denied` is terminal.** You cannot re-prompt. Show an explanation plus a button to
  `UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)`
  (macOS: `x-apple.systempreferences:` URL). Silently degrading with no explanation is the
  most common permission bug.
- **macOS also needs entitlements.** Sandboxed Mac apps require the matching
  `com.apple.security.device.camera` / `.audio-input` / `personal-information.location`
  entitlement *in addition* to the usage string; hardened-runtime apps need it for the
  notarised build too. The failure mode is a silent no-device, not a dialog.

## Notifications and push

```swift
@main struct MyApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ app: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self   // must be set before launch returns
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { await Server.register(token: token.map { String(format: "%02x", $0) }.joined()) }
    }

    // Foreground presentation — without this, notifications are swallowed while the app is open.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
```

- **`UNUserNotificationCenterDelegate` must be assigned before `didFinishLaunching`
  returns**, or a tap that launched the app is never delivered. This is the one thing that
  genuinely requires an app delegate adaptor in a SwiftUI app.
- **Authorization and APNs registration are separate.** `requestAuthorization` governs the
  *display*; `registerForRemoteNotifications()` produces the token. Call registration on
  every launch — the token rotates on restore, reinstall and OS update — and treat the
  callback, not a stored copy, as the source of truth.
- **`.provisional` costs nothing.** It delivers quietly to Notification Center with no
  dialog, and the user promotes or mutes from the notification itself. For anything not
  time-critical this converts far better than an alert at first launch.
- **Actions are `AppIntent`s** (see **system/extensions**) — the same intent backs a
  notification button, a widget and Siri. A `UNNotificationAction` handled by a string
  `identifier` switch is the old spelling.
- **Content-changing pushes need a notification service extension**; silent pushes
  (`content-available: 1`) are budgeted and dropped freely — never make correctness depend
  on one arriving.

## Background execution

Three distinct things, routinely confused:

| Need | API | Notes |
|---|---|---|
| Finish work started by a tap | `BGContinuedProcessingTask` (iOS 26) | Starts in foreground, continues after; shows a system Live Activity |
| Periodic refresh | `BGAppRefreshTaskRequest` + `.backgroundTask(.appRefresh(_:))` | Minutes, opportunistic, no schedule guarantee |
| Long / deferrable processing | `BGProcessingTaskRequest` | Usually overnight on charge |
| Large transfer | `URLSessionConfiguration.background` + `.backgroundTask(.urlSession(_:))` | Survives termination |

```swift
WindowGroup { ContentView() }
    .backgroundTask(.appRefresh("com.example.refresh")) {
        await store.refresh()
        await scheduleNextRefresh()   // re-submit: a request fires at most once
    }
```

- Every identifier must appear in `BGTaskSchedulerPermittedIdentifiers` and be re-submitted
  after each run. Register handlers *before* `didFinishLaunching` returns.
- **The closure runs under a hard deadline.** Honour cancellation
  (`withTaskCancellationHandler`) and checkpoint partial progress; on expiry the system
  kills you and a half-written store is your problem.
- `BGContinuedProcessingTask` is the right answer for exports, batch encodes and ML passes:
  report `task.progress` honestly — the system deprioritises tasks that appear stuck, and
  the user can cancel from the Live Activity. Gate GPU use on
  `BGTaskScheduler.supportedResources.contains(.gpu)` plus the Background GPU Access
  entitlement.
- **`scenePhase == .background` is not background execution.** It is a notification that you
  have seconds to save state. Kicking off a network call there is a lost write.
- Core Location live updates (`CLLocationUpdate.liveUpdates()`) *require* an
  `AppDelegate` adaptor that restarts the sequence in `didFinishLaunching`, plus a
  `CLBackgroundActivitySession`; a SwiftUI app without it stops receiving updates after the
  first background launch.

## Secrets: keychain, never `@AppStorage`

`@AppStorage` / `UserDefaults` is a plist in the container — readable from a backup, synced
to a Mac, visible to anyone with the device unlocked. Tokens, passwords and keys go in the
keychain.

```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.example.api",
    kSecAttrAccount as String: userID,
    kSecValueData as String: Data(token.utf8),
    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    kSecUseDataProtectionKeychain as String: true,   // required on macOS for iOS-like behaviour
]
SecItemAdd(query as CFDictionary, nil)
```

- **Pick accessibility deliberately.** `…WhenUnlockedThisDeviceOnly` for anything a
  background task never needs; `…AfterFirstUnlockThisDeviceOnly` when a background refresh
  must read it. The default (`kSecAttrAccessibleWhenUnlocked`, which *does* migrate to new
  devices) is rarely what you want for a bearer token.
- **`kSecUseDataProtectionKeychain: true` on macOS** or you land in the legacy file-based
  keychain, with different semantics and no app-group sharing. Set it on every query.
- **Sharing with an extension** means a keychain access group (`kSecAttrAccessGroup`) in the
  entitlement — the App Group alone is not enough.
- Keychain calls are synchronous and can block on a locked device: do them off the main
  actor, and surface `errSecItemNotFound` as "signed out", never as an error alert.
- **Delete on sign-out.** Keychain items survive app deletion; the classic bug is a
  reinstall that silently resumes the previous user's session.

## Biometrics

```swift
let context = LAContext()
context.localizedFallbackTitle = "Use Passcode"

var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { … }

let ok = try await context.evaluatePolicy(
    .deviceOwnerAuthentication,                       // falls back to passcode
    localizedReason: "Unlock your saved notes")       // shown verbatim; localise it
```

- **`.deviceOwnerAuthentication` unless you mean otherwise.** `…WithBiometrics` fails hard
  when biometry is unenrolled or locked out, stranding the user with no way in.
- **`LocalAuthenticationView` is macOS 13+ only** despite being a SwiftUI view. On iOS, drive
  `LAContext` from a `.task` or a button action and render your own gate.
- **A `Bool` result protects nothing.** Anyone who can patch the binary flips it. Real
  protection binds the *secret itself* to biometry via
  `SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
  .biometryCurrentSet, &err)` on `kSecAttrAccessControl` — then the keychain refuses to
  return the data without authentication, and `.biometryCurrentSet` invalidates the item if
  a new face or finger is enrolled.
- Reuse one `LAContext` per session and `invalidate()` it on sign-out; a fresh context per
  call re-prompts every time. `touchIDAuthenticationAllowableReuseDuration` softens repeat
  prompts where the policy allows.
- Always offer a non-biometric route. Biometry is a convenience over the passcode, never the
  only door.

## Checklist

- [ ] Status re-read on `.active`, not cached at launch
- [ ] Request triggered by a user action that explains itself first
- [ ] `.denied` path shows an explanation + Settings link
- [ ] Usage strings written as user-facing copy; macOS entitlements present
- [ ] Notification delegate + APNs registration wired in `didFinishLaunching`
- [ ] Background handlers registered before launch returns, re-submitted after each run, cancellation-safe
- [ ] Secrets in the keychain with an explicit `kSecAttrAccessible`, cleared on sign-out
- [ ] Biometric gate binds the secret, not a `Bool`; passcode fallback available
