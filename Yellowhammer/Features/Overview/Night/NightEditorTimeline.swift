import Pulse
import SwiftUI

/// The Night's lanes docked at the bottom of the editor, under a ruler with a triangular playhead head and
/// a line through the lanes. Drag on the ruler to scrub; the ruler is also an adjustable element for
/// VoiceOver, five minutes a step. A problem is a dot on the ruler.
struct NightEditorTimeline: View {
    let timeline: NightTimeline
    @Binding var playhead: Date
    private let labelWidth: CGFloat = 64
    private let rulerTicks: [RulerTick]
    private let axisTicks: [Date]

    /// A tick on the ruler: taller on the hour.
    private struct RulerTick: Identifiable {
        let date: Date
        let isOnHour: Bool
        var id: Date { date }
    }

    /// The ticks depend on the Night alone, never on the playhead: worked out here, once per pass, and handed
    /// to the ruler and the lanes' axis.
    init(timeline: NightTimeline, playhead: Binding<Date>) {
        self.timeline = timeline
        _playhead = playhead
        rulerTicks = timeline.scale.quarterHours.map {
            RulerTick(date: $0, isOnHour: Calendar.current.component(.minute, from: $0) == 0)
        }
        axisTicks = timeline.scale.ticks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ruler
            NightLanes(
                timeline: timeline,
                selection: timeline.moment(at: playhead).runUnderPlayhead?.id,
                axis: axisTicks,
                laneHeight: 28,
                labelWidth: labelWidth,
                select: { playhead = $0.startedAt }
            )
            .overlay { playheadLine }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background.secondary)
    }

    private var ruler: some View {
        GeometryReader { geometry in
            let length = geometry.size.width
            let scale = timeline.scale
            ZStack(alignment: .topLeading) {
                ForEach(rulerTicks) { tick in
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1, height: tick.isOnHour ? 10 : 5)
                        .offset(x: scale.position(tick.date, length: length), y: tick.isOnHour ? 8 : 13)
                }
                ForEach(Array(timeline.problemTimes.enumerated()), id: \.offset) { problem in
                    Circle()
                        .fill(.warning)
                        .frame(width: 5, height: 5)
                        .offset(x: scale.position(problem.element, length: length) - 2.5, y: 2)
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: scale.position(playhead, length: length) - 6.5, y: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    playhead = scale.date(at: drag.location.x, length: length)
                }
            )
        }
        .frame(height: 20)
        .padding(.leading, labelWidth)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(playhead.formatted(.dateTime.hour().minute()))
        .accessibilityAdjustableAction { direction in
            playhead = timeline.moment(at: playhead).moved(by: direction == .increment ? 300 : -300)
        }
        .accessibilityIdentifier("night-account-playhead")
    }

    /// The playhead through the lanes, stopping above their time axis.
    private var playheadLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: max(geometry.size.height - 14, 0))
                .offset(x: labelWidth + timeline.scale.position(playhead, length: geometry.size.width - labelWidth))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
