import Domain
import Testing

struct ConfigInvocationTests {
    @Test("operatorArguments always passes --installation before the user id")
    func operatorArgumentsVector() {
        #expect(
            ConfigInvocation.operatorArguments(installation: "acme", userID: "user-1")
                == ["config", "operator", "--installation", "acme", "user-1"]
        )
    }

    @Test("removeInstallationArguments passes the name as the one positional")
    func removeInstallationArgumentsVector() {
        #expect(
            ConfigInvocation.removeInstallationArguments(name: "acme")
                == ["config", "remove-installation", "acme"]
        )
    }
}
