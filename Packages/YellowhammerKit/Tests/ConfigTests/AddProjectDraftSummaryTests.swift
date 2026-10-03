import Config
import Domain
import Foundation
import Testing

@Suite("Add Project draft: summaries")
struct AddProjectDraftSummaryTests {
    @Test("Project summary")
    func project() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .project) == "Not named yet")
        draft.setName("Acme")
        #expect(draft.summary(of: .project) == "Acme \u{b7} acme")
        #expect(draft.displayName == "Acme")
        draft.setName("")
        draft.setProjectID("raw")
        #expect(draft.displayName == "raw")
    }

    @Test("Linear project summary: existing, and new in a team by name or by key")
    func linear() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .linearProject) == "No Linear project")
        draft.linearProjectID = " ACME "
        #expect(draft.summary(of: .linearProject) == "\u{201c}ACME\u{201d}")
        draft.linearChoice = .createInTeam
        #expect(draft.summary(of: .linearProject) == "No team")
        draft.teamKey = "ENG"
        #expect(draft.summary(of: .linearProject) == "New in ENG")
        draft.context.teams = [SetupChoices.Team(id: "t1", key: "ENG", name: "Engineering")]
        #expect(draft.summary(of: .linearProject) == "New in Engineering")
    }

    @Test("Repos summary")
    func repos() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .repos) == "No Repos yet")
        draft.addRepo(path: "/w/a")
        draft.addRepo(path: "/w/b")
        #expect(draft.summary(of: .repos) == "a and b")
    }

    @Test("Spec Source summary: path, Repo, and neither")
    func specSource() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .specSource) == "Not chosen")
        draft.useSpecSource(NSHomeDirectory() + "/dev/spec")
        #expect(draft.summary(of: .specSource) == "~/dev/spec")
        draft.specChoice = .repo
        #expect(draft.summary(of: .specSource) == "No spec Repo")
        draft.addSpecRepo(path: "/w/acme-spec")
        #expect(draft.summary(of: .specSource) == "Repo acme-spec")
    }

    @Test("Bounds summary: defaults and changed")
    func bounds() {
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .bounds) == "Defaults")
        draft.bounds.reviewRoundsMax = 4
        #expect(draft.summary(of: .bounds) == "4 Rounds \u{b7} 3 Attempts \u{b7} 3 Nights")
    }

    @Test("Jobs summary shows an edited window")
    func jobsEditedWindow() throws {
        var draft = AddProjectDraft()
        draft.schedule.nightStart = try #require(TimeOfDay("23:30"))
        draft.schedule.buildEveryMinutes = 20
        #expect(draft.summary(of: .jobs) == "LaunchAgents \u{b7} 23:30\u{2013}06:00, build every 20 min")
    }

    @Test("Jobs summary takes its window from the Schedule defaults")
    func jobs() {
        let schedule = Schedule()
        let window = "\(schedule.nightStart)\u{2013}\(schedule.nightEnd), build every \(schedule.buildEveryMinutes) min"
        var draft = AddProjectDraft()
        #expect(draft.summary(of: .jobs) == "LaunchAgents \u{b7} \(window)")
        draft.jobs = .export
        draft.exportDirectory = "/tmp/jobs"
        #expect(draft.summary(of: .jobs) == "Export launchd to /tmp/jobs \u{b7} \(window)")
        draft.exportUsesCron = true
        #expect(draft.summary(of: .jobs) == "Export cron to /tmp/jobs \u{b7} \(window)")
        draft.jobs = .notNow
        #expect(draft.summary(of: .jobs) == "Not installed")
        #expect(window == "22:00\u{2013}06:00, build every 15 min")
    }

    @Test("Fixed-phrase summaries start with a capital or an opening quote")
    func capitalised() {
        var draft = AddProjectDraft()
        draft.specChoice = .repo
        for step in AddProjectDraft.Step.allCases {
            let first = draft.summary(of: step).first
            #expect(first?.isUppercase == true || first == "\u{201c}", "\(step)")
        }
        draft.linearProjectID = "X"
        #expect(draft.summary(of: .linearProject).first == "\u{201c}")
    }

    @Test("Bounds fields cover the six Bounds with their defaults")
    func boundsFields() {
        #expect(Bounds.fields.count == 6)
        #expect(Bounds.fields.map(\.defaultValue) == [2, 3, 3, 2, 3, 2])
        #expect(Bounds.fields(.stopsCard).count == 3)
        #expect(Bounds.fields(.raisesToYou).count == 2)
        #expect(Bounds.fields[2].valueText(1) == "1 Night")
        #expect(Bounds.fields[2].valueText(3) == "3 Nights")
        #expect(Bounds().isDefault)
        var changed = Bounds()
        changed[keyPath: Bounds.fields[0].keyPath] = 9
        #expect(!changed.isDefault)
        #expect(changed.reviewRoundsMax == 9)
    }
}
