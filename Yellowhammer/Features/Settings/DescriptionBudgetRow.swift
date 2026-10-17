import Domain
import SwiftUI

/// The description budget part of a Linear workspace card: the budget in force (marked when it is the
/// default), a field to change it and Save. `yh` validates the value; a refusal is shown in its own words.
/// Every identifier is `settings-linear-budget-<kind>-<name>` on a leaf element, so no container swallows one.
struct DescriptionBudgetRow: View {
    @Bindable var model: DescriptionBudgetModel
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(valueText)
                .accessibilityIdentifier("settings-linear-budget-\(name)")
            HStack(spacing: 8) {
                TextField("Description budget", text: $model.draft)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 90)
                    .onSubmit { save() }
                    .accessibilityIdentifier("settings-linear-budget-field-\(name)")
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty || model.isSaving)
                    .accessibilityIdentifier("settings-linear-budget-revert-\(name)")
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty || model.parsedDraft == nil || model.isSaving)
                    .accessibilityIdentifier("settings-linear-budget-save-\(name)")
            }
            Text("Lowering it changes no card already written until that card\u{2019}s next rewrite.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = model.failure {
                SettingsFailureText(text: failure, identifier: "settings-linear-budget-error-\(name)")
            }
        }
    }

    private var valueText: String {
        let value = DescriptionBudgetOverrun.grouped(model.effective)
        return model.configured == nil ? "\(value) (default)" : value
    }

    private func save() {
        guard model.isDirty, model.parsedDraft != nil, !model.isSaving else { return }
        Task { await model.save() }
    }
}
