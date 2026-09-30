import Domain
import Foundation
import Journal
import Sparkle

/// Names the Projects whose Journal holds a live Lease, given the configured Projects and the
/// configuration directory to look for their Journals in. Pure and testable in isolation from
/// Sparkle: `launchd` runs `yh` from inside the app bundle, so an update that replaced the bundle
/// out from under a live Lease would corrupt whatever Act holds it. A Journal that does not exist
/// yet holds no Lease — no Act has ever run for that Project. A Journal that fails to open for any
/// other reason (an unreadable schema, for instance) is treated as a refusal too: fail closed,
/// named, rather than silently proceeding past a Journal the app could not actually check.
enum LiveLeaseScan {
    /// One Project the updater must not proceed past, and why.
    struct Refusal {
        let projectName: String
        let reason: String
        /// Whether the refusal is a live Lease (worded as such) or a fail-closed refusal because
        /// something could not be read at all.
        let isLiveLease: Bool
    }

    static func refusals(
        projects: ConfiguredProjects,
        directory: URL,
        now: Date = Date()
    ) -> [Refusal] {
        // An unreadable configuration cannot be scanned for live Leases at all: fail closed rather
        // than proceed as though there were no configured Projects to check.
        if let loadFailure = projects.loadFailure {
            return [
                Refusal(
                    projectName: "Yellowhammer",
                    reason: "the configuration could not be read: \(loadFailure)",
                    isLiveLease: false
                )
            ]
        }
        return projects.entries.compactMap { entry in
            let fileURL = JournalStore.defaultFileURL(configurationDirectory: directory, id: entry.id)
            do {
                let journal = try JournalStore.openReadOnly(at: fileURL, projectID: entry.id)
                guard try journal.holdsLiveLease(now: now) else { return nil }
                return Refusal(projectName: entry.name, reason: "an Act is running", isLiveLease: true)
            } catch JournalError.missing {
                return nil
            } catch {
                return Refusal(
                    projectName: entry.name,
                    reason: "its Journal could not be read: \(error)",
                    isLiveLease: false
                )
            }
        }
    }

    /// The error the updater's install gate throws when one or more Projects refuse the update,
    /// naming every Project involved and why. A live Lease is worded as one; a Journal or
    /// configuration that could not be read at all is named as what it is, not misdescribed as a
    /// running Act.
    static func error(for refusals: [Refusal]) -> NSError {
        let sentences = refusals.map { refusal in
            refusal.isLiveLease
                ? "Yellowhammer can't update while an Act is running for \(refusal.projectName). " +
                    "Try again when it finishes."
                : "Yellowhammer can't update: \(refusal.reason) for \(refusal.projectName)."
        }
        return NSError(
            domain: "dev.yellowhammer.updater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sentences.joined(separator: "\n")]
        )
    }
}

/// Gates Sparkle's install: throws unless every configured Project's Journal is free of a live
/// Lease at the moment an update is found (before it is shown or downloaded). Never installs
/// silently — `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` and `SUAllowsAutomaticUpdates` are
/// all `NO` (Info.plist), so this hook only ever fires from the Operator's own "Check for Updates…".
///
/// `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR`, so this class — and the method Sparkle calls on
/// it — is `@MainActor`-isolated, matching every other model in this app.
///
/// Known, unclosed gap — read before touching this: `shouldProceedWithUpdate` is the only
/// delegate hook this app can use to prevent an install, and it only gates *download*. Once it
/// passes, Sparkle downloads, verifies and extracts the update automatically in the background
/// (`AppInstaller`'s "stage 1"), independent of the Operator ever clicking "Install and Relaunch".
/// `shouldPostponeRelaunchForUpdate:untilInvokingBlock:` looks like a second gate but is not one:
/// verified against Sparkle's own source (`Autoupdate/AppInstaller.m`,
/// `-finishInstallationAfterHostTermination`), once stage 1 has completed, quitting the host app
/// for *any* reason — not just clicking Install — makes the separate installer process perform
/// the actual file swap, whether or not that delegate method was ever asked or what it returned.
/// So a Lease claimed after a "Check for Updates…" passes and before Yellowhammer next quits is
/// not caught by anything in this app. See doc/update-channel.md for the design options this
/// implies; this file deliberately does not implement a hook that would misleadingly claim to
/// close that window.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let refusals = LiveLeaseScan.refusals(
            projects: ConfiguredProjects.load(),
            directory: ConfigurationDirectory.current
        )
        guard refusals.isEmpty else {
            throw LiveLeaseScan.error(for: refusals)
        }
    }
}
