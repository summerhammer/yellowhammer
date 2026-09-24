import Domain
import Foundation
import Testing

struct ProjectDeepLinkTests {
    private let project = ProjectID(rawValue: "yellow-hammer_2")!

    @Test func urlNamesTheProject() {
        #expect(ProjectDeepLink(project: project).url.absoluteString == "yellowhammer://project/yellow-hammer_2")
    }

    @Test func urlRoundTrips() {
        let link = ProjectDeepLink(project: project)

        #expect(ProjectDeepLink(url: link.url) == link)
    }

    @Test(arguments: [
        "yellowhammer://project/yellow-hammer_2",
        "yellowhammer://project/yellow-hammer_2/",
        "YellowHammer://PROJECT/yellow-hammer_2"
    ])
    func readsTheProject(string: String) throws {
        let url = try #require(URL(string: string))

        #expect(ProjectDeepLink(url: url)?.project == project)
    }

    @Test(arguments: [
        "yellowhammer://project/",
        "yellowhammer://project",
        "yellowhammer://project/a/b",
        "yellowhammer://project/has%20space",
        "yellowhammer://project/caf%C3%A9",
        "yellowhammer://night/yellowhammer",
        "yellowhammer:project/yellowhammer",
        "https://project/yellowhammer",
        "yellowhammer://project/yellowhammer?status=1",
        "yellowhammer://project/yellowhammer#status",
        "yellowhammer://user@project/yellowhammer",
        "yellowhammer://project:80/yellowhammer"
    ])
    func refusesAnythingElse(string: String) throws {
        let url = try #require(URL(string: string))

        #expect(ProjectDeepLink(url: url) == nil)
    }

    @Test func theIDIsCaseSensitive() throws {
        let url = try #require(URL(string: "yellowhammer://project/Yellowhammer"))

        #expect(ProjectDeepLink(url: url)?.project.rawValue == "Yellowhammer")
    }
}

struct ProjectIDCodingTests {
    @Test func encodesAsItsRawString() throws {
        let data = try JSONEncoder().encode([ProjectID(rawValue: "yellowhammer")!])

        #expect(String(bytes: data, encoding: .utf8) == #"["yellowhammer"]"#)
    }

    @Test func roundTrips() throws {
        let id = ProjectID(rawValue: "yellow-hammer_2")!
        let data = try JSONEncoder().encode(id)

        #expect(try JSONDecoder().decode(ProjectID.self, from: data) == id)
    }

    @Test(arguments: [#""""#, #""has space""#, #""../escape""#])
    func refusesAnInvalidID(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProjectID.self, from: Data(json.utf8))
        }
    }
}
