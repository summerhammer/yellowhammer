import Config
import Domain
import Foundation
import Testing

// board-projection/provision-the-board (P22.8): `[board.linear.mapping]` names existing Linear objects that
// stand in for what Yellowhammer provisions or selects by category. Retired entries are accepted and ignored.

private func loaded(_ mapping: String) throws -> ProjectConfiguration {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-mapping-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(component: "mapped.toml", directoryHint: .notDirectory)
    try """
        id = "mapped"
        name = "Mapped"
        spec_source = "~/dev/spec"

        [board.linear]
        connection = "acme"
        project = "MAP"

        \(mapping)

        [[repos]]
        name = "only"
        path = "~/dev/only"
        role = "backend"
        check = "swift test"

        [code_hosting]
        connection = "github"
        """.write(to: file, atomically: true, encoding: .utf8)
    return try ProjectConfiguration.load(contentsOf: file)
}

private func error(of mapping: String) throws -> ConfigurationError {
    do {
        _ = try loaded(mapping)
    } catch let error as ConfigurationError {
        return error
    }
    throw ConfigurationError(file: "", line: 0, key: nil, reason: .missingKey)
}

private func id(_ string: String) -> BoardObjectID { BoardObjectID(rawValue: string) }

@Suite("Board Mapping configuration")
struct BoardMappingConfigurationTests {
    @Test("A Project without [board.linear.mapping] has an empty Board Mapping")
    func noMappingIsEmpty() throws {
        #expect(try loaded("").boardMapping == .empty)
    }

    @Test("Every state and Card Type label role is read from its key")
    func everyRoleIsRead() throws {
        let configuration = try loaded("""
            [board.linear.mapping]
            waiting_on_you = "s1"
            blocked = "s2"
            unstarted = "s3"
            started = "s4"
            completed = "s5"
            canceled = "s6"
            feature_card = "l1"
            work_card = "l2"
            night_card = "l3"
            """)

        let mapping = configuration.boardMapping
        #expect(mapping[.waitingOnYou] == id("s1") && mapping[.blocked] == id("s2"))
        #expect(mapping[.unstarted] == id("s3") && mapping[.started] == id("s4"))
        #expect(mapping[.completed] == id("s5") && mapping[.canceled] == id("s6"))
        #expect(mapping[.featureCard] == id("l1") && mapping[.workCard] == id("l2"))
        #expect(mapping[.nightCard] == id("l3"))
    }

    @Test("A key of a settled-away meaning is an ordinary unknown key", arguments: [
        "block_reason", "override", "kept_in_flight", "abandoned"
    ])
    func formerKeysAreUnknown(key: String) throws {
        let refusal = try error(of: """
            [board.linear.mapping]
            \(key) = "state-1"
            """)

        #expect(refusal.reason == .unknownKey)
        #expect(refusal.key == "board.linear.mapping.\(key)")
    }

    @Test("An unknown mapping key is refused")
    func unknownKeyIsRefused() throws {
        let refusal = try error(of: """
            [board.linear.mapping]
            in_progress = "s1"
            """)

        #expect(refusal.reason == .unknownKey)
        #expect(refusal.key == "board.linear.mapping.in_progress")
    }

    @Test("No id serves two meanings in one Project")
    func duplicateIdIsRefused() throws {
        let refusal = try error(of: """
            [board.linear.mapping]
            waiting_on_you = "same"
            blocked = "same"
            """)

        #expect(refusal.reason == .duplicateMappingID(firstKey: "waiting_on_you"))
        #expect(refusal.key == "board.linear.mapping.blocked")
    }

    @Test("An empty id is refused")
    func emptyIdIsRefused() throws {
        #expect(try error(of: "[board.linear.mapping]\nblocked = \"\"").reason == .emptyString)
    }

    @Test("Saving a Project through the form keeps its Board Mapping")
    func formRoundTripKeepsTheMapping() throws {
        let configuration = try loaded("""
            [board.linear.mapping]
            started = "s4"
            night_card = "l3"
            """)

        let rendered = ProjectFileDraft(configuration).renderedTOML

        #expect(rendered.contains("[board.linear.mapping]"))
        #expect(rendered.contains("started = \"s4\"") && rendered.contains("night_card = \"l3\""))
    }

    @Test("Projects on one Linear project with disagreeing mappings are both refused; the others load")
    func conflictingMappingsOnASharedLinearProjectAreRefused() throws {
        let directory = try #require(Bundle.module.url(
            forResource: "Sets/board-mapping", withExtension: nil, subdirectory: "Fixtures"
        ))

        let configuration = try Configuration.load(directory: directory)

        #expect(configuration.projects.map(\.id.rawValue) == ["gamma"])
        let invalid = Dictionary(
            uniqueKeysWithValues: configuration.invalidProjects.map { ($0.id?.rawValue ?? "", $0) }
        )
        #expect(Set(invalid.keys) == ["alpha", "beta"])
        let alpha = try #require(invalid["alpha"]?.errors.first)
        #expect(alpha.key == "board.linear.mapping")
        guard case .boardMappingConflict(let role, let project, _) = alpha.reason else {
            Issue.record("expected a boardMappingConflict, got \(alpha.reason)")
            return
        }
        #expect(role == "started" && project.rawValue == "beta")
    }
}
