# UserKit (User Management)

**Mandatory.** The current user and session come from
[UserKit](https://github.com/rozd/user-kit). Do not hand-roll an auth/session layer.
Companion to **state/injection** (where the session is injected),
**system/capabilities** (keychain and biometrics) and **data/persistence**.

Requires Swift 6.2+, iOS 18+, macOS 15+, with *Approachable Concurrency* (`MainActor`
default isolation + `NonisolatedNonsendingByDefault`) on the app target so isolation
lines up across the package boundary.

## Rules

- **Never** write an `AuthManager` / `SessionStore` / `CurrentUser` singleton, an
  `isLoggedIn` `@AppStorage` flag, or a `@Published var user`.
- **Never** import a provider SDK (Firebase, Auth0, …) outside the single adapter-wiring
  file. Views import only `UserKit`.
- **Never** persist tokens yourself — that is `UserStorage`'s job, supplied by the
  adapter.
- Exactly one `User` instance exists, injected once via `.environment(...)` and read
  with `@Environment(User.self)`.
- Authenticated work goes through `withAuthentication { … }`, never through a manually
  cached token.

## Wiring (one file, the only place the adapter is imported)

```swift
import UserKit
import UserKitFirebase   // or another adapter

extension User {
    @MainActor static let current = User(
        service: FirebaseUserService(configuration: .init(
            authDomain: "auth.example.com",
            bundleID: Bundle.main.bundleIdentifier!
        )),
        storage: FirebaseUserStorage(),
        synchronizer: FirebaseUserSynchronizer()
    )
}

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup { RootView().environment(User.current) }
    }
}
```

## Usage

```swift
struct ProfileView: View {
    @Environment(User.self) private var user

    var body: some View {
        if user.isAuthenticated {
            Text(user.info?.profile.displayName ?? "Signed in")
            if user.isAdmin { AdminPanelLink() }
            Button("Sign out") { Task { try? await user.signOut() } }
        } else {
            Button("Sign in") { Task { try? await user.signIn() } }
        }
    }
}
```

`User` is `@Observable`, so views update on sign-in, sign-out, and token refresh with no
extra plumbing.

## API surface

| Member | Use |
| --- | --- |
| `info` | Snapshot (`id`, `session`, `profile`, `role`), `nil` when signed out. |
| `isAuthenticated` / `isAdmin` | Gate UI. |
| `signIn()` / `signOut()` | Provider sign in/out. |
| `authenticate()` | Present the provider's auth UI. |
| `withAuthentication { … }` | Run work with a guaranteed-valid session (refreshes as needed). |
| `infos` | `AsyncSequence` of distinct user changes — the seam into [craft-streamui](craft-streamui.md). |

## New providers

Write an adapter package, never a fork. Conform to `UserService`, `UserStorage`,
`UserSynchronizer` (behaviour) and `UserInfo`, `UserSession`, `UserProfile` (data); see
[`user-kit-firebase`](https://github.com/rozd/user-kit-firebase) as the reference.
