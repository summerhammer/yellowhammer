#if DEBUG
import SwiftUI

// Round two, from the round-one feedback: keep the Checklist's hub (move to any step, see what is
// done), the Focus layout and the Repo cards; drop sidebar icons, the progress bar, Repo rows and
// tables, the web-style stepper and the accordion. Each variant also tries a different answer to the
// four open questions — see `WizardComponents`.

/// A step's heading: its title and the sentence that says what it decides.
struct StepHeading: View {
    let step: WizardStep
    var large = false

    var body: some View {
        VStack(alignment: large ? .center : .leading, spacing: 6) {
            Text(step.title).font(large ? .largeTitle.weight(.bold) : .title2.weight(.semibold))
            Text(step.explanation)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(large ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: large ? 480 : .infinity, alignment: large ? .center : .leading)
    }
}

extension AddProjectDraft {
    /// The next step in order, for a hub's Continue.
    var nextStep: WizardStep? { WizardStep(rawValue: step.rawValue + 1) }

    var readyCount: Int { WizardStep.allCases.count(where: isComplete) }
}

// MARK: - Hub

/// The Checklist kept, without its distractions: a plain step list (a title, the step's summary, a tick
/// or a problem count), progress in words, and a roomier detail. The id is a locked token with what it
/// names; Linear and the spec source are option cards; Bounds are explained, grouped by consequence.
struct HubWizard: View {
    @Binding var draft: AddProjectDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Project").font(.title3.weight(.semibold))
                        Text("\(draft.readyCount) of \(WizardStep.allCases.count) ready")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
                    WizardStepSidebar(draft: $draft)
                }
                .frame(width: 240)
                .background(WizardTheme.surface)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if draft.run == .notStarted {
                        StepHeading(step: draft.step).padding([.horizontal, .top], 20)
                        WizardStepBody(step: draft.step, draft: $draft)
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            WizardHubFooter(draft: $draft)
        }
    }
}

// MARK: - Focused Hub

/// The hub's step list beside the Focus layout: a large centred title and a narrow column, with a
/// large Continue that walks the steps in order while the list lets the Operator jump. The id is
/// confirmed in a dialog before leaving the first step; Linear and the spec source are single lists of
/// every candidate; Bounds read as sentences.
struct FocusedHubWizard: View {
    @Binding var draft: AddProjectDraft
    @State private var pendingStep: WizardStep?
    @State private var confirmsBeforeAdding = false

    private let components = WizardComponents(
        identity: .confirmable, linear: .unifiedList, spec: .candidateList, bounds: .sentences
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Project").font(.title3.weight(.semibold))
                        Text(draft.displayName.isEmpty ? "New Project" : draft.displayName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
                    WizardStepSidebar(draft: $draft, onSelect: leave(to:))
                }
                .frame(width: 220)
                .background(WizardTheme.surface)
                Divider()
                VStack(spacing: 14) {
                    if draft.run == .notStarted {
                        StepHeading(step: draft.step, large: true).padding(.top, 24)
                        WizardStepBody(step: draft.step, draft: $draft, components: components, maxWidth: 520)
                        if let next = draft.nextStep {
                            Button {
                                leave(to: next)
                            } label: {
                                Text("Continue to \(next.shortTitle)").frame(minWidth: 220)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.bottom, 16)
                        }
                    } else {
                        WizardRunView(draft: draft)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            WizardHubFooter(draft: $draft) { addProject() }
        }
        .alert(confirmTitle, isPresented: isConfirming) {
            Button("Use \u{201c}\(draft.projectID)\u{201d}") { confirm() }
            Button("Edit Id", role: .cancel) { cancelConfirm() }
        } message: {
            Text("The id names the Project file, its Journal and its three LaunchAgents. "
                + "It can\u{2019}t be changed after the Project is added.")
        }
    }

    private var confirmTitle: String { "Use \u{201c}\(draft.projectID)\u{201d} as the Project id?" }

    /// Leaving the first step with a valid, unconfirmed id asks first; everything else just moves.
    private func leave(to target: WizardStep) {
        if draft.step == .project, target != .project, !draft.idConfirmed, needsConfirmation {
            pendingStep = target
        } else {
            draft.go(to: target, allowingAhead: true)
        }
    }

    private var needsConfirmation: Bool {
        !draft.projectID.isEmpty && !draft.problems(in: .project).contains { $0.contains("id") }
    }

    private func addProject() {
        if draft.idConfirmed { draft.runSetup() } else { confirmsBeforeAdding = true }
    }

    private var isConfirming: Binding<Bool> {
        // Dismissing only clears the request; each button has already done its own work.
        Binding { pendingStep != nil || confirmsBeforeAdding } set: { isPresented in
            if !isPresented {
                pendingStep = nil
                confirmsBeforeAdding = false
            }
        }
    }

    private func confirm() {
        draft.idConfirmed = true
        if let pendingStep { draft.go(to: pendingStep, allowingAhead: true) }
        if confirmsBeforeAdding { draft.runSetup() }
        pendingStep = nil
        confirmsBeforeAdding = false
    }

    /// Stays on the first step, with the id still editable.
    private func cancelConfirm() {
        pendingStep = nil
        confirmsBeforeAdding = false
    }
}

// MARK: - Focus Pages

/// Focus kept whole — one step per page, a large title, a narrow column — made navigable: the title
/// bar's step menu jumps anywhere and marks what is done, and the page dots are coloured by status and
/// clickable. The first page leads with a large name; the id follows it as a locked token.
struct FocusPagesWizard: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    private let components = WizardComponents(identity: .nameFirst)

    var body: some View {
        VStack(spacing: 0) {
            titleBar.padding(14)
            if draft.run == .notStarted {
                StepHeading(step: draft.step, large: true)
                WizardStepBody(step: draft.step, draft: $draft, components: components, maxWidth: 540)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 12) {
                    Button {
                        draft.goForward()
                    } label: {
                        Text(draft.continueTitle).frame(minWidth: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canContinue)
                    if let stillNeeded = draft.stillNeeded, draft.isLastStep {
                        Text(stillNeeded).font(.caption).foregroundStyle(.secondary)
                    }
                    statusDots
                }
                .padding(.vertical, 16)
            } else {
                WizardRunView(draft: draft).frame(maxWidth: 560)
                HStack { WizardNavigationButtons(draft: $draft) }.controlSize(.large).padding(.bottom, 18)
            }
        }
    }

    private var titleBar: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") { draft.goBack() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(draft.isFirstStep || draft.run != .notStarted)
            Spacer()
            Menu {
                ForEach(WizardStep.allCases) { step in
                    Button {
                        draft.go(to: step, allowingAhead: true)
                    } label: {
                        switch draft.hubStatus(of: step) {
                        case .done: Label(step.title, systemImage: "checkmark")
                        case .problem: Label(step.title, systemImage: "exclamationmark.triangle")
                        case .current, .upcoming: Text(step.title)
                        }
                    }
                }
            } label: {
                Text("\(draft.step.number) of \(WizardStep.allCases.count) · \(draft.step.shortTitle)")
                    .monospacedDigit()
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(draft.run != .notStarted)
            Spacer()
            Button("Cancel") { action("Cancel — leaves nothing behind") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .disabled(draft.run != .notStarted)
        }
    }

    private var statusDots: some View {
        HStack(spacing: 8) {
            ForEach(WizardStep.allCases) { step in
                Button {
                    draft.go(to: step, allowingAhead: true)
                } label: {
                    Capsule()
                        .fill(dotColor(step))
                        .frame(width: step == draft.step ? 20 : 8, height: 8)
                        .contentShape(.rect.inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(step.title)
                .accessibilityLabel("\(step.title), \(String(describing: draft.hubStatus(of: step)))")
            }
        }
        .animation(.snappy, value: draft.step)
    }

    private func dotColor(_ step: WizardStep) -> Color {
        if step == draft.step { return WizardTheme.accent }
        return switch draft.hubStatus(of: step) {
        case .done: WizardTheme.success
        case .problem: WizardTheme.error
        case .current, .upcoming: WizardTheme.neutral.opacity(0.4)
        }
    }
}
#endif
