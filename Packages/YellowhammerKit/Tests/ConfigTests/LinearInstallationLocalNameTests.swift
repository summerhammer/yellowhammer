import Config
import Testing

@Suite("LinearInstallation local-name rule")
struct LinearInstallationLocalNameTests {
    @Test("Valid names match ^[a-z0-9][a-z0-9_-]*$", arguments: ["a", "acme", "acme-2", "a_b", "9lives", "a-"])
    func validNames(name: String) {
        #expect(LinearInstallation.isValidLocalName(name))
    }

    @Test(
        "Invalid names are rejected",
        arguments: ["", "-acme", "_acme", "Acme", "my acme", "acme.io", "café", "acme\n", "日本"]
    )
    func invalidNames(name: String) {
        #expect(!LinearInstallation.isValidLocalName(name))
    }
}
