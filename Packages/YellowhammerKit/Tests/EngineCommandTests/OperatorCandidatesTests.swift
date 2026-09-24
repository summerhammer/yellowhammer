import Domain
import Engine
import Testing

private func member(
    id: String, name: String, displayName: String, isActive: Bool = true, isApp: Bool = false, isSelf: Bool = false
) -> BoardMember {
    BoardMember(
        id: BoardObjectID(rawValue: id), name: name, displayName: displayName,
        isActive: isActive, isApp: isApp, isSelf: isSelf
    )
}

@Suite("Operator candidates")
struct OperatorCandidatesTests {
    @Test("A deactivated member is excluded")
    func excludesDeactivated() {
        let active = member(id: "u1", name: "alice", displayName: "Alice")
        let deactivated = member(id: "u2", name: "bob", displayName: "Bob", isActive: false)
        #expect(OperatorIdentity.candidates(from: [active, deactivated]) == [active])
    }

    @Test("An app member is excluded")
    func excludesApp() {
        let human = member(id: "u1", name: "alice", displayName: "Alice")
        let app = member(id: "u2", name: "bot", displayName: "Bot", isApp: true)
        #expect(OperatorIdentity.candidates(from: [human, app]) == [human])
    }

    @Test("Yellowhammer's own identity is excluded")
    func excludesSelf() {
        let human = member(id: "u1", name: "alice", displayName: "Alice")
        let itself = member(id: "u2", name: "yellowhammer", displayName: "Yellowhammer", isSelf: true)
        #expect(OperatorIdentity.candidates(from: [human, itself]) == [human])
    }

    @Test("Candidates sort case-insensitively by displayName, then name, then id")
    func sortsCaseInsensitively() {
        let bob = member(id: "u2", name: "bob", displayName: "bob")
        let alice = member(id: "u1", name: "alice", displayName: "Alice")
        let anotherAlice = member(id: "u3", name: "alice2", displayName: "alice")
        let tieBreakerA = member(id: "u4", name: "carol", displayName: "Carol")
        let tieBreakerB = member(id: "u5", name: "carol", displayName: "Carol")
        let candidates = OperatorIdentity.candidates(
            from: [bob, tieBreakerB, alice, tieBreakerA, anotherAlice]
        )
        #expect(candidates.map(\.id.rawValue) == ["u1", "u3", "u2", "u4", "u5"])
    }

    @Test("No active human non-self members yields an empty result")
    func emptyResult() {
        let deactivated = member(id: "u1", name: "alice", displayName: "Alice", isActive: false)
        let app = member(id: "u2", name: "bot", displayName: "Bot", isApp: true)
        let itself = member(id: "u3", name: "yellowhammer", displayName: "Yellowhammer", isSelf: true)
        #expect(OperatorIdentity.candidates(from: [deactivated, app, itself]).isEmpty)
    }
}
