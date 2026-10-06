import Config
import SwiftUI

extension BoundsDraft {
    /// The draft's field for a `[limits]` key, one for each of ``Config/Bounds/fields``.
    static func keyPath(for key: String) -> WritableKeyPath<BoundsDraft, String>? {
        switch key {
        case "review_rounds_max": \.reviewRoundsMax
        case "attempts_per_work_card": \.attemptsPerWorkCard
        case "overdue_nights_max": \.unansweredNightsMax
        case "reselections_max": \.reselectionsMax
        case "consecutive_refusals_max": \.consecutiveRefusalsMax
        case "failed_adoptions_max": \.failedAdoptionsMax
        default: nil
        }
    }
}

/// A Project's six Bounds as the Add Project sheet draws them: grouped by consequence, each a sentence
/// around its value with a stepper, its `[limits]` key, and whether it is the default. The value stays a
/// typed field beside the stepper, so a value the loader refuses still reaches the loader and is refused in
/// its words.
struct BoundsDraftBlocks: View {
    @Binding var bounds: BoundsDraft

    var body: some View {
        ForEach(Bounds.Consequence.allCases, id: \.self) { consequence in
            WizardBlock(title: consequence.title, footer: consequence.footer) {
                let fields = Bounds.fields(consequence)
                ForEach(fields, id: \.key) { field in
                    if let keyPath = BoundsDraft.keyPath(for: field.key) {
                        row(field, text: $bounds[dynamicMember: keyPath])
                    }
                    if field.key != fields.last?.key {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func row(_ field: Bounds.Field, text: Binding<String>) -> some View {
        let value = Text(valueText(field, text.wrappedValue)).bold()
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(field.sentence.before) \(value) \(field.sentence.after)")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(field.key).font(.caption.monospaced())
                    defaultMark(field, text: text)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            BoundValueField(text: text, field: field, identifier: "bound-\(field.key)")
        }
        .padding(12)
    }

    /// The value with its unit, or what was typed when it is not a number.
    private func valueText(_ field: Bounds.Field, _ text: String) -> String {
        if let value = Int(text.trimmed) { return field.valueText(value) }
        return text.isEmpty ? "\u{2014}" : text
    }

    @ViewBuilder
    private func defaultMark(_ field: Bounds.Field, text: Binding<String>) -> some View {
        if Int(text.wrappedValue.trimmed) == field.defaultValue {
            Text("Default").font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Reset to \(field.defaultValue)") {
                text.wrappedValue = String(field.defaultValue)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

/// One Bound's value as typed, with a stepper that steps it while it is a number.
struct BoundValueField: View {
    @Binding var text: String
    let field: Bounds.Field
    let identifier: String

    var body: some View {
        HStack(spacing: 4) {
            TextField(field.key, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
                .accessibilityIdentifier(identifier)
            Stepper(field.title, value: value, in: 1...99)
                .labelsHidden()
        }
    }

    /// Steps from the typed number, or from the default while the field holds something else.
    private var value: Binding<Int> {
        Binding {
            Int(text.trimmed) ?? field.defaultValue
        } set: { newValue in
            text = String(newValue)
        }
    }
}
