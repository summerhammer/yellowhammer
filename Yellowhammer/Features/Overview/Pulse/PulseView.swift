import Domain
import Pulse
import SwiftUI

/// The main area: the selected Project's Pulse, under a head that names the Project and says its status, over
/// tinted cards for the groups, in the ruled order Needs you → Now → Feature → Tonight / last Night → Health.
///
/// It takes one Project's snapshot and gives each group only that group's part of it. A group reports
/// each way out through `openPulseDestination`, and never opens anything itself.
struct PulseView: View {
    let project: ProjectSnapshot
    /// The instant the snapshot describes. Elapsed times are measured to this, not to the clock.
    let asOf: Date
    /// What the Inspector shows, so the row it names is marked.
    let inspected: PulseSelection?
    let deliverNow: () -> Void
    let canDeliverNow: Bool
    let repairBoard: () -> Void
    let canRepairBoard: Bool
    let isRepairingBoard: Bool
    let boardRepairResult: String?

    /// The head's height, so the mist behind the scroll view is exactly as tall as the head plus the toolbar.
    @State private var headHeight: CGFloat = 0
    /// How far the content is scrolled from its rest, and the inset the toolbar takes at the top.
    @State private var scroll = PulseScroll()
    /// How far a scroll takes to bring the toolbar's backdrop in.
    private static let backdropFade: CGFloat = 16

    var body: some View {
        let condition = PulseCondition(project: project)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PulseHead(project: project, condition: condition) { group in
                        withAnimation { proxy.scrollTo(group, anchor: .top) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
                    VStack(alignment: .leading, spacing: 14) {
                        if let failure = project.journalFailure {
                            JournalFailureNotice(failure: failure)
                        } else {
                            ForEach(PulseGroup.allCases) { group in
                                card(group).id(group)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            .onScrollGeometryChange(for: PulseScroll.self) { geometry in
                PulseScroll(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top, topInset: geometry.contentInsets.top
                )
            } action: { _, new in
                scroll = new
            }
            // A scroll view hands the toolbar's safe area to its content as an inset, which its content cannot
            // ignore, so the mist is drawn behind the scroll view instead: from the window's top edge, under the
            // toolbar, to the head's bottom, and out under the sidebar and the Inspector, moved with the scroll so
            // it leaves with the head. Pulled past the top, it stretches rather than leaving a gap.
            .background(alignment: .top) {
                PulseMist(condition: condition)
                    .frame(height: max(0, headHeight + scroll.topInset + max(0, -scroll.offset)))
                    .offset(y: -max(0, scroll.offset))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                    // Mirrored, blurred, under the sidebar's and the Inspector's glass, so the mist runs the
                    // window's full width. The top safe area is already ignored, so nothing mirrors upward.
                    .backgroundExtensionEffect()
            }
            // The toolbar draws no bar of its own, so the mist shows through it; once content scrolls up under
            // the toolbar, a blurred backdrop, exactly the toolbar's height and ruled off at its bottom edge, fades
            // in behind it, so its items stay legible over the cards.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: scroll.topInset)
                    .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
                    .opacity(min(1, max(0, scroll.offset / Self.backdropFade)))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    @ViewBuilder private func card(_ group: PulseGroup) -> some View {
        let pulse = project.pulse
        switch group {
        case .needsYou: NeedsYouGroup(needsYou: pulse.needsYou, inspected: inspected)
        case .now: NowGroup(now: pulse.now, asOf: asOf, inspected: inspected)
        case .feature: FeatureGroup(feature: pulse.feature, stack: pulse.unmergedFeatures, inspected: inspected)
        case .night: NightGroup(night: pulse.night, scheduled: pulse.scheduledNight)
        case .health:
            HealthGroup(
                health: pulse.health, deliverNow: deliverNow, canDeliverNow: canDeliverNow,
                repairBoard: repairBoard, canRepairBoard: canRepairBoard,
                isRepairingBoard: isRepairingBoard, boardRepairResult: boardRepairResult
            )
        }
    }
}

/// The head of the main area: the Project's name, so the Pulse always says whose it is, and its Repo count,
/// over the Project's status in words — a status word, a symbol and one line, from `PulseCondition` — and a
/// jump to the group whose card explains it. `PulseView` draws its mist behind it.
private struct PulseHead: View {
    let project: ProjectSnapshot
    let condition: PulseCondition
    let jump: (PulseGroup) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: condition.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(condition.token)
                .frame(width: 52, height: 52)
                .background(condition.token.opacity(0.16), in: .rect(cornerRadius: 12))
                // A solid tile under the tint, so the icon reads over any colour of the mist.
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(project.name)
                        .accessibilityIdentifier("pulse-heading")
                    Text(" \u{00B7} " + (project.repos.count == 1 ? "1 Repo" : "\(project.repos.count) Repos"))
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(condition.title)
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                    Text(condition.line)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pulse-status")
            }
            Spacer(minLength: 12)
            if let group = condition.group {
                Button { jump(group) } label: {
                    Label("Show \(group.title)", systemImage: "arrow.down")
                }
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Pulse's scroll position: `offset` from rest (negative while pulled past the top) and the top inset.
private struct PulseScroll: Equatable {
    var offset: CGFloat = 0
    var topInset: CGFloat = 0
}

/// Why the Pulse cannot be shown: the Project's Journal could not be read.
private struct JournalFailureNotice: View {
    let failure: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Yellowhammer can\u{2019}t read this Project\u{2019}s Journal.",
                systemImage: "exclamationmark.triangle"
            )
            Text(failure)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("pulse-journal-failure")
    }
}
