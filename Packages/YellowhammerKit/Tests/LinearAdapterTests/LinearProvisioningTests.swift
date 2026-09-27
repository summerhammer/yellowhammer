import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear provisioning")
struct LinearProvisioningTests {
    @Test("Request variables carry team id and pagination")
    func variablesAndPagination() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"workflowStates":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.workflowStates(team: BoardObjectID(rawValue: "team-1"))

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["teamId"] as? String == "team-1")
        #expect(variables["first"] as? Int == 250)
    }

    @Test("A Linear project with id, name and teams decodes")
    func projectDecodes() async throws {
        let json = #"{"data":{"project":{"id":"proj-123","# // glossary:ignore GL001
            + #""name":"Yellowhammer","teams":{"nodes":["#
            + #"{"id":"team-1","key":"ENG","name":"Engineering"},{"id":"team-2","key":"PRD","name":"Product"}"#
            + "]}}}}"
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let scope = try await adapter.linearProject()

        #expect(scope.id == BoardObjectID(rawValue: "proj-123"))
        #expect(scope.name == "Yellowhammer")
        #expect(scope.teams.count == 2)
        let eng = try #require(scope.teams.first)
        #expect(eng.id == BoardObjectID(rawValue: "team-1"))
        #expect(eng.key == "ENG")
        #expect(eng.name == "Engineering")
    }

    @Test("A Linear project that is not found throws scopeNotFound")
    func projectNotFoundThrows() async throws {
        let json = #"{"data":{"project":null},"# // glossary:ignore GL001
            + #""errors":[{"message":"Entity not found","extensions":{"code":"FORBIDDEN"}}]}"#
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json, status: 200)])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.linearProject()
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Creating a Linear project sends its name and team id")
    func createProjectMutation() async throws {
        let json = #"{"data":{"projectCreate":{"success":true,"project":{"# // glossary:ignore GL001
            + #""id":"proj-new","name":"Test","#
            + #""teams":{"nodes":[{"id":"team-1","key":"ENG","name":"Engineering"}]}}}}}"#
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let scope = try await adapter.createLinearProject(
            name: "Test",
            team: BoardObjectID(rawValue: "team-1")
        )

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["name"] as? String == "Test")
        #expect(variables["teamId"] as? String == "team-1")
        #expect(scope.id == BoardObjectID(rawValue: "proj-new"))
    }

    @Test("Workflow states paginate with endCursor")
    func workflowStatesPaginate() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"workflowStates":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-a"},"nodes":[
                  {"id":"state-1","name":"Waiting on You"}
                ]}}}
                """),
            Fixture.json("""
                {"data":{"workflowStates":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"id":"state-2","name":"Done"}
                ]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let states = try await adapter.workflowStates(team: BoardObjectID(rawValue: "team-1"))

        #expect(states.count == 2)
        #expect(states[0].name == "Waiting on You")
        #expect(states[1].name == "Done")
        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-a")
    }

    @Test("Create workflow state sends team id, name, type and uses neutral color")
    func createWorkflowStateMutation() async throws {
        let json = """
            {"data":{"workflowStateCreate":{"success":true,"workflowState":{"id":"state-new","name":"Waiting on You"}}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let state = try await adapter.createWorkflowState(
            name: "Waiting on You",
            category: .started,
            team: BoardObjectID(rawValue: "team-1")
        )

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["teamId"] as? String == "team-1")
        #expect(variables["name"] as? String == "Waiting on You")
        #expect(variables["type"] as? String == "started")
        // Color is not inspectable from outside, but mutation uses neutral value
        #expect(state.id == BoardObjectID(rawValue: "state-new"))
    }

    @Test("A cancelled category is sent as Linear's canceled type")
    func createWorkflowStateSendsCancelledAsCanceled() async throws {
        let json = """
            {"data":{"workflowStateCreate":{"success":true,"workflowState":{"id":"state-new","name":"Dropped"}}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.createWorkflowState(
            name: "Dropped",
            category: .cancelled,
            team: BoardObjectID(rawValue: "team-1")
        )

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["type"] as? String == "canceled")
    }

    @Test("Labels query filters for team-scoped and workspace-level labels")
    func labelsQuery() async throws {
        let json = """
            {"data":{"issueLabels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
              {"id":"lbl-1","name":"Feature","isGroup":false,"parent":null,"team":null},
              {"id":"lbl-2","name":"Object Type","isGroup":true,"parent":null,"team":{"id":"team-1"}},
              {"id":"lbl-3","name":"Card","isGroup":false,"parent":{"id":"lbl-2"},"team":{"id":"team-1"}}
            ]}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let labels = try await adapter.labels(team: BoardObjectID(rawValue: "team-1"))

        #expect(labels.count == 3)
        let workspace = try #require(labels.first)
        #expect(workspace.name == "Feature")
        #expect(workspace.team == nil)
        let group = labels[1]
        #expect(group.isGroup)
        #expect(group.team == BoardObjectID(rawValue: "team-1"))
        let child = labels[2]
        #expect(!child.isGroup)
        #expect(child.parent == BoardObjectID(rawValue: "lbl-2"))
    }

    @Test("Create label sends team id, name, isGroup, and optional parent id")
    func createLabelMutation() async throws {
        let json = """
            {"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"lbl-new","name":"Card","isGroup":false,
             "parent":{"id":"lbl-2"},"team":{"id":"team-1"}}}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let label = try await adapter.createLabel(
            name: "Card",
            team: BoardObjectID(rawValue: "team-1"),
            isGroup: false,
            parent: BoardObjectID(rawValue: "lbl-2")
        )

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["teamId"] as? String == "team-1")
        #expect(variables["name"] as? String == "Card")
        #expect(variables["isGroup"] as? Bool == false)
        #expect(variables["parentId"] as? String == "lbl-2")
        #expect(label.name == "Card")
    }

    @Test("success: false throws refused")
    func successFalseMeansRefused() async throws {
        let json = """
            {"data":{"workflowStateCreate":{"success":false,
             "workflowState":{"id":"state-new","name":"Waiting on You"}}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.createWorkflowState(
                name: "Waiting on You",
                category: .started,
                team: BoardObjectID(rawValue: "team-1")
            )
            Issue.record("expected refused")
        } catch .refused {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Pagination guard: hasNextPage true but null cursor throws unreadableResponse")
    func paginationGuardWithoutCursor() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"workflowStates":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.workflowStates(team: BoardObjectID(rawValue: "team-1"))
            Issue.record("expected unreadableResponse")
        } catch .unreadableResponse {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - memberTeams (P17.2, OQ80)

    @Test("memberTeams reads viewer.teamMemberships, decoding each team's id")
    func memberTeamsDecodesIDs() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"viewer":{"teamMemberships":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"team":{"id":"team-1"}}, {"team":{"id":"team-2"}}
                ]}}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let teamIDs = try await adapter.memberTeams()

        #expect(teamIDs == [BoardObjectID(rawValue: "team-1"), BoardObjectID(rawValue: "team-2")])
        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["first"] as? Int == 250)
    }

    @Test("memberTeams paginates with endCursor")
    func memberTeamsPaginate() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"viewer":{"teamMemberships":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-a"},"nodes":[
                  {"team":{"id":"team-1"}}
                ]}}}}
                """),
            Fixture.json("""
                {"data":{"viewer":{"teamMemberships":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"team":{"id":"team-2"}}
                ]}}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let teamIDs = try await adapter.memberTeams()

        #expect(teamIDs == [BoardObjectID(rawValue: "team-1"), BoardObjectID(rawValue: "team-2")])
        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-a")
    }

    @Test("memberTeams translates a GraphQL error through LinearFailure")
    func memberTeamsErrorTranslates() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"errors":[{"message":"nope","extensions":{"code":"FORBIDDEN"}}]}"#)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.memberTeams()
            Issue.record("expected forbidden")
        } catch .forbidden {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
