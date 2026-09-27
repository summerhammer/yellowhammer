import Domain
import Testing

struct ExceptionNotificationTests {
    private let project = ProjectID(rawValue: "yellowhammer")!

    @Test(arguments: [
        ExceptionNotification.Event.halted(reason: "Bound reached: 3 attempts"),
        .haltedUnrecorded,
        .closed
    ])
    func argumentsRoundTrip(event: ExceptionNotification.Event) throws {
        let notification = ExceptionNotification(project: project, event: event)
        let launch = ["/Applications/Yellowhammer.app/Contents/MacOS/Yellowhammer"]
            + notification.arguments

        #expect(try ExceptionNotification(arguments: launch) == notification)
    }

    @Test func anOrdinaryLaunchIsNotAPost() throws {
        #expect(try ExceptionNotification(arguments: ["Yellowhammer"]) == nil)
        #expect(try ExceptionNotification(arguments: ["Yellowhammer", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test func argumentsBeforeThePostFlagAreIgnored() throws {
        let launch = ["Yellowhammer", "-psn_0_12345", "--post-notification",
                      "--project", "yellowhammer", "--event", "closed"]

        #expect(try ExceptionNotification(arguments: launch)
            == ExceptionNotification(project: project, event: .closed))
    }

    @Test func eachNotificationNamesItsProject() {
        let halted = ExceptionNotification(project: project, event: .halted(reason: "Linear unreachable"))

        #expect(halted.title == "yellowhammer")
        #expect(halted.body == "Night halted: Linear unreachable")
        #expect(ExceptionNotification(project: project, event: .closed).body == "Night closed")
        #expect(ExceptionNotification(project: project, event: .haltedUnrecorded).body ==
            "yellowhammer halted before its Night Card could be opened — nothing is recorded on the " +
                "board for this Night. Check the Journal or run yh status.")
    }

    @Test(arguments: [
        (["--post-notification"], ExceptionNotification.ArgumentError.missingProject),
        (["--post-notification", "--project", "yellowhammer"], .missingEvent),
        (["--post-notification", "--project", "not a project", "--event", "closed"],
         .invalidProject("not a project")),
        (["--post-notification", "--project", "yellowhammer", "--event", "opened"], .unknownEvent("opened")),
        (["--post-notification", "--project", "yellowhammer", "--event", "halted"], .missingReason),
        (["--post-notification", "--project", "yellowhammer", "--event", "halted", "--reason", "  "],
         .missingReason),
        (["--post-notification", "--project", "yellowhammer", "--event", "closed", "--reason", "x"],
         .unexpectedReason),
        (["--post-notification", "--project", "yellowhammer", "--event", "halted-unrecorded", "--reason", "x"],
         .unexpectedReason),
        (["--post-notification", "--project", "yellowhammer", "--event"], .missingValue("--event")),
        (["--post-notification", "--project", "a", "--project", "b"], .duplicateArgument("--project")),
        (["--post-notification", "--silent", "yes"], .unknownArgument("--silent"))
    ])
    func malformedPostArgumentsThrow(arguments: [String], expected: ExceptionNotification.ArgumentError) {
        #expect(throws: expected) {
            try ExceptionNotification(arguments: ["Yellowhammer"] + arguments)
        }
    }
}
