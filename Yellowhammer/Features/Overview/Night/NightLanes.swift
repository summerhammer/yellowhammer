import Pulse
import SwiftUI

/// The Night's tracks: one for each Act, and one for unstamped events when there are any, laid flush with
/// every other track shaded. Each run is a block from its first entry to its last, filled solid: the error
/// colour when it could not complete, the warning colour when it had a problem, else coloured by how it
/// ended; a run that stood down is drawn hollow. Runs without a problem recede so the problems stand out,
/// except the run under the playhead, which keeps full weight and is bordered in the system accent.
/// Choosing a run moves the playhead to its start.
struct NightLanes: View {
    let timeline: NightTimeline
    /// The id of the run under the playhead, if any.
    let selection: NightAccount.ActRun.ID?
    let trackHeight: CGFloat
    /// The width of the time axis the tracks are laid along.
    let width: CGFloat
    let select: (NightAccount.ActRun) -> Void
    /// Each run's place in the account, counted from one, for its accessibility identifier.
    private let numbers: [String: Int]

    init(
        timeline: NightTimeline,
        selection: NightAccount.ActRun.ID?,
        trackHeight: CGFloat,
        width: CGFloat,
        select: @escaping (NightAccount.ActRun) -> Void
    ) {
        self.timeline = timeline
        self.selection = selection
        self.trackHeight = trackHeight
        self.width = width
        self.select = select
        numbers = Dictionary(
            timeline.account.runs.enumerated().map { ($1.id, $0 + 1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(timeline.account.lanes.enumerated()), id: \.offset) { index, act in
                track(act, index: index)
            }
        }
    }

    private func track(_ act: String?, index: Int) -> some View {
        ZStack(alignment: .leading) {
            ForEach(timeline.account.runs.filter { $0.act == act && timeline.scale.overlaps($0) }) { run in
                bar(run)
            }
        }
        .frame(width: width, height: trackHeight, alignment: .leading)
        .background(index.isMultiple(of: 2) ? AnyShapeStyle(.clear) : AnyShapeStyle(.surface))
        .clipped()
    }

    private func bar(_ run: NightAccount.ActRun) -> some View {
        let scale = timeline.scale
        let left = scale.position(run.startedAt, length: width)
        let barWidth = max(12, scale.position(run.lastAt, length: width) - left)
        let isSelected = selection == run.id
        return barShape(run)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.accent, lineWidth: isSelected ? 2 : 0))
            .overlay(alignment: .leading) {
                if barWidth >= 56, !run.outcome.isQuiet {
                    Text(run.outcome.shortWords)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isProblem(run) && !isFailure(run) ? Color.black : .white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: barWidth, height: trackHeight - 4)
            .opacity(isProblem(run) || isSelected ? 1 : 0.22)
            .contentShape(.rect)
            // Simultaneous with the strip's drag, which moves the playhead under the pointer first.
            .simultaneousGesture(TapGesture().onEnded { select(run) })
            .help("\(run.title) \u{2014} \(run.outcome.words)")
            .accessibilityElement()
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("\(run.title), \(run.outcome.words)\(run.hasProblem ? ", has a problem" : "")")
            .accessibilityAction { select(run) }
            .accessibilityIdentifier("night-account-run-\(numbers[run.id] ?? 0)")
            .offset(x: left)
    }

    /// A run's block: solid, except a run that stood down, which is hollow, so it reads as a run that never
    /// took the Project.
    @ViewBuilder
    private func barShape(_ run: NightAccount.ActRun) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        if run.outcome == .stoodDown {
            shape.strokeBorder(run.outcome.style, lineWidth: 1.5)
        } else if isFailure(run) {
            shape.fill(.error)
        } else if run.hasProblem {
            shape.fill(.warning)
        } else {
            shape.fill(run.outcome.style)
        }
    }

    /// Failure takes precedence over a problem when a run has both.
    private func isFailure(_ run: NightAccount.ActRun) -> Bool {
        if case .incomplete = run.outcome { return true }
        return false
    }

    private func isProblem(_ run: NightAccount.ActRun) -> Bool { isFailure(run) || run.hasProblem }
}
