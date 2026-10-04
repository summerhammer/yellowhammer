#if DEBUG
import SwiftUI

// The round-three variants' small parts: the sidebar row's marks, the three problem placements, the
// empty Repo list, and the Next card.

/// Hub4's sidebar row, with a trailing tag as well as a tick or a problem count.
struct VariantSidebarRow: View {
    enum Mark: Equatable {
        case none
        case done
        case problems(Int)
        /// A word in place of a tick: "Optional", "Default", "Changed".
        case tag(String)
    }

    let title: String
    let summary: String
    let mark: Mark

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            switch mark {
            case .none:
                EmptyView()
            case .done:
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(WizardTheme.success)
                    .accessibilityLabel("Done")
            case .problems(let count):
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WizardTheme.onColor)
                    .padding(.horizontal, 6)
                    .background(WizardTheme.error, in: .capsule)
                    .accessibilityLabel("\(count) problems")
            case .tag(let word):
                Text(word).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The sidebar's header: "Add Project", or the Project's name and id, over the readiness in words.
struct VariantSidebarHeader: View {
    let draft: AddProjectDraft
    let design: HubDesign

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if design.context == .sidebarHeader {
                Text("Adding").font(.caption).foregroundStyle(.secondary)
                Text(draft.contextTitle).font(.title3.weight(.semibold)).lineLimit(1)
                if !draft.projectID.isEmpty {
                    Text(draft.projectID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                Text("Add Project").font(.title3.weight(.semibold))
            }
            Text(readiness)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, design.context == .sidebarHeader ? 4 : 0)
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 8)
    }

    /// Optional pages count only under Hub4's ticks; otherwise readiness is the required pages'.
    private var readiness: String {
        if design.optionalMark == .tick {
            return "\(VariantPage.allCases.count(where: draft.isPageComplete)) of \(VariantPage.allCases.count) ready"
        }
        let required = VariantPage.allCases.filter { !$0.isOptional }
        return "\(required.count(where: draft.isPageComplete)) of \(required.count) required ready"
    }
}

/// Problems under the page heading, in a tinted strip.
struct ProblemBanner: View {
    let problems: [String]

    var body: some View {
        WizardProblemList(problems: problems)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WizardTheme.error.opacity(0.08), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WizardTheme.error.opacity(0.25)))
    }
}

/// Problems after the page's content, as a titled block.
struct ProblemBox: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To finish this page").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            WizardProblemList(problems: problems)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WizardTheme.surface, in: .rect(cornerRadius: 10))
        }
    }
}

/// One problem as a caption beside the part it is about.
struct FieldProblem: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(WizardTheme.error)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Repo page before any Repo is added: a placeholder that is also the way to add one, so an empty
/// page is never blank.
struct EmptyRepoList: View {
    /// Draws the page's problem inside the placeholder, for the beside-the-field placement.
    let showsProblem: Bool
    let addRepo: () -> Void

    var body: some View {
        let tint = showsProblem ? WizardTheme.error : WizardTheme.neutral
        VStack(spacing: 8) {
            Text("No Repos yet").font(.headline)
            Text("Add the working Repos this Project builds in.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if showsProblem {
                FieldProblem(text: "Add at least one working Repo.")
            }
            Button("Add Repo\u{2026}", systemImage: "plus", action: addRepo).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(tint.opacity(0.05), in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
    }
}

/// A title bar across the sheet: "Add Project — Acme", with the id once there is one.
struct ProjectTitleBar: View {
    let draft: AddProjectDraft

    var body: some View {
        HStack(spacing: 8) {
            Text("Add Project").foregroundStyle(.secondary)
            Text("\u{2014}").foregroundStyle(.tertiary)
            Text(draft.contextTitle).fontWeight(.semibold)
            if !draft.projectID.isEmpty {
                IdToken(id: draft.projectID, locked: false).font(.caption)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The Project being added, as a chip beside the footer's Cancel.
struct ProjectChip: View {
    let draft: AddProjectDraft

    var body: some View {
        HStack(spacing: 6) {
            Text(draft.contextTitle).fontWeight(.medium)
            if !draft.projectID.isEmpty {
                Text(draft.projectID).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(WizardTheme.surface, in: .capsule)
    }
}

/// The way on from a complete page, at its end.
struct NextCard: View {
    let page: VariantPage
    /// Return presses the card until every page is ready; then Return is Add Project's.
    var isDefault = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next: \(page.title)").font(.headline)
                    Text(page.explanation).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.headline).foregroundStyle(WizardTheme.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WizardTheme.accent.opacity(0.07), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WizardTheme.accent.opacity(0.4)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}
#endif
