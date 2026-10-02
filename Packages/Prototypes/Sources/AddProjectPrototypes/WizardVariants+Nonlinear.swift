#if DEBUG
import SwiftUI

// The variants that show every step at once, so the Operator sees the whole Project before adding it:
// an accordion, tabs beside the Project file it will write, and a checklist hub.

// MARK: - Accordion

/// Every step on one sheet. Steps not being edited fold to a row with their summary and an Edit
/// button; the open step fills the space between them.
struct AccordionWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add Project").font(.title2.weight(.bold))
                Spacer()
                Text("\(WizardStep.allCases.count(where: draft.isComplete)) of \(WizardStep.allCases.count) ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            if draft.run == .notStarted {
                VStack(spacing: 8) {
                    ForEach(WizardStep.allCases) { step in
                        if step == draft.step {
                            openCard(step)
                        } else {
                            foldedRow(step)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            } else {
                WizardRunView(draft: draft)
            }
            Divider()
            HStack {
                WizardCancelButton()
                Spacer()
                WizardNavigationButtons(draft: $draft)
            }
            .padding(16)
        }
    }

    private func foldedRow(_ step: WizardStep) -> some View {
        let status = draft.status(of: step)
        return HStack(spacing: 10) {
            numberBadge(step, status: status)
            Text(step.title).fontWeight(.medium)
            Spacer()
            if step <= draft.reached {
                Text(draft.summary(of: step))
                    .font(.callout)
                    .foregroundStyle(status == .problem ? AnyShapeStyle(WizardTheme.error) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Button("Edit") { draft.go(to: step) }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
        .foregroundStyle(step <= draft.reached ? .primary : .secondary)
    }

    private func openCard(_ step: WizardStep) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                numberBadge(step, status: .current)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline)
                    Text(step.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            WizardStepContent(step: step, draft: $draft)
                .scrollContentBackground(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(WizardTheme.accent.opacity(0.07), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WizardTheme.accent.opacity(0.22)))
    }

    private func numberBadge(_ step: WizardStep, status: WizardStepStatus) -> some View {
        ZStack {
            Circle().fill(status == .upcoming ? WizardTheme.neutral.opacity(0.25) : status.color)
            if status == .done {
                Image(systemName: "checkmark").font(.caption2.weight(.bold))
            } else if status == .problem {
                Image(systemName: "exclamationmark").font(.caption2.weight(.bold))
            } else {
                Text("\(step.number)").font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(status == .upcoming ? AnyShapeStyle(.secondary) : AnyShapeStyle(WizardTheme.onColor))
        .frame(width: 22, height: 22)
    }
}

// MARK: - Live Preview

/// Tabs instead of Back and Continue, in any order, beside the Project file `yh setup --init` will
/// write, updated as the Operator types, with everything that still blocks it listed underneath.
struct LivePreviewWizard: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Project").font(.title3.weight(.semibold))
                Spacer()
                Picker("Step", selection: stepBinding) {
                    ForEach(WizardStep.allCases) { step in
                        // A segmented control drops label icons, so completion rides in the text.
                        Text(draft.isComplete(step) ? "\(step.shortTitle) \u{2713}" : step.shortTitle).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(draft.run != .notStarted)
                Spacer()
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                Group {
                    if draft.run == .notStarted {
                        WizardStepContent(step: draft.step, draft: $draft, repoStyle: .table, boundsStyle: .grid)
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                preview.frame(width: 340)
            }
            Divider()
            HStack {
                if draft.run == .notStarted {
                    WizardCancelButton()
                    Spacer()
                    Button("Add Project") { draft.runSetup() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isComplete)
                } else {
                    Spacer()
                    WizardNavigationButtons(draft: $draft)
                }
            }
            .padding(16)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(draft.projectID.isEmpty ? "<id>" : draft.projectID).toml", systemImage: "doc.plaintext")
                .font(.headline)
            ScrollView {
                Text(draft.projectFilePreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(WizardTheme.surface, in: .rect(cornerRadius: 8))
            let blocking = WizardStep.allCases.flatMap { step in draft.problems(in: step).map { (step, $0) } }
            if blocking.isEmpty {
                Label("Ready to write", systemImage: "checkmark.circle.fill").foregroundStyle(WizardTheme.success)
            } else {
                Text("Before it can be written").font(.subheadline.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(blocking, id: \.1) { step, problem in
                            Button {
                                draft.go(to: step, allowingAhead: true)
                            } label: {
                                Label {
                                    Text(problem).multilineTextAlignment(.leading)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(WizardTheme.error)
                                }
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var stepBinding: Binding<WizardStep> {
        Binding { draft.step } set: { draft.go(to: $0, allowingAhead: true) }
    }
}

// MARK: - Checklist

/// A hub, not a sequence: the five steps as a list of tasks, each with its tile, status and summary;
/// the selected task's fields beside it. Add Project lights up once every task is ready.
struct ChecklistWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Add Project")
                        .font(.title3.weight(.semibold))
                        .padding([.horizontal, .top], 16)
                        .padding(.bottom, 8)
                    List(selection: selection) {
                        ForEach(WizardStep.allCases) { step in
                            row(step).tag(step)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .disabled(draft.run != .notStarted)
                }
                .frame(width: 270)
                .background(WizardTheme.surface)
                Divider()
                Group {
                    if draft.run == .notStarted {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(draft.step.explanation)
                                .foregroundStyle(.secondary)
                                .padding([.horizontal, .top], 20)
                            WizardStepContent(step: draft.step, draft: $draft)
                        }
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                if draft.run == .notStarted {
                    WizardCancelButton()
                    Spacer()
                    ProgressView(
                        value: Double(WizardStep.allCases.count(where: draft.isComplete)),
                        total: Double(WizardStep.allCases.count)
                    )
                    .frame(width: 90)
                    .tint(WizardTheme.success)
                    Button("Add Project") { draft.runSetup() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isComplete)
                } else {
                    Spacer()
                    WizardNavigationButtons(draft: $draft)
                }
            }
            .padding(16)
        }
    }

    private func row(_ step: WizardStep) -> some View {
        let isComplete = draft.isComplete(step)
        let hasProblem = step <= draft.reached && !isComplete
        let tint = isComplete ? WizardTheme.success : hasProblem ? WizardTheme.error : WizardTheme.neutral
        return HStack(spacing: 10) {
            Image(systemName: step.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(WizardTheme.onColor)
                .frame(width: 26, height: 26)
                .background(tint, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.shortTitle).font(.headline)
                Text(draft.summary(of: step))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isComplete {
                Image(systemName: "checkmark").foregroundStyle(WizardTheme.success)
            } else if hasProblem {
                Text("\(draft.problems(in: step).count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WizardTheme.onColor)
                    .padding(.horizontal, 6)
                    .background(WizardTheme.error, in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }

    private var selection: Binding<WizardStep?> {
        Binding { draft.step } set: { if let step = $0 { draft.go(to: step, allowingAhead: true) } }
    }
}
#endif
