import Pulse
import SwiftUI

/// The transport under the viewer: step back or forward five minutes, or to the previous or next problem,
/// beside how many problems the Night has and the stretch it covers. The stretch is dropped when the bar has
/// no room for it. Every step stays inside the Night.
struct NightEditorTransport: View {
    let moment: NightMoment
    @Binding var playhead: Date

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showsSpan: true)
            bar(showsSpan: false)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.background.secondary)
    }

    private func bar(showsSpan: Bool) -> some View {
        HStack(spacing: 14) {
            control(
                "Previous problem", systemImage: "backward.end.fill", identifier: "night-account-previous-problem"
            ) {
                go(to: moment.previousProblem)
            }
            .disabled(moment.previousProblem == nil)
            control("Back 5 minutes", systemImage: "gobackward.5", identifier: "night-account-back-5-minutes") {
                playhead = moment.moved(by: -300)
            }
            control("Forward 5 minutes", systemImage: "goforward.5", identifier: "night-account-forward-5-minutes") {
                playhead = moment.moved(by: 300)
            }
            control("Next problem", systemImage: "forward.end.fill", identifier: "night-account-next-problem") {
                go(to: moment.nextProblem)
            }
            .disabled(moment.nextProblem == nil)
            Spacer(minLength: 8)
            Text(problemCount)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("night-account-problem-count")
            if showsSpan {
                Text(moment.timeline.scale.words)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-account-span")
            }
        }
    }

    /// An icon-only button; its title is its help and its accessibility label.
    private func control(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .font(.title3)
            .help(title)
            .accessibilityIdentifier(identifier)
    }

    private func go(to time: Date?) {
        if let time { playhead = time }
    }

    private var problemCount: String {
        switch moment.timeline.problemTimes.count {
        case 0: "No problems"
        case 1: "1 problem"
        case let count: "\(count) problems"
        }
    }
}
