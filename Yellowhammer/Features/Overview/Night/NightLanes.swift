import Pulse
import SwiftUI

/// The Night's lanes: one for each Act, and one for unstamped events when there are any, under a time axis.
/// Each run is a bar from its first entry to its last, coloured by how it ended, a problem ringed in the
/// warning colour. The run under the playhead is ringed in the system accent, and choosing a bar moves the
/// playhead to the start of its run.
struct NightLanes: View {
    let timeline: NightTimeline
    /// The id of the run under the playhead, if any.
    let selection: NightAccount.ActRun.ID?
    /// The time axis's labels, worked out by the caller beside the ruler's ticks.
    let axis: [Date]
    let laneHeight: CGFloat
    let labelWidth: CGFloat
    let select: (NightAccount.ActRun) -> Void
    /// Each run's place in the account, counted from one, for its accessibility identifier.
    private let numbers: [String: Int]

    init(
        timeline: NightTimeline,
        selection: NightAccount.ActRun.ID?,
        axis: [Date],
        laneHeight: CGFloat,
        labelWidth: CGFloat,
        select: @escaping (NightAccount.ActRun) -> Void
    ) {
        self.timeline = timeline
        self.selection = selection
        self.axis = axis
        self.laneHeight = laneHeight
        self.labelWidth = labelWidth
        self.select = select
        numbers = Dictionary(
            timeline.account.runs.enumerated().map { ($1.id, $0 + 1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(timeline.account.lanes, id: \.self) { act in
                lane(act)
            }
            axisLabels
                .padding(.leading, labelWidth)
        }
    }

    private func lane(_ act: String?) -> some View {
        HStack(spacing: 0) {
            Text(act.map { $0.capitalized } ?? "No Act")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.separator).frame(height: 1)
                    ForEach(timeline.account.runs.filter { $0.act == act && timeline.scale.overlaps($0) }) { run in
                        bar(run, width: geometry.size.width)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: laneHeight)
            .clipped()
        }
    }

    private func bar(_ run: NightAccount.ActRun, width: CGFloat) -> some View {
        let scale = timeline.scale
        let left = scale.position(run.startedAt, length: width)
        let barWidth = max(10, scale.position(run.lastAt, length: width) - left)
        let height: CGFloat = run.outcome.isQuiet ? 10 : 16
        return Button {
            select(run)
        } label: {
            Capsule()
                .fill(run.outcome.style.opacity(run.outcome.isQuiet ? 0.45 : 0.9))
                .overlay(Capsule().strokeBorder(.warning, lineWidth: run.hasProblem ? 2.5 : 0))
                .overlay(
                    Capsule().strokeBorder(Color.accentColor, lineWidth: selection == run.id ? 2 : 0).padding(-3)
                )
                .frame(width: barWidth, height: height)
        }
        .buttonStyle(.plain)
        .help("\(run.title) \u{2014} \(run.outcome.words)")
        .accessibilityLabel("\(run.title), \(run.outcome.words)\(run.hasProblem ? ", has a problem" : "")")
        .accessibilityIdentifier("night-account-run-\(numbers[run.id] ?? 0)")
        .offset(x: left)
    }

    private var axisLabels: some View {
        GeometryReader { geometry in
            ForEach(axis, id: \.self) { tick in
                Text(tick.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: timeline.scale.position(tick, length: geometry.size.width), y: 6)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
