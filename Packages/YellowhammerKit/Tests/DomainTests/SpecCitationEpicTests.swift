import Domain
import Testing

@Test("a story ID has an epic; a goal ID, an anchor or a malformed path has none")
func specCitationEpic() {
    #expect(SpecCitation("auth/sign-in").epic == "auth")
    #expect(SpecCitation("feature-authoring/write-a-card#dod-1").epic == "feature-authoring")
    #expect(SpecCitation("  auth/sign-in  ").epic == "auth")
    for notAStory in ["G1", "{#g5}", "#g5", "a/b/c", "/x", "x/", "goals", "auth/ x", "", "{auth/x}", "#a/b"] {
        #expect(SpecCitation(notAStory).epic == nil, "\(notAStory) is not a story ID")
    }
}

@Test("a story ID citation has a story with any #fragment stripped; anything else has none")
func specCitationStory() {
    #expect(SpecCitation("auth/login").story == "auth/login")
    #expect(SpecCitation("auth/login#ac-2").story == "auth/login")
    #expect(SpecCitation("  auth/login  ").story == "auth/login")
    for notAStory in ["G1", "{#g5}", "#g5", "a/b/c", "/x", "x/", ""] {
        #expect(SpecCitation(notAStory).story == nil, "\(notAStory) is not a story ID")
    }
}
