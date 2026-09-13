# Hygiene

Best practices for code quality, formatting, strict concurrency, and project hygiene on
modern iOS and macOS (Swift 6 / SwiftUI). Companion to **state/primitives** (the
`@Observable` rules), **view/composition** (why bodies stay flat) and
**system/capabilities** (secret storage).

## Tooling Hygiene

### SwiftFormat
- Format code deterministically before committing (`swiftformat .`).
- Follow project configuration without introducing formatting-only churn in functional
  PRs.
- Key rules: 4-space indentation, consistent trailing commas in multiline
  collections/parameters, and sorted imports.

### SwiftLint
- **Zero warnings policy**: Treat lint warnings as errors. CI must pass with zero
  issues.
- Never disable lint rules globally to work around localized code smells.
- If a temporary exclusion is unavoidable, use precise inline disables with rationale:
  ```swift
  // swiftlint:disable:next force_unwrapping - Invariant guaranteed by test setup
  let url = URL(string: "https://example.com")!
  ```

## Strict Concurrency & Swift 6

Set the project language mode to Swift 6 and enable `-strict-concurrency=complete` on
the app target. This surfaces data-race errors at compile time.

- Keep shared domain entities, events, and parameters `Sendable` (prefer immutable
  `struct` and `enum`).
- Avoid `@unchecked Sendable`. When interfacing with legacy non-Sendable types, wrap
  them inside an isolated `actor` or boundary adapter.
- Enable *Approachable Concurrency* (`MainActor` default isolation +
  `NonisolatedNonsendingByDefault`) on the app target, as **craft/userkit** requires.
  With it on, `@Observable` stores need no explicit `@MainActor`; without it they
  annotate it per **state/primitives**.

Task lifecycle and `.task(id:)` coordination live in **state/streams**; actor isolation
rules for `@Observable` in **state/primitives**.

## Secrets & Sensitive Storage

Never commit secrets (API keys, tokens, certificates) — use `.xcconfig`, environment
variables or secret managers. `@AppStorage` is unencrypted; use it for settings and
toggles only, never for credentials. Use Keychain for passwords, session tokens and PII;
see **system/capabilities** for access control and `kSecUseDataProtectionKeychain`
mechanics.

## Documentation & Strings

Write code that reads as self-evident intent; comment the *why*, not the *what*. Add
DocC comments (`///`) to public module APIs, custom ViewModifiers, design system tokens,
and non-trivial domain algorithms. String Catalogs, the literal-first rule, and
localization mechanics live in **system/localization**.

## Testing Discipline

- **Unit tests first**: Cover domain logic, state machines, validation rules, and
  network mappers using Swift Testing (`@Suite`, `@Test`, `#expect`).
- **UI tests sparingly**: Reserve UI tests for critical user journeys (e.g., login,
  payment checkout). If logic can be verified via unit tests, do not use a UI test.
- **Xcode Previews**: Provide `#Preview` with mock/in-memory data covering light/dark
  mode, accessibility dynamic types, and edge cases.

## SwiftUI Code Conventions

View wrappers (property vs state vs binding choice), body composition, and invalidation
rules live in **state/primitives** and **view/composition**. Mark view-internal `@State`
properties as `private`. Inject external state via dependencies or `@Bindable`.
