import Domain
import Foundation
import Testing

@Suite("DispatchPromptRecord and Domain types")
struct DispatchPromptRecordTests {
    @Test("PromptFamily raw values, diagnostic state, instructions acceptance, and default versions")
    func promptFamilyProperties() {
        for family in PromptFamily.allCases {
            // The verifier's text changed for OQ191 (it judges the commit its checkout is at).
            #expect(family.defaultVersion == (family == .verifier ? 2 : 1))
        }

        let productionFamilies: Set<PromptFamily> = [
            .selection, .breakdown, .architect, .worker, .reviewer, .verifier
        ]
        let diagnosticFamilies: Set<PromptFamily> = [
            .unattendedProbe, .sessionResumptionProbe, .routePreflight,
            .processContainmentProbe, .stateContainmentProbe
        ]

        #expect(productionFamilies.count + diagnosticFamilies.count == PromptFamily.allCases.count)

        for family in productionFamilies {
            #expect(!family.isDiagnostic)
            #expect(family.acceptsProjectInstructions)
        }

        for family in diagnosticFamilies {
            #expect(family.isDiagnostic)
            #expect(!family.acceptsProjectInstructions)
        }

        #expect(PromptFamily.unattendedProbe.rawValue == "unattended-probe")
        #expect(PromptFamily.sessionResumptionProbe.rawValue == "session-resumption-probe")
        #expect(PromptFamily.routePreflight.rawValue == "route-preflight")
        #expect(PromptFamily.processContainmentProbe.rawValue == "process-containment-probe")
        #expect(PromptFamily.stateContainmentProbe.rawValue == "state-containment-probe")

        for pass in RunPass.allCases {
            let family = PromptFamily(pass: pass)
            #expect(family != nil)
            #expect(family?.rawValue == pass.rawValue)
        }
    }

    @Test("DispatchProvenance scope accessor and fields")
    func provenanceScope() {
        let machineProv = DispatchProvenance(
            recordID: "UUID-1",
            family: .unattendedProbe,
            projectID: nil
        )
        #expect(machineProv.recordID == "uuid-1")
        #expect(machineProv.scope == .machine)

        let scopedProv = DispatchProvenance(
            recordID: "UUID-2",
            family: .worker,
            projectID: "proj-2",
            runID: "run-42",
            nightID: 101,
            featureIssueID: "feat-1",
            workCardIssueID: "card-2",
            cardID: 7,
            attemptID: 1,
            round: 2,
            routeTry: 3
        )
        #expect(scopedProv.recordID == "uuid-2")
        #expect(scopedProv.scope == .project(ProjectID(rawValue: "proj-2")!))
        #expect(scopedProv.nightID == 101)
        #expect(scopedProv.round == 2)
        #expect(scopedProv.routeTry == 3)
    }

    @Test("DispatchPromptRecord encode/decode round-trip with sorted keys and ISO-8601 dates")
    func recordEncodeDecodeRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = DispatchProvenance(
            recordID: "rec-12345",
            family: .worker,
            projectID: "proj-1",
            runID: "run-1",
            nightID: 1,
            featureIssueID: "F-1",
            workCardIssueID: "C-1",
            cardID: 10,
            attemptID: 2,
            round: 1,
            routeTry: 1
        )
        let record = DispatchPromptRecord(
            provenance: provenance,
            route: "claude-code/sonnet/high",
            pass: .worker,
            dispatchedAt: date,
            defaultVersion: 1,
            projectInstructions: .absent,
            session: .new,
            instruction: "Fix the bug",
            outputSchema: "{\"type\":\"object\"}",
            launch: .pending
        )

        let encoder = DispatchPromptRecord.makeJSONEncoder()
        let data = try encoder.encode(record)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        // Check sorted keys
        let keys = ["defaultVersion", "dispatchedAt", "id", "instruction", "launch", "outputSchema",
                    "pass", "projectInstructions", "provenance", "route", "session"]
        var lastIndex = jsonString.startIndex
        for key in keys {
            let keyQuote = "\"\(key)\""
            let range = try #require(jsonString.range(of: keyQuote, range: lastIndex..<jsonString.endIndex))
            lastIndex = range.upperBound
        }

        let decoder = DispatchPromptRecord.makeJSONDecoder()
        let decoded = try decoder.decode(DispatchPromptRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.id == "rec-12345")
    }

    @Test("DispatchPromptRecord round-trips with revision instructions and notLaunched state")
    func recordWithRevisionAndNotLaunched() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = DispatchProvenance(
            recordID: "rec-67890",
            family: .architect,
            projectID: "proj-2"
        )
        let record = DispatchPromptRecord(
            provenance: provenance,
            route: "claude-code/opus/high",
            pass: .architect,
            dispatchedAt: date,
            defaultVersion: 1,
            projectInstructions: .revision("rev-abc"),
            session: .resumed,
            instruction: "Plan the architecture",
            outputSchema: nil,
            launch: .notLaunched(cause: "process spawn failed")
        )

        let encoder = DispatchPromptRecord.makeJSONEncoder()
        let data = try encoder.encode(record)
        let decoder = DispatchPromptRecord.makeJSONDecoder()
        let decoded = try decoder.decode(DispatchPromptRecord.self, from: data)

        #expect(decoded == record)
        #expect(decoded.projectInstructions == .revision("rev-abc"))
        #expect(decoded.session == .resumed)
        #expect(decoded.outputSchema == nil)
        #expect(decoded.launch == .notLaunched(cause: "process spawn failed"))
    }

    @Test("DispatchPromptRecord retention and isExpired boundary at exactly 30 days")
    func retentionAndExpiryBoundary() {
        #expect(DispatchPromptRecord.retention == 30 * 24 * 60 * 60)
        let dispatchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let provenance = DispatchProvenance(recordID: "exp-1", family: .worker)
        let record = DispatchPromptRecord(
            provenance: provenance,
            route: "route/test/low",
            pass: .worker,
            dispatchedAt: dispatchDate,
            defaultVersion: 1,
            session: .new,
            instruction: "test",
            outputSchema: nil
        )

        let before30Days = dispatchDate.addingTimeInterval(30 * 24 * 60 * 60 - 1)
        #expect(!record.isExpired(at: before30Days))

        let exactly30Days = dispatchDate.addingTimeInterval(30 * 24 * 60 * 60)
        #expect(record.isExpired(at: exactly30Days))

        let after30Days = dispatchDate.addingTimeInterval(30 * 24 * 60 * 60 + 1)
        #expect(record.isExpired(at: after30Days))
    }
}
