import Config
import Foundation
import Testing

private func answerWaitProject(_ limits: String = "") throws -> ProjectConfiguration {
    let fixture = try #require(Bundle.module.url(
        forResource: "minimal", withExtension: "toml", subdirectory: "Fixtures/Projects/Valid"
    ))
    let source = try String(contentsOf: fixture, encoding: .utf8)
    return try ProjectConfiguration.parse(source + limits, file: "answer-wait.toml")
}

@Test("answer_wait_minutes defaults to 30 and accepts positive integers", arguments: [1, 17, 30, 120])
func answerWaitPositiveMinutes(_ minutes: Int) throws {
    #expect(try answerWaitProject().bounds.answerWaitMinutes == 30)
    let project = try answerWaitProject("\n[limits]\nanswer_wait_minutes = \(minutes)\n")
    #expect(project.bounds.answerWaitMinutes == minutes)
    #expect(try ProjectConfiguration.parse(project.renderedTOML, file: "roundtrip.toml") == project)
}

@Test(
    "answer_wait_minutes refuses nonpositive and noninteger TOML values",
    arguments: ["0", "-1", "1.5", "\"5\"", "true"]
)
func answerWaitRefusesInvalidMinutes(_ value: String) {
    #expect(throws: ConfigurationError.self) {
        try answerWaitProject("\n[limits]\nanswer_wait_minutes = \(value)\n")
    }
}
