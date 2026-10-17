import Pulse
import SwiftUI

/// The Night's account as an editor, under the Project's name: the Night at the playhead's moment, a
/// transport under it, and the Night's lanes docked at the bottom under a ruler. Drag on the ruler to scrub;
/// the transport steps five minutes or a problem at a time.
///
/// The playhead is this view's own state. It opens on the Night's first problem, else its opening, and stays
/// where the Operator left it when the account is read again, because the view keeps its identity while the
/// Night is open. The timeline is worked out once, here in `init`, so a drag only searches it.
struct NightEditor: View {
    private let timeline: NightTimeline
    @State private var playhead: Date
    /// The least height the viewer is laid out in: its header, its tiles and a log a few entries tall.
    private static let minimumViewerHeight: CGFloat = 560

    init(account: NightAccount) {
        let timeline = NightTimeline(account: account)
        self.timeline = timeline
        _playhead = State(initialValue: timeline.opening)
    }

    private var moment: NightMoment { timeline.moment(at: playhead) }

    var body: some View {
        VStack(spacing: 0) {
            // The viewer is exactly as tall as the space above the transport, so its log stretches down to it;
            // only when that space is shorter than the viewer needs does the viewer scroll as a whole.
            GeometryReader { geometry in
                ScrollView {
                    NightEditorViewer(moment: moment, playhead: $playhead)
                        .padding([.horizontal, .bottom], 20)
                        .padding(.top, 6)
                        .frame(height: max(geometry.size.height, Self.minimumViewerHeight))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Divider()
            NightEditorTransport(moment: moment, playhead: $playhead)
            Divider()
            NightEditorTimeline(timeline: timeline, playhead: $playhead)
        }
    }
}

extension Date {
    /// `15:12:04`, in this Mac's locale and time zone.
    var nightClock: String { formatted(.dateTime.hour().minute().second()) }
}
