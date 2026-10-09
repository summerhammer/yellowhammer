#if DEBUG
import Domain
import Pulse
import SwiftUI

/// The plainest reading of the spec (app/land-on-the-sidebar-and-pulse): a three-column window —
/// Sidebar, the Pulse's five groups as boxes in ruled order, and an Inspector. A starting point to
/// copy, not a design: new variants begin from this file.
struct PulseBaselineVariant: View {
    let snapshot: LandingSnapshot
    @Binding var selection: ProjectID?
    @State private var inspected: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let project = snapshot.project(selection) {
                pulse(project)
            } else {
                Text("Select a Project").foregroundStyle(.secondary)
            }
        }
        .inspector(isPresented: .constant(inspected != nil)) {
            inspector
        }
    }

    private func open(_ selection: PulseSelection) {
        inspected = selection
        openDestination(.inspector(selection))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(snapshot.projects) { project in
                Label {
                    HStack {
                        Text(project.name)
                        Spacer()
                        Text(project.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: project.status == .working ? "circle.fill" : "circle")
                        .foregroundStyle(project.status == .working ? .green : .secondary)
                }
                .tag(project.id)

                ForEach(project.repos, id: \.self) { repo in
                    repoRow(repo, in: project)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    @ViewBuilder
    private func repoRow(_ repo: String, in project: ProjectSnapshot) -> some View {
        Button { open(.repo(repo)) } label: {
            HStack {
                Label(repo, systemImage: "shippingbox")
                Spacer()
                if let lane = project.laneState(for: repo) {
                    Text(lane.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 16)
        if let attempt = project.runningAttempt(for: repo) {
            Button { open(.attempt(attempt.id)) } label: {
                Label("\(attempt.route) · \(elapsed(since: attempt.startedAt))", systemImage: "gearshape.2")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.leading, 32)
        }
    }

    // MARK: Pulse

    private func pulse(_ project: ProjectSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(project.name).font(.largeTitle.bold())
                group("Needs you") { needsYou(project.pulse.needsYou) }
                group("Now") { now(project.pulse.now) }
                group("Feature") { feature(project.pulse.feature) }
                group("Tonight / last Night") { night(project.pulse.night) }
                group("Health") { health(project.pulse.health) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
    }

    @ViewBuilder
    private func needsYou(_ needsYou: NeedsYou) -> some View {
        if needsYou.cards.isEmpty {
            Text("Nothing needs you").foregroundStyle(.secondary)
        } else {
            Text("\(needsYou.waitingOnYouCount) Waiting on You")
            ForEach(needsYou.blockReasonCounts, id: \.reason) { entry in
                Text("\(entry.count) \(entry.reason.rawValue)").foregroundStyle(.secondary)
            }
            ForEach(needsYou.cards) { card in
                Button { open(.card(card.id)) } label: {
                    Text("\(card.id)  \(card.title)")
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func now(_ now: Now) -> some View {
        if let next = now.nextAct {
            let time = next.at.formatted(date: .omitted, time: .shortened)
            Text("\(now.status.rawValue) — next Act \(next.act.rawValue) \(time)")
        } else {
            Text(now.status.rawValue)
        }
        ForEach(now.attempts) { attempt in
            Button { open(.attempt(attempt.id)) } label: {
                Text("\(attempt.cardID) · \(attempt.repo)\(attempt.status.map { " · \($0)" } ?? "")")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func feature(_ feature: FeatureInFlight?) -> some View {
        if let feature {
            Button { open(.feature(feature.id)) } label: {
                Text([feature.id, feature.title].compactMap { $0 }.joined(separator: "  "))
            }
            .buttonStyle(.link)
            Text([feature.state, feature.rollupState?.rawValue].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            ForEach(feature.lanes) { lane in
                HStack {
                    Text(lane.repo)
                    Text("\(lane.cardsDone)/\(lane.cardsTotal) · \(lane.state.rawValue)").foregroundStyle(.secondary)
                    if let pullRequest = lane.pullRequest {
                        let title = ["#\(pullRequest.number)", pullRequest.state?.rawValue]
                            .compactMap { $0 }.joined(separator: " ")
                        Button(title) {
                            openDestination(.pullRequest(pullRequest.url))
                        }
                        .controlSize(.small)
                    }
                }
            }
        } else {
            Text("No Feature in flight").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func night(_ night: NightPulse?) -> some View {
        if let night {
            if let link = night.nightCard {
                Button(night.verdictLine ?? "Night Card") { openDestination(.nightCard(link.url)) }
                    .buttonStyle(.link)
            } else {
                Text(night.verdictLine ?? "Night Card")
            }
            Text(night.state.rawValue).foregroundStyle(.secondary)
            Text(night.cardsByDisposition.map { "\($0.count) \($0.disposition.rawValue)" }.joined(separator: " · "))
                .foregroundStyle(.secondary)
        } else {
            Text("No Night yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func health(_ flags: [HealthFlag]?) -> some View {
        if let flags, !flags.isEmpty {
            ForEach(flags) { flag in
                Button { openDestination(.settings) } label: {
                    VStack(alignment: .leading) {
                        Label("\(flag.kind.rawValue): \(flag.detail)", systemImage: "exclamationmark.triangle")
                        if flag.kind == .undeliveredBoardWrites {
                            Text(flag.outboxSummary).font(.caption).foregroundStyle(.secondary)
                            if let error = flag.lastError {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let recoveredAt = flag.recoveredAt {
                            let count = flag.occurrenceCount
                            let time = recoveredAt.formatted(date: .omitted, time: .shortened)
                            Text("\(count) failure · recovered \(time)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.link)
            }
        } else if flags == nil {
            Text("Not read — yh doctor was not run").foregroundStyle(.secondary)
        } else {
            Text("Healthy — yh doctor raised nothing").foregroundStyle(.secondary)
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inspector").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { inspected = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            if let inspected {
                Text(String(describing: inspected)).font(.callout.monospaced())
            }
            Spacer()
        }
        .padding()
        .inspectorColumnWidth(min: 240, ideal: 280)
    }

    private func elapsed(since start: Date) -> String {
        Duration.seconds(snapshot.asOf.timeIntervalSince(start))
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}

#Preview("Baseline") {
    PulsePlayground(variant: "Baseline")
}
#endif
