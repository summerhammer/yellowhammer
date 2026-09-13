# Forms

Data-entry screens: `Form` + `Section` for structure, [FormsKit](https://github.com/rozd/forms-kit)
once validation, submission or focus traversal is involved. Companion to **view/lists**
(the same row machinery without the input semantics) and **view/theming** (row backgrounds).

## Simple: plain `Form`

Settings screens, grouped toggles, action rows — anything with no validation and no async
submit.

- Wrap in `NavigationStack` **only** when the form is standalone or in a sheet.
- Group with `Section`; `.formStyle(.grouped)` where grouped styling is wanted.
- Custom background = `.scrollContentBackground(.hidden)` + `.background(...)` +
  `.listRowBackground(...)`. Pick one strategy; don't mix with default `Form` chrome.
- `@FocusState` for keyboard focus; `.scrollDismissesKeyboard(.immediately)` on long forms.

```swift
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    NavigationLink("Display") { DisplaySettingsView() }
                    Toggle("Haptics", isOn: $haptics)
                }
                Section("Account") {
                    Button("Edit profile") { isEditing = true }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

Pitfalls: heavy custom layout inside a `Form` fights its spacing — use `ScrollView` +
`VStack` instead. Row buttons need `.contentShape(Rectangle())` and `.buttonStyle(.plain)`
to stay tappable across the full row.

## Focus

Focus state is **view-local** — an `@FocusState` never belongs in a shared model. Declare it
`private`: `Bool` for one field, an optional `Hashable` enum for several.

```swift
enum Field: Hashable { case title, symbol }
@FocusState private var focus: Field?

TextField("Title", text: $title)
    .focused($focus, equals: .title)
    .onSubmit { focus = .symbol }      // chain fields on return
TextField("Symbol", text: $symbol)
    .focused($focus, equals: .symbol)
```

- **Initial focus:** `.defaultFocus($focus, .title)` (iOS 17+), not `onAppear`, which can fire
  before the tree settles. `focus = nil` dismisses the keyboard.
- **Dynamic rows:** an enum case with an associated value — `case option(Int)`. After
  appending a row, set focus on the next runloop tick so the field exists.
- One enum case per field. Two views bound to the same case is ambiguous and SwiftUI warns.
- `TextField`/`SecureField` are focusable implicitly; any other view needs `.focusable()`
  first, and must *not* also set focus from a tap gesture — the redundant write revokes it.
- `.searchFocused($isSearching)` targets the `.searchable` field, not a form row.

## Complex: FormsKit

Reach for it as soon as the screen has **per-field rules, an async submit, server-side field
errors, or focus that must jump to the first invalid field**. Hand-rolling those with
`@State` + booleans is the anti-pattern this replaces.

The form is a `struct` of `@Validated` fields; a `FormController` owns its submission state.

```swift
struct CreatePlanForm: ValidatableForm, SubmittableForm {
    @Validated(name: "name", .isNotEmpty(message: "Name is required"), .minLength(3))
    var name: String = ""

    @Validated(name: "email", .email())
    var ownerEmail: String = ""

    // Value key path first, wrapper key path via `wrappedBy:`.
    var validatedFields: [ValidatedField<Self>] {
        [.init(\.name, wrappedBy: \._name),
         .init(\.ownerEmail, wrappedBy: \._ownerEmail)]
    }

    @MainActor
    func submit() async throws -> Plan {
        try await api.createPlan(name: name, ownerEmail: ownerEmail)
    }
}

struct CreatePlanSheet: View {
    @State private var controller = FormController(form: CreatePlanForm())
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $controller.form.name)
                    .focused(on: $controller, equals: \.name)
                    .formValidationError(for: controller.form.$name)

                TextField("Owner email", text: $controller.form.ownerEmail)
                    .focused(on: $controller, equals: \.ownerEmail)
                    .formValidationError(for: controller.form.$ownerEmail)
            }
            .navigationTitle("New Plan")
            .formToolbar(controller: controller) {
                // Dismiss only on success — a throw leaves the sheet up so the
                // failure state and field errors stay visible.
                Task {
                    guard (try? await controller.submit()) != nil else { return }
                    dismiss()
                }
            }
        }
    }
}
```

What you get for that shape:

| Need | API |
|---|---|
| Field rules | `.isNotEmpty`, `.minLength`, `.maxLength`, `.pattern`, `.email`; custom via `ValidationRule` |
| When rules run | `mode:` — `.onChange` (default), `.always`, `.onSubmit` |
| Inline error text | `.formValidationError(for: controller.form.$field)` |
| Cancel/Submit bar + discard confirmation | `.formToolbar(controller:onSubmit:)` |
| Focus traversal | `.focused(on:equals:)`, or `.formBindFocus(_:on:)` when the view needs its own `@FocusState` |
| Submission lifecycle | `controller.state` — `.initial` / `.loading` / `.success` / `.failure` |
| Edit flows | `PopulatableForm.populate(from:)` |
| Server field errors | `throw ValidationError.invalid(errors:)` from `submit()` — mapped back onto fields by `name` |

Rules worth internalising:

- **Dismiss only after `submit()` returns.** `submit()` throws on validation or server
  failure; dismissing unconditionally (the `try? …; dismiss()` one-liner) closes the sheet
  before `.failure`, the inline field errors, or the auto-focused invalid field can be seen.
- **Focus is the controller's, not the view's.** `.focused(on:equals:)` owns a hidden
  `@FocusState` internally — declare none. Use `.formBindFocus($focus, on: controller)` only
  when the view needs that `@FocusState` for something else (a scroll-to-error overlay); the
  two can be mixed across fields in one form.
- **Focus identifiers are value key paths** (`\.name`), never wrapper paths (`\._name`).
  Non-validated fields are valid identifiers too; only validated ones participate in
  `focusFirstInvalidField()`.
- `submit()` and `populate(from:)` are `@MainActor`; the `await` inside still frees the main
  actor, so network work does not block the UI. Forms are deliberately not `Sendable` —
  load data off-main, then `populate(from:)`.
- Submit auto-disables while `!isDirty || isLoading`; don't re-implement it.
- After a failed submit the controller focuses the first invalid field
  (`shouldFocusFirstInvalidFieldOnSubmit`, default `true`).
- iOS 17+ / `@Observable` only — no `ObservableObject` path.
