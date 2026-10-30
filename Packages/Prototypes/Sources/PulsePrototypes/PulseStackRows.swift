#if DEBUG
import Domain
import Pulse
import SwiftUI

// The Unmerged Feature Stack U as the Pulse draws it (proposed spec amendment, yellowhammer-spec#132): the
// Feature group's absence wording, the "Awaiting merge" list (bottom of the stack first), and Tonight's
// stack-full line. A row only renders snapshot values and calls `PulseActions`.

/// How the Awaiting merge list is drawn. A design chooses; the shared rows read it from the environment.
enum PulseStackStyle: String, CaseIterable {
    /// One row per Feature, bottom of the stack first.
    case rows
    /// A ladder: the top of the stack at the top, a connector between rungs, the bottom rung merging first.
    case ladder
}

extension EnvironmentValues {
    @Entry var pulseStackStyle: PulseStackStyle = .rows
}

/// The wording that depends on U.
enum PulseStackText {
    /// What the Feature group says when no Feature is in flight. Never "No Feature in flight" above a landed Feature.
    /// `pull request open · 30 Oct 2026 at 02:10`, then `· latest read failed` where it did.
    static func observation(_ observation: PullRequestObservation) -> String {
        var parts = [
            "pull request \(observation.state.words)",
            observation.observedAt.formatted(date: .abbreviated, time: .shortened)
        ]
        if observation.latestReadFailed { parts.append("latest read failed") }
        return parts.joined(separator: " · ")
    }

    static func absence(_ stack: UnmergedFeatureStack) -> String {
        if stack.isEmpty { return "No Feature in flight" }
        if stack.isFull {
            return "Authoring waits for a merge — the unmerged Feature stack is full (\(fraction(stack)))"
        }
        return "The in-flight slot is free"
    }

    static func absenceImage(_ stack: UnmergedFeatureStack) -> String {
        if stack.isEmpty { return "flag.slash" }
        return stack.isFull ? "hourglass" : "flag"
    }

    /// `m of max`, or just `m` while the Bound is unknown.
    static func fraction(_ stack: UnmergedFeatureStack) -> String {
        stack.unmergedFeaturesMax.map { "\(stack.count) of \($0)" } ?? "\(stack.count)"
    }

    /// "stacked on ARC-9 in yellowhammer", one clause per repository, or nil when every base is mainline.
    static func stackedOnCaption(_ feature: FeatureInFlight) -> String? {
        guard !feature.stackedOn.isEmpty else { return nil }
        let clauses = feature.stackedOn.sorted { $0.key < $1.key }.map { "\($0.value) in \($0.key)" }
        return "stacked on " + clauses.joined(separator: ", ")
    }

    static func name(_ feature: AwaitingMergeFeature) -> String {
        feature.issueIDForDisplay ?? feature.link?.identifier ?? feature.id
    }

    /// The Feature group's one-line summary.
    static func summary(_ pulse: PulseSnapshot) -> String {
        let stack = pulse.unmergedFeatures
        guard let feature = pulse.feature else {
            if stack.isEmpty { return "No Feature in flight" }
            return stack.isFull ? "Stack full (\(fraction(stack)))" : "Slot free · \(stack.count) awaiting merge"
        }
        let line = [feature.issueIDForDisplay ?? feature.id, feature.rollupState?.rawValue]
            .compactMap { $0 }.joined(separator: " · ")
        return stack.isEmpty ? line : "\(line) · \(stack.count) awaiting merge"
    }
}

// MARK: - Awaiting merge

/// The "Awaiting merge · m of max" sub-heading and its Features. Nothing at all when U is empty.
struct PulseAwaitingMerge: View {
    let context: PulseContext
    @Environment(\.pulseStackStyle) private var style

    var body: some View {
        let stack = context.pulse.unmergedFeatures
        if !stack.isEmpty {
            Text("Awaiting merge · \(PulseStackText.fraction(stack))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            switch style {
            case .rows:
                ForEach(stack.features) { feature in
                    PulseAwaitingRow(feature: feature, context: context)
                }
            case .ladder:
                PulseStackLadder(stack: stack, context: context)
            }
        }
    }
}

/// One Feature of U: identifier, `landed tonight`, "k of N merged", and each pushed repository.
struct PulseAwaitingRow: View {
    let feature: AwaitingMergeFeature
    let context: PulseContext
    var showsStackedOn = true
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { context.actions.inspect(.feature(feature.id)) } label: {
                HStack(spacing: 6) {
                    Text(PulseStackText.name(feature)).fontWeight(.medium)
                    if feature.landedTonight { PulseBadge(text: "landed tonight", color: palette.landed) }
                    Spacer(minLength: 8)
                    Text("\(feature.mergedCount) of \(feature.pushedCount) merged")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            ForEach(feature.repositories) { repository in
                HStack(spacing: 8) {
                    Image(systemName: repository.merged ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(repository.merged ? palette.landed : .secondary)
                    Text(repository.repo).lineLimit(1).truncationMode(.middle)
                    Text(repository.merged ? "in mainline" : "not in mainline")
                        .font(.caption).foregroundStyle(.secondary)
                    if let observation = repository.pullRequestObservation {
                        PulsePullRequestObservationText(observation: observation)
                    }
                    if showsStackedOn, let base = repository.stackedOn {
                        Text("stacked on \(base)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let chip = repository.pullRequest {
                        PulsePullRequestButton(chip: chip) { context.actions.open(.pullRequest($0)) }
                    }
                }
                .font(.callout)
            }
        }
        .pulseRowHighlight(context.actions.inspected == .feature(feature.id), tint: palette.accent)
    }
}

// MARK: - Stack-full line

/// Tonight's line when author firings skipped because U was full: a quiet Night, not a failure.
struct PulseStackFullLine: View {
    let skip: StackFullSkip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(headline)
            } icon: {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            }
            Text("\(skip.features.joined(separator: ", ")) await merge. A quiet Night, not a failure.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        var line = "\(StackFullSkip.headline) (\(skip.features.count) of \(skip.unmergedFeaturesMax))"
        line += " · \(PulseFormat.time(skip.at))"
        if skip.count > 1 { line += " · \(skip.count) times" }
        return line
    }
}
#endif
