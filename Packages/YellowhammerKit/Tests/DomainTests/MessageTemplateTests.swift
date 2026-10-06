import Domain
import Testing

@Test("every Kind's built-in default is valid for that Kind and renders")
func messageTemplateDefaultsRender() throws {
    let values: [MessageTemplate.Token: String] = [
        .type: "feat", .scope: "(auth)", .partial: "partial landing: ", .title: "Add login",
        .workCardTitle: "Wire the form", .branch: "yh-alpha-login"
    ]
    for kind in MessageTemplate.Kind.allCases {
        _ = try MessageTemplate(kind.defaultText, kind: kind)
    }
    #expect(MessageTemplate.default(.pullRequestTitle).render(values) == "feat(auth): partial landing: Add login")
    #expect(MessageTemplate.default(.commitMessage).render(values) == "feat(auth): Wire the form")
    #expect(
        MessageTemplate.default(.wipCommitMessage).render(values)
            == "chore(wip): preserve uncommitted work on yh-alpha-login"
    )
}

@Test("an empty scope renders no parentheses and a missing value renders empty")
func messageTemplateEmptyScope() {
    let template = MessageTemplate.default(.pullRequestTitle)
    #expect(template.render([.type: "fix", .scope: "", .partial: "", .title: "Repair"]) == "fix: Repair")
    #expect(template.render([:]) == ": ")
}

@Test("each Kind refuses a token outside its own set")
func messageTemplateRefusesForeignTokens() {
    struct Case {
        let kind: MessageTemplate.Kind
        let text: String
        let name: String
        init(_ kind: MessageTemplate.Kind, _ text: String, _ name: String) {
            self.kind = kind
            self.text = text
            self.name = name
        }
    }
    let cases = [
        Case(.pullRequestTitle, "{work_card_key}", "work_card_key"),
        Case(.pullRequestTitle, "{story}", "story"),
        Case(.commitMessage, "{branch}", "branch"),
        Case(.commitMessage, "{partial}", "partial"),
        Case(.commitMessage, "{project}", "project"), // glossary:ignore GL001
        Case(.wipCommitMessage, "{title}", "title"),
        Case(.wipCommitMessage, "{scope}", "scope"),
        Case(.wipCommitMessage, "{work_card_title}", "work_card_title"),
        Case(.pullRequestTitle, "{nonsense}", "nonsense"),
        Case(.commitMessage, "{}", "")
    ]
    for item in cases {
        #expect(throws: MessageTemplate.Refusal.unknownToken(item.name)) {
            try MessageTemplate(item.text, kind: item.kind)
        }
    }
}

@Test("an empty or whitespace-only template is refused")
func messageTemplateRefusesEmpty() {
    for kind in MessageTemplate.Kind.allCases {
        #expect(throws: MessageTemplate.Refusal.empty) { try MessageTemplate("", kind: kind) }
        #expect(throws: MessageTemplate.Refusal.empty) { try MessageTemplate("  \n", kind: kind) }
    }
}

@Test("braces: a lone close brace is literal, an unterminated open brace is refused, tokens may repeat")
func messageTemplateBraces() throws {
    let literal = try MessageTemplate("done} {type} {type}", kind: .commitMessage)
    #expect(literal.render([.type: "fix"]) == "done} fix fix")
    #expect(throws: MessageTemplate.Refusal.unterminatedBrace) { try MessageTemplate("{type", kind: .commitMessage) }
    #expect(throws: MessageTemplate.Refusal.unknownToken("a{type")) {
        try MessageTemplate("{a{type}", kind: .commitMessage)
    }
    let plain = try MessageTemplate("no tokens here", kind: .wipCommitMessage)
    #expect(plain.render([.type: "feat"]) == "no tokens here")
}

@Test("a Change Type refuses empty, trims, and defaults to feat")
func changeTypeValidation() {
    #expect(ChangeType.feat.rawValue == "feat")
    #expect(ChangeType("") == nil)
    #expect(ChangeType("  ") == nil)
    #expect(ChangeType(" fix ")?.rawValue == "fix")
}
