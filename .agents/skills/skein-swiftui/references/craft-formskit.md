# FormsKit (Forms)

**Mandatory.** Every form with validation or submission uses
[FormsKit](https://github.com/rozd/forms-kit). Do not hand-roll validation. Companion to
**view/forms** (the `Form` structure FormsKit fills) and **state/primitives** (the
wrappers a controller is held in).

## Rules

- **Never** write per-field `@State var emailError: String?`, an `isValid` computed
  property over raw `@State`, an `ObservableObject` form view model, or ad-hoc regex
  checks in a view body.
- A form is a **struct** of `@Validated` fields conforming to `ValidatableForm` (+
  `SubmittableForm` / `PopulatableForm`), owned by a `FormController` held as `@State`.
- Field state is read from the projected value (`controller.form.$email`) and rendered
  by `.formValidationError(for:)` — never by hand-built error `Text`.
- Focus is key-path driven through the controller. **Never** declare a bespoke
  `@FocusState` enum.
- Server-side field errors are returned by throwing `ValidationError.invalid(errors:)`
  from `submit()`; do not map them onto fields manually.
- `submit()` and `populate(from:)` are `@MainActor` by protocol requirement. Forms are
  deliberately not `Sendable` — do not add conformance; load data off-MainActor as a
  `Sendable` carrier and `populate(from:)` on MainActor.

## The shape

```swift
struct CreatePlanForm: ValidatableForm, SubmittableForm {
    @Validated(name: "name", .isNotEmpty(message: "Name is required"), .minLength(3))
    var name: String = ""

    @Validated(name: "email", .email())
    var ownerEmail: String = ""

    // Value key path first; `wrappedBy:` carries the wrapper key path.
    var validatedFields: [ValidatedField<Self>] {
        [.init(\.name, wrappedBy: \._name),
         .init(\.ownerEmail, wrappedBy: \._ownerEmail)]
    }

    @MainActor func submit() async throws -> Plan {
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

## Validation

- Modes: `.onChange` (default — quiet until first invalid, then re-validates per
  keystroke), `.always`, `.onSubmit`.
- Built-in string rules: `isNotEmpty`, `minLength`, `maxLength`, `pattern`, `email`.
  `@Validated` works on any `Equatable`, not just `String`.
- Custom rules conform to `ValidationRule` (return `nil` when valid) plus a static
  factory for call-site syntax — do not inline closures in views.

```swift
struct DivisibleBy: ValidationRule {
    let divisor: Int; let message: String
    func validate(value: Int) -> String? { value % divisor == 0 ? nil : message }
}
extension ValidationRule where Self == DivisibleBy {
    static func divisibleBy(_ n: Int, message: String) -> DivisibleBy { .init(divisor: n, message: message) }
}
```

## Controller

`controller.state` runs `.initial → .loading → .success / .failure(Error)`. Also:
`form`, `focus`, `isDirty`, `isValid`, `isLoading`, `validate()`,
`focusFirstInvalidField()`, `shouldFocusFirstInvalidFieldOnSubmit` (default `true` —
auto-focuses the first invalid field after a failed submit).

`submit()` throws when validation or the server rejects the form, so gate dismissal on it
returning — never `try? await controller.submit(); dismiss()`, which tears the form down
before `.failure`, the inline errors, and the auto-focus can be seen.

## Modifiers

| Modifier | Use |
| --- | --- |
| `.formValidationError(for:)` | Inline field errors; optional `alignment:`/`spacing:`. |
| `.formToolbar(controller:onSubmit:)` | Cancel/Submit toolbar; Submit disabled when `!isDirty \|\| isLoading`; discard confirmation + `interactiveDismissDisabled` when dirty. |
| `.focused(on:equals:)` | Default focus binding — owns its `@FocusState` internally. Use value key paths (`\.name`), not `\._name`. |
| `.formBindFocus(_:on:)` | Only when the view needs its own `@FocusState` for something else. |
