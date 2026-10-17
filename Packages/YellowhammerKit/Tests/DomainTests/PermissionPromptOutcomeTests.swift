import Domain
import Foundation
import Testing

// #555: a pass a macOS permission prompt blocked is an engine stop, Crashed-Unknown, never a hard failure.

private let detail = "Keychain prompt for /usr/bin/security (pid 7365), item dev.yellowhammer.probe"

@Test("A prompt-blocked run is Crashed-Unknown, stopped by the engine, whatever the result file holds")
func promptBlockedIsEngineStoppedCrashedUnknown() {
    for forcedKill in [false, true] {
        let outcome = RunOutcome.classify(
            end: .promptBlocked(detail: detail, forcedKill: forcedKill), resultFile: Data("{}".utf8), pass: .worker
        )
        let cause = "a macOS permission prompt blocked the pass: \(detail)"
        #expect(outcome == .crashedUnknown(.engineStopped(cause: cause)))
    }
}

@Test("A prompt-blocked Attempt is consumed, excludes no Route, and reads as stopped by the engine")
func promptBlockedEndingConsumesWithoutExcluding() throws {
    let outcome = RunOutcome.classify(
        end: .promptBlocked(detail: detail, forcedKill: false), resultFile: nil, pass: .worker
    )
    let ending = try #require(AttemptEnding(failedRun: outcome))

    #expect(ending.outcome == .crashedUnknown)
    #expect(ending.excludesRoute == false)
    #expect(ending.exclusionReason == nil)
    #expect(ending.consumesAttempt)
    #expect(ending.classification == "stopped by the engine: a macOS permission prompt blocked the pass: \(detail)")
    #expect(ending.classification.hasPrefix(AttemptEnding.engineStoppedClassificationPrefix))
    #expect(ending.consumedHow == "consumed; route not excluded (Crashed-Unknown, stopped by the engine)")
}

@Test("Only the permission-prompt engine stop says it is one")
func onlyPermissionPromptCauseIsPermissionPrompt() {
    #expect(CrashedUnknownCause.permissionPrompt(detail).isPermissionPrompt)
    #expect(!CrashedUnknownCause.engineStopped(cause: "heartbeat failed").isPermissionPrompt)
    #expect(!CrashedUnknownCause.reclaimed("no result file for the worker pass").isPermissionPrompt)
}

@Test("A permission prompt recurs as its own Failure-Cause, without its pid")
func permissionPromptFailureCauseIgnoresDetail() throws {
    let first = try #require(FailureCause(ending: .crashedUnknown(.permissionPrompt(detail))))
    let other = "Keychain prompt for /bin/sh (pid 1)"
    let second = try #require(FailureCause(ending: .crashedUnknown(.permissionPrompt(other))))
    let engineStop = try #require(FailureCause(ending: .crashedUnknown(.engineStopped(cause: "heartbeat failed"))))

    #expect(first == second)
    #expect(first.summary == "Crashed-Unknown (permission prompt)")
    #expect(engineStop.summary == "Crashed-Unknown (reclaimed)")
}

@Test("A prompt-blocked run end describes itself")
func promptBlockedDescription() {
    #expect(
        RunEnd.promptBlocked(detail: "x", forcedKill: true).description == "promptBlocked(x, forcedKill: true)"
    )
}
