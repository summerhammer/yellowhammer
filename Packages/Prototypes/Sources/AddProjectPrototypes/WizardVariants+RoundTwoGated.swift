#if DEBUG
import SwiftUI

// MARK: - Name First

/// The id is settled before anything else: the sheet opens on one focused page that names the Project
/// and locks its id in with an explicit button. Only then does the hub appear, carrying the locked id
/// in its header. Linear is one list; the spec source is option cards; Bounds read as sentences.
struct NameFirstWizard: View {
    @Binding var draft: AddProjectDraft
    @Environment(\.addProjectAction) private var action

    private let components = WizardComponents(
        identity: .hidden, linear: .unifiedList, spec: .optionCards, bounds: .sentences
    )

    var body: some View {
        if draft.idConfirmed || draft.run != .notStarted {
            hub
        } else {
            gate
        }
    }

    private var idIsUsable: Bool {
        !draft.projectID.isEmpty && !draft.problems(in: .project).contains { $0.contains("id") }
    }

    private var gate: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Cancel") { action("Cancel — leaves nothing behind") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Spacer()
            VStack(spacing: 18) {
                Text("Add Project").font(.largeTitle.weight(.bold))
                IdentityBlock(draft: $draft, style: .nameFirst)
                WizardBlock(title: "The id names") { IdNamesList(id: draft.projectID) }
                    .frame(maxWidth: 480)
                Button {
                    draft.idConfirmed = true
                    draft.go(to: .project)
                } label: {
                    Label(
                        "Lock In \u{201c}\(draft.projectID.isEmpty ? "id" : draft.projectID)\u{201d}",
                        systemImage: "lock.fill"
                    )
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!idIsUsable)
                Text("You can rename the Project later. The id stays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func sidebarTitle(_ step: WizardStep) -> String {
        step == .project ? "Linear project" : step.shortTitle // glossary:ignore GL001
    }

    private var hub: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.displayName).font(.title3.weight(.semibold))
                        HStack(spacing: 6) {
                            IdToken(id: draft.projectID)
                            Button("Change") { draft.idConfirmed = false }
                                .buttonStyle(.link)
                                .font(.caption)
                                .disabled(draft.run != .notStarted)
                        }
                    }
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
                    WizardStepSidebar(draft: $draft, title: sidebarTitle)
                }
                .frame(width: 240)
                .background(WizardTheme.surface)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if draft.run == .notStarted {
                        if draft.step == .project {
                            WizardColumn {
                                Text("Where this Project\u{2019}s Features come from.")
                                    .font(.title2.weight(.semibold))
                                LinearBlock(draft: $draft, style: components.linear)
                            }
                        } else {
                            StepHeading(step: draft.step).padding([.horizontal, .top], 20)
                            WizardStepBody(step: draft.step, draft: $draft, components: components)
                        }
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

// MARK: - Overview and Edit

/// The sheet opens on the whole Project at a glance — name and locked id on top, then one row per step
/// with its summary and status — and each row opens that step as a focused page with a way back.
/// Progress is the overview itself.
struct OverviewEditWizard: View {
    @Binding var draft: AddProjectDraft
    @State private var editing: WizardStep?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if draft.run != .notStarted {
                    WizardRunView(draft: draft)
                } else if let editing {
                    page(editing).transition(.move(edge: .trailing))
                } else {
                    overview.transition(.move(edge: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.snappy, value: editing)
            Divider()
            if editing == nil || draft.run != .notStarted {
                WizardHubFooter(draft: $draft)
            } else {
                HStack {
                    Spacer()
                    Button("Done") { editing = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
        }
    }

    private var overview: some View {
        WizardColumn(maxWidth: 560) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Project").font(.title2.weight(.bold))
                HStack(spacing: 8) {
                    Text(draft.displayName.isEmpty ? "Unnamed Project" : draft.displayName)
                        .font(.title3)
                        .foregroundStyle(draft.displayName.isEmpty ? .secondary : .primary)
                    IdToken(id: draft.projectID)
                    PermanentBadge()
                }
            }
            WizardBlock {
                ForEach(WizardStep.allCases) { step in
                    Button {
                        draft.go(to: step, allowingAhead: true)
                        editing = step
                    } label: {
                        overviewRow(step)
                    }
                    .buttonStyle(.plain)
                    if step != WizardStep.allCases.last { Divider().padding(.leading, 12) }
                }
            }
        }
    }

    private func overviewRow(_ step: WizardStep) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).fontWeight(.medium)
                Text(draft.summary(of: step)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if draft.hubStatus(of: step) == .problem, let problem = draft.problems(in: step).first {
                    Text(problem).font(.caption).foregroundStyle(WizardTheme.error).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if draft.isComplete(step) {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(WizardTheme.success)
            }
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .contentShape(.rect)
    }

    private func page(_ step: WizardStep) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button("All Steps", systemImage: "chevron.left") { editing = nil }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding([.horizontal, .top], 14)
            StepHeading(step: step, large: true)
            WizardStepBody(step: step, draft: $draft, maxWidth: 540)
        }
    }
}
#endif
