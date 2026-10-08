import Domain
import Testing

struct ConfigInvocationTests {
    @Test("operatorArguments always passes --board-connection before the user id")
    func operatorArgumentsVector() {
        #expect(
            ConfigInvocation.operatorArguments(boardConnection: "acme", userID: "user-1")
                == ["config", "operator", "--board-connection", "acme", "user-1"]
        )
    }

    @Test("removeBoardConnectionArguments passes the name as the one positional")
    func removeInstallationArgumentsVector() {
        #expect(
            ConfigInvocation.removeBoardConnectionArguments(name: "acme")
                == ["config", "remove-board-connection", "acme"]
        )
    }

    @Test("removeBoardConnectionArguments with orphanProjects passes --orphan-projects --yes")
    func removeInstallationOrphanVector() {
        #expect(
            ConfigInvocation.removeBoardConnectionArguments(name: "acme", orphanProjects: true)
                == ["config", "remove-board-connection", "acme", "--orphan-projects", "--yes"]
        )
        #expect(
            ConfigInvocation.removeBoardConnectionArguments(name: "acme", orphanProjects: false)
                == ["config", "remove-board-connection", "acme"]
        )
    }

    @Test("removeCodeHostingConnectionArguments passes the name as the one positional and no override")
    func removeCodeHostingConnectionVector() {
        #expect(
            ConfigInvocation.removeCodeHostingConnectionArguments(name: "gh")
                == ["config", "remove-code-hosting-connection", "gh"]
        )
    }
}
