import Config
import Domain
import Foundation

/// The two pieces `yh setup`'s Operator step and `yh config operator` share (spec
/// `install-the-linear-app`, OQ66): why a user id is refused as an Operator identity, and the
/// validated, atomic write of one App Installation's `operator` key.
enum OperatorIdentityEditing {
    /// Why `id` is not an Operator candidate among `members`: not a member, deactivated, an app, or
    /// Yellowhammer's own identity.
    static func exclusionMessage(id: BoardObjectID, members: [BoardMember]) -> String {
        guard let member = members.first(where: { $0.id == id }) else {
            return "\(id.rawValue) is not a workspace member"
        }
        let reason = !member.isActive ? "deactivated"
            : member.isApp ? "an app"
            : member.isSelf ? "Yellowhammer's own identity" : "not a candidate"
        return "\(id.rawValue) is not an Operator candidate: \(reason)"
    }

    /// Sets `operator` in `[board.linear.installations.<name>]` of the machine file, touching no other
    /// table. The edited text is re-parsed before it is written, and written atomically, so a refusal
    /// leaves the file as it was.
    static func write(_ id: BoardObjectID, installation name: String, machineFileURL: URL) throws {
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
