import Config
import Domain
import Engine

extension Setup {
    /// Step 3, immediately after authorization. Setup does not finish without the Operator identity.
    /// Nothing after this step runs if it throws (no Project file is written, no provisioning happens).
    /// Writes the file only when the value changes, re-parsing the result to confirm it is still valid
    /// before writing.
    func setOperatorIdentity(
        machine: inout MachineConfiguration, installation: LinearInstallation, members: [BoardMember]
    ) throws {
        let candidates = OperatorIdentity.candidates(from: members)
        let chosen = try resolveOperatorID(
            candidates: candidates, members: members, configured: installation.operatorIdentity
        )

        if chosen != installation.operatorIdentity {
            try writeOperatorIdentity(chosen, installation: installation.name)
        }
        if let index = machine.linearInstallations.firstIndex(where: { $0.name == installation.name }) {
            machine.linearInstallations[index].operatorIdentity = chosen
        }
        output("Operator: \(chosen.rawValue)")
    }

    private func resolveOperatorID(
        candidates: [BoardMember], members: [BoardMember], configured: BoardObjectID?
    ) throws -> BoardObjectID {
        if let requested = options.operatorID {
            if let candidate = candidates.first(where: { $0.id == requested }) {
                return candidate.id
            }
            throw SetupError(operatorExclusionMessage(id: requested, members: members))
        }
        if let configured, candidates.contains(where: { $0.id == configured }) {
            return configured
        }
        guard isInteractive, !candidates.isEmpty else {
            throw SetupError(noOperatorMessage(candidates: candidates))
        }
        if let configured {
            output("the configured Operator identity \(configured.rawValue) is no longer a candidate")
        }
        return try askOperator(candidates: candidates)
    }

    /// Nothing is preselected: an empty, non-numeric or out-of-range answer re-asks; EOF cancels.
    private func askOperator(candidates: [BoardMember]) throws -> BoardObjectID {
        for (index, candidate) in candidates.enumerated() {
            output("\(index + 1)) \(candidate.displayName) (\(candidate.name))")
        }
        while true {
            guard let line = console.ask("Operator identity (number): ") else {
                throw SetupError("setup was cancelled")
            }
            guard let number = Int(line.trimmingCharacters(in: .whitespaces)),
                  (1...candidates.count).contains(number)
            else {
                continue
            }
            return candidates[number - 1].id
        }
    }

    private func operatorExclusionMessage(id: BoardObjectID, members: [BoardMember]) -> String {
        guard let member = members.first(where: { $0.id == id }) else {
            return "\(id.rawValue) is not a workspace member"
        }
        let reason = !member.isActive ? "deactivated"
            : member.isApp ? "an app"
            : member.isSelf ? "Yellowhammer's own identity" : "not a candidate"
        return "\(id.rawValue) is not an Operator candidate: \(reason)"
    }

    private func noOperatorMessage(candidates: [BoardMember]) -> String {
        guard !candidates.isEmpty else {
            return "Setup does not finish without the Operator identity; the workspace has no "
                + "active human members to offer"
        }
        let listing = candidates.map { "\($0.id.rawValue)  \($0.displayName) (\($0.name))" }
            .joined(separator: "\n")
        return "Setup does not finish without the Operator identity. Candidates:\n\(listing)\n"
            + "Pass --operator <id>."
    }

    private func writeOperatorIdentity(_ id: BoardObjectID, installation name: String) throws {
        let path = machineFileURL.path(percentEncoded: false)
        let text: String
        do {
            text = try String(contentsOf: machineFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(path): \(error)")
        }
        let updated = MachineConfiguration.settingOperator(id, installation: name, inFileText: text)
        guard updated != text else {
            throw SetupError("\(path) has no [board.linear.installations.\(name)] to hold the Operator identity")
        }
        do {
            _ = try MachineConfiguration.parse(updated, file: path)
        } catch {
            throw SetupError("could not set the Operator identity: \(error)")
        }
        do {
            try updated.write(to: machineFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
    }
}
