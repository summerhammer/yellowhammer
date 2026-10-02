#if DEBUG
import SwiftUI

// The variants that walk the five steps in order with Back and Continue. They differ in how the
// steps are shown: a numbered list, an Installer-style pane, a stepper bar, or one question per page.

// MARK: - Wireframe

/// The attached wireframe, as drawn: a numbered step list on the left, the step on the right.
struct WireframeWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Add Project").font(.title2.weight(.bold))
                Text("step \(draft.step.number) of \(WizardStep.allCases.count)").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(WizardStep.allCases) { step in
                        stepRow(step)
                        Divider()
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 220)
                Divider()
                Group {
                    if draft.run == .notStarted {
                        WizardStepContent(step: draft.step, draft: $draft)
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func stepRow(_ step: WizardStep) -> some View {
        let isCurrent = step == draft.step
        return Button {
            draft.go(to: step)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(step.number).").monospacedDigit()
                Text(step.qualifier.map { "\(step.title) (\($0))" } ?? step.title)
                Spacer(minLength: 0)
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(step <= draft.reached ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? WizardTheme.surface : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(step > draft.reached || draft.run != .notStarted)
    }
}

// MARK: - Assistant

/// macOS Installer: a tinted pane with the sheet's identity and each step's status, the step's title
/// and a sentence of explanation over the fields. Repos as an editable table; Bounds as a key grid.
struct AssistantWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidePane.frame(width: 220)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if draft.run == .notStarted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.step.title).font(.title2.weight(.semibold))
                            Text(draft.step.explanation).foregroundStyle(.secondary)
                        }
                        .padding([.horizontal, .top], 20)
                        WizardStepContent(step: draft.step, draft: $draft, repoStyle: .table, boundsStyle: .grid)
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                // A minimum of zero, so the table's ideal width never pushes the sheet wider.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack {
                WizardCancelButton(caption: false)
                Spacer()
                WizardNavigationButtons(draft: $draft)
            }
            .padding(16)
        }
    }

    private var sidePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "plus.rectangle.on.folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(WizardTheme.accent)
                Text("Add Project").font(.title3.weight(.semibold))
                if !draft.projectID.isEmpty {
                    Text(draft.displayName).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(WizardStep.allCases) { step in
                    Button {
                        draft.go(to: step)
                    } label: {
                        HStack(spacing: 8) {
                            WizardStatusIcon(status: draft.run == .succeeded ? .done : draft.status(of: step))
                            Text(step.shortTitle)
                                .fontWeight(step == draft.step ? .semibold : .regular)
                                .foregroundStyle(step <= draft.reached ? .primary : .secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(step > draft.reached || draft.run != .notStarted)
                }
                HStack(spacing: 8) {
                    WizardStatusIcon(status: runStatus)
                    Text("Add").foregroundStyle(draft.run == .notStarted ? .secondary : .primary)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [WizardTheme.accent.opacity(0.32), WizardTheme.accent.opacity(0.08)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var runStatus: WizardStepStatus {
        switch draft.run {
        case .notStarted: .upcoming
        case .running: .current
        case .succeeded: .done
        case .failed: .problem
        }
    }
}

// MARK: - Top Stepper

/// A numbered stepper bar across the top, each segment ticked when its step is complete; the step's
/// fields below in a single column. Repos as cards.
struct StepperWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Text("Add Project").font(.headline)
                stepper
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            Divider()
            Group {
                if draft.run == .notStarted {
                    WizardStepContent(step: draft.step, draft: $draft, repoStyle: .cards)
                } else {
                    WizardRunView(draft: draft)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                WizardCancelButton()
                Spacer()
                WizardNavigationButtons(draft: $draft)
            }
            .padding(16)
        }
    }

    private var stepper: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(WizardStep.allCases) { step in
                if step != WizardStep.allCases.first {
                    Capsule()
                        .fill(step <= draft.reached ? WizardTheme.accent : WizardTheme.neutral.opacity(0.35))
                        .frame(height: 2)
                        .padding(.top, 13)
                }
                Button {
                    draft.go(to: step)
                } label: {
                    VStack(spacing: 6) {
                        node(for: step)
                        Text(step.shortTitle)
                            .font(.caption)
                            .fontWeight(step == draft.step ? .semibold : .regular)
                            .foregroundStyle(step == draft.step ? .primary : .secondary)
                            .fixedSize()
                    }
                    .frame(width: 72)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(step > draft.reached || draft.run != .notStarted)
            }
        }
    }

    @ViewBuilder
    private func node(for step: WizardStep) -> some View {
        let status = draft.run == .succeeded ? .done : draft.status(of: step)
        ZStack {
            switch status {
            case .done:
                Circle().fill(WizardTheme.success)
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(WizardTheme.onColor)
            case .problem:
                Circle().fill(WizardTheme.error)
                Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(WizardTheme.onColor)
            case .current:
                Circle().fill(WizardTheme.accent)
                Text("\(step.number)").font(.callout.weight(.semibold)).foregroundStyle(WizardTheme.onColor)
            case .upcoming:
                Circle().strokeBorder(WizardTheme.neutral.opacity(0.5), lineWidth: 1.5)
                Text("\(step.number)").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Focus

/// One question per page, like Setup Assistant: a large title and a sentence centred over a narrow
/// column, page dots and a large Continue at the bottom, Back as a chevron. Repos as cards.
struct FocusWizard: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", systemImage: "chevron.left") { draft.goBack() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .opacity(draft.isFirstStep || draft.run != .notStarted ? 0 : 1)
                    .disabled(draft.isFirstStep || draft.run != .notStarted)
                Spacer()
                if draft.run == .notStarted {
                    Button("Cancel") { action("Cancel — leaves nothing behind") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(14)
            if draft.run == .notStarted {
                VStack(spacing: 10) {
                    Image(systemName: draft.step.systemImage)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(WizardTheme.onColor)
                        .frame(width: 52, height: 52)
                        .background(WizardTheme.accent, in: .rect(cornerRadius: 12))
                    Text(draft.step.title).font(.largeTitle.weight(.bold))
                    Text(draft.step.explanation)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                }
                WizardStepContent(step: draft.step, draft: $draft, repoStyle: .cards)
                    .frame(maxWidth: 520, maxHeight: .infinity)
            } else {
                WizardRunView(draft: draft).frame(maxWidth: 560)
            }
            VStack(spacing: 14) {
                if draft.run == .notStarted {
                    Button {
                        draft.goForward()
                    } label: {
                        Text(draft.continueTitle).frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canContinue)
                } else {
                    HStack { WizardNavigationButtons(draft: $draft) }.controlSize(.large)
                }
                pageDots
            }
            .padding(.bottom, 18)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(WizardStep.allCases) { step in
                Capsule()
                    .fill(step == draft.step ? WizardTheme.accent : WizardTheme.neutral.opacity(0.4))
                    .frame(width: step == draft.step ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: draft.step)
        .accessibilityElement()
        .accessibilityLabel("Step \(draft.step.number) of \(WizardStep.allCases.count)")
    }
}
#endif
