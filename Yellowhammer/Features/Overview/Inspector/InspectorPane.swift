import Domain
import Pulse
import SwiftUI

/// The frame every Inspector pane shares: a large header (a tinted icon tile, the kind, the title, an
/// identifier and badges) over a grouped form of the pane's sections, and the one way out pinned below.
/// Read-only: the way out opens Linear or GitHub, where a triage gesture is made.
struct InspectorPane<Style: ShapeStyle, Badges: View, Content: View>: View {
    let kind: LocalizedStringResource
    let systemImage: String
    let style: Style
    let title: String
    /// The issue id or other identifier under the title, when it is not the title itself.
    let subtitle: String?
    /// The accessibility identifier of the title.
    let titleIdentifier: String
    let wayOut: (title: LocalizedStringResource, destination: PulseDestination)?
    let note: LocalizedStringResource?
    let identifier: String
    let wayOutIdentifier: String
    let badges: Badges
    let content: Content
    @Environment(\.openPulseDestination) private var openDestination

    init(
        kind: LocalizedStringResource,
        systemImage: String,
        style: Style,
        title: String,
        subtitle: String? = nil,
        titleIdentifier: String,
        wayOut: (title: LocalizedStringResource, destination: PulseDestination)?,
        note: LocalizedStringResource?,
        identifier: String,
        wayOutIdentifier: String? = nil,
        @ViewBuilder badges: () -> Badges,
        @ViewBuilder content: () -> Content
    ) {
        self.kind = kind
        self.systemImage = systemImage
        self.style = style
        self.title = title
        self.subtitle = subtitle
        self.titleIdentifier = titleIdentifier
        self.wayOut = wayOut
        self.note = note
        self.identifier = identifier
        self.wayOutIdentifier = wayOutIdentifier ?? "\(identifier)-way-out"
        self.badges = badges()
        self.content = content()
    }

    var body: some View {
        Form {
            Section {
                EmptyView()
            } header: {
                header
                    .padding(.bottom, 4)
                    .textCase(nil)
            }
            content
        }
        .formStyle(.grouped)
        // On the Form, not the whole pane: an identifier set outside `safeAreaBar` replaces the way-out
        // button's own.
        .accessibilityIdentifier(identifier)
        .safeAreaBar(edge: .bottom) {
            if let wayOut {
                VStack(spacing: 6) {
                    Button { openDestination(wayOut.destination) } label: {
                        Label(String(localized: wayOut.title), systemImage: "arrow.up.forward.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(wayOutIdentifier)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(style)
                .frame(width: 44, height: 44)
                .background(style.opacity(0.14), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(titleIdentifier)
                if let subtitle, subtitle != title {
                    Text(subtitle).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) { badges }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label beside a value, for the facts an Inspector pane lists.
struct InspectorFact: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        LabeledContent(String(localized: label)) {
            Text(value).textSelection(.enabled)
        }
    }
}

/// A Repo Lane's member Cards, one row each. A Card the Pulse lists under Needs you opens its Card
/// detail; any other is listed as a row, because the Inspector has no detail to open for it.
struct LaneCardList: View {
    let cards: [LaneCard]
    let decisionCardIDs: Set<String>
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        ForEach(cards) { card in
            HStack(spacing: 6) {
                if decisionCardIDs.contains(card.id) {
                    Button("\(card.issueIDForDisplay ?? card.id)  \(card.title)") {
                        openDestination(.inspector(.card(card.id)))
                    }
                    .buttonStyle(.link)
                } else {
                    Text("\(card.issueIDForDisplay ?? card.id)  \(card.title)")
                }
                Spacer(minLength: 4)
                PulseCountBadge(text: card.state.rawValue, style: card.state.style)
            }
            .lineLimit(1)
            .accessibilityIdentifier("lane-card-\(card.id)")
        }
    }
}

extension PullRequestChip {
    /// `#42 open`, or just `#42` while the pull request's own state is unknown (it lives in GitHub).
    var label: String {
        ["#\(number)", state?.rawValue].compactMap { $0 }.joined(separator: " ")
    }
}
