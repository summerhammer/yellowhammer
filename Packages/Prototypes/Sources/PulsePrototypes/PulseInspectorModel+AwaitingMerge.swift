#if DEBUG
import Domain
import Pulse
import SwiftUI

extension PulseInspectorModel {
    /// The small detail of a Feature in the Unmerged Feature Stack: identifier, k of N merged, and per
    /// repository its mainline state, branch, what it is stacked on, and its pull request.
    static func awaitingMerge(
        _ feature: AwaitingMergeFeature, stack: UnmergedFeatureStack, palette: PulsePalette
    ) -> PulseInspectorModel {
        let name = PulseStackText.name(feature)
        var badges: [(text: String, color: Color)] = [("awaiting merge", palette.landed)]
        if feature.landedTonight { badges.append(("landed tonight", palette.landed)) }
        var facts: [(label: String, value: String)] = [
            ("Merged", "\(feature.mergedCount) of \(feature.pushedCount)"),
            ("Stack", PulseStackText.fraction(stack))
        ]
        for repository in feature.repositories {
            let parts = [
                repository.merged ? "in mainline" : "not in mainline",
                repository.branch,
                repository.stackedOn.map { "stacked on \($0)" },
                repository.pullRequest.map { "#\($0.number)" + ($0.state.map { " \($0.rawValue)" } ?? "") }
            ]
            facts.append((repository.repo, parts.compactMap { $0 }.joined(separator: " · ")))
        }
        let pullRequests = feature.repositories.compactMap { repository in
            repository.pullRequest.map { chip in
                Item(
                    id: "\(repository.repo)#\(chip.number)", title: "\(repository.repo) #\(chip.number)",
                    subtitle: chip.state?.rawValue ?? "state unknown", systemImage: "arrow.triangle.pull",
                    tint: palette.color(for: chip.state), action: .open(.pullRequest(chip.url))
                )
            }
        }
        return PulseInspectorModel(
            kind: "Feature",
            systemImage: "flag.checkered",
            tint: palette.landed,
            identifier: name,
            title: name,
            badges: badges,
            progress: (feature.mergedCount, feature.pushedCount),
            facts: facts,
            related: pullRequests.isEmpty ? [] : [Related(title: "Pull requests", items: pullRequests)],
            primary: feature.link.map { ("Open \($0.identifier) in Linear", .linearIssue($0.url)) },
            note: "Merge happens in GitHub, not here."
        )
    }
}
#endif
