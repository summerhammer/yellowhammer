import Domain
import Testing

@Test("Roll-up uses exactly six current words and rejects retired spellings")
func rollUpWords() {
    #expect(RollUpState.allCases.map(\.rawValue) == [
        "authoring", "running", "waiting", "blocked", "partial", "verified"
    ])
    #expect(RollUpState(rawValue: "waiting") == .waiting)
    #expect(RollUpState(rawValue: "partial") == .partial)
    #expect(RollUpState(rawValue: "needs you") == nil)
    #expect(RollUpState(rawValue: "partial landing") == nil)
}
