import Domain
import Pulse
import SwiftUI

/// Detail pane for one selected dispatch prompt item.
struct PromptViewerDetailView: View {
    let item: DispatchPromptItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerFacts
                stateNotice
                if item.isResumed {
                    resumedNotice
                }
                contentSections
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerFacts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dispatch Information")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                if let family = item.family {
                    gridRow("Family", family.rawValue)
                }
                if let project = item.projectID {
                    gridRow("Project", project.rawValue)
                }
                gridRow("Route", item.route)
                gridRow("Dispatch time", item.time.formatted(date: .abbreviated, time: .standard))
                if let defaultVersion = item.defaultVersion {
                    gridRow("Default version", "\(defaultVersion)")
                }
                gridRow("Instructions", item.projectInstructionsDescription)
                if let nightID = item.nightID {
                    gridRow("Night", "\(nightID)")
                }
                if let feature = item.featureDisplay ?? item.featureName {
                    gridRow("Feature", feature)
                }
                if let workCard = item.workCardDisplay {
                    gridRow("Work Card", workCard)
                }
                if let attemptID = item.attemptID {
                    gridRow("Attempt", "\(attemptID)")
                }
                if let round = item.round {
                    gridRow("Round", "\(round)")
                }
                gridRow("Launch state", item.launchStateDescription)
            }
            .font(.callout)
        }
        .accessibilityIdentifier("prompts-header-facts")
    }

    private func gridRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var stateNotice: some View {
        switch item.state {
        case .recorded:
            EmptyView()
        case let .expired(dispatchedAt):
            noticeBanner(
                title: "Expired",
                message: "30 days have elapsed since dispatch "
                    + "(\(dispatchedAt.formatted(date: .abbreviated, time: .standard)))."
                    + " Stored prompt text has been cleaned up.",
                systemImage: "clock.badge.exclamationmark",
                color: .orange
            )
            .accessibilityIdentifier("prompts-state-expired")
        case let .deleted(deletedAt):
            noticeBanner(
                title: "Deleted",
                message: "This prompt record was deleted on "
                    + "\(deletedAt.formatted(date: .abbreviated, time: .standard)).",
                systemImage: "trash",
                color: .red
            )
            .accessibilityIdentifier("prompts-state-deleted")
        case let .unavailable(cause):
            noticeBanner(
                title: "Unavailable",
                message: "Prompt text is unavailable\(cause.map { ": \($0)" } ?? ".").",
                systemImage: "exclamationmark.triangle",
                color: .secondary
            )
            .accessibilityIdentifier("prompts-state-unavailable")
        case let .rehearsal(fixture):
            noticeBanner(
                title: "Rehearsal Pass",
                message: "Answered from fixture \u{201C}\(fixture)\u{201D}. No agent CLI was dispatched.",
                systemImage: "theatermasks",
                color: .purple
            )
            .accessibilityIdentifier("prompts-state-rehearsal")
        }
    }

    private var resumedNotice: some View {
        noticeBanner(
            title: "Resumed Session",
            message: DispatchPromptItem.resumedSessionNotice,
            systemImage: "arrow.triangle.2.circlepath",
            color: .blue
        )
        .accessibilityIdentifier("prompts-resumed-notice")
    }

    private func noticeBanner(title: String, message: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private var contentSections: some View {
        if let instruction = item.instruction {
            textSection(title: "Instruction", text: instruction, id: "prompts-instruction-text")
        }
        if let schema = item.outputSchema {
            textSection(title: "Output Schema", text: schema, id: "prompts-schema-text")
        }
    }

    private func textSection(title: String, text: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 140, maxHeight: 340)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
            .accessibilityIdentifier(id)
        }
    }
}
