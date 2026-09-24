import ArgumentParser
import Domain
import Engine

/// Parses `--result-fixture <pass>=<fixture>` or `--result-fixture <pass>@<card issue id>=<fixture>`,
/// shared by `yh rehearse` and the three Act commands. Only valid alongside a Rehearsal Night: a real
/// Night never reads a fixture, so it is never wired to `DispatchBinding.dispatch`.
enum ResultFixtureOption {
    static let help: ArgumentHelp = """
        Answer one pass of a Rehearsal Night from a named fixture instead of the default script \
        (`<pass>=<fixture>`, repeatable), or answer one pass for one named Card alone \
        (`<pass>@<card issue id>=<fixture>`), which takes priority over a same-pass entry with no Card \
        named. Only valid alongside --rehearsal: a real Night never reads a fixture. <pass> is one of \
        \(RunPass.allCases.map(\.rawValue).joined(separator: ", ")). <fixture> is a bundled fixture name, \
        with or without `.json` (e.g. `worker=worker-question`, `worker@BACK-1=worker-question`). Bundled \
        fixtures: \(RehearsalResultFixture.allCases.map(\.rawValue).joined(separator: ", ")).
        """

    /// An Act command's check: refuses any `--result-fixture` without `--rehearsal`, then every entry
    /// ``parse(_:)`` would refuse.
    static func validate(_ raw: [String], rehearsal: Bool) throws {
        guard rehearsal || raw.isEmpty else {
            throw ValidationError(
                "--result-fixture is only valid alongside --rehearsal: a real Night never reads a fixture."
            )
        }
        _ = try parse(raw)
    }

    /// Parses `raw` into a ``RehearsalScript``. Refuses an unknown pass, an unknown fixture, a fixture
    /// whose declared pass differs from the pass it is named against, the same pass given twice, the
    /// same (pass, Card issue id) given twice, and an empty or whitespace-bearing Card issue id.
    static func parse(_ raw: [String]) throws -> RehearsalScript {
        var byPass: [RunPass: RehearsalResultFixture] = [:]
        var byCard: [CardPass: RehearsalResultFixture] = [:]
        for entry in raw {
            switch try parseEntry(entry) {
            case .pass(let pass, let fixture):
                guard byPass[pass] == nil else {
                    throw ValidationError("--result-fixture names pass `\(pass.rawValue)` more than once.")
                }
                byPass[pass] = fixture
            case .card(let cardPass, let fixture):
                guard byCard[cardPass] == nil else {
                    throw ValidationError(
                        "--result-fixture names pass `\(cardPass.pass.rawValue)` for Card " +
                        "`\(cardPass.issueID)` more than once."
                    )
                }
                byCard[cardPass] = fixture
            }
        }
        return RehearsalScript(byPass: byPass, byCard: byCard)
    }

    private enum Entry {
        case pass(RunPass, RehearsalResultFixture)
        case card(CardPass, RehearsalResultFixture)
    }

    private static func parseEntry(_ entry: String) throws -> Entry {
        let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ValidationError(
                "--result-fixture `\(entry)` must be `<pass>=<fixture>` or `<pass>@<card issue id>=<fixture>`."
            )
        }
        let keyRaw = String(parts[0])
        let fixtureRaw = String(parts[1])

        let keyParts = keyRaw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let passRaw = String(keyParts[0])
        let issueID: String?
        if keyParts.count == 2 {
            let rawIssueID = String(keyParts[1])
            guard !rawIssueID.isEmpty, !rawIssueID.contains(where: \.isWhitespace) else {
                throw ValidationError(
                    "--result-fixture `\(entry)` names an empty or whitespace-bearing Card issue id."
                )
            }
            issueID = rawIssueID
        } else {
            issueID = nil
        }

        guard let pass = RunPass(rawValue: passRaw) else {
            let valid = RunPass.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("--result-fixture names an unknown pass `\(passRaw)`. Valid passes: \(valid).")
        }
        guard let fixture = fixture(named: fixtureRaw) else {
            let valid = RehearsalResultFixture.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError(
                "--result-fixture names an unknown fixture `\(fixtureRaw)`. Valid fixtures: \(valid)."
            )
        }
        guard fixture.pass == pass else {
            throw ValidationError(
                "--result-fixture `\(entry)` names fixture `\(fixture.rawValue)`, whose pass is " +
                "`\(fixture.pass.rawValue)`, not `\(pass.rawValue)`."
            )
        }
        if let issueID {
            return .card(CardPass(issueID: issueID, pass: pass), fixture)
        }
        return .pass(pass, fixture)
    }

    private static func fixture(named name: String) -> RehearsalResultFixture? {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        return RehearsalResultFixture(rawValue: fileName)
    }
}
