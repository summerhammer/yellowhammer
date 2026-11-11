import Domain
import Foundation

extension ClaudeCodeAdapter {
    /// The `customTitle` of every `custom-title` record in the session's transcript, in file order: the
    /// `--name` a fresh run gave it, then each resume's. Nil when the transcript is not found or unreadable;
    /// empty when it holds no such record.
    public func sessionTitles(of session: CLISession, dispatch: CLIDispatch) -> [String]? {
        guard let url = transcriptURL(for: session.rawValue, dispatch: dispatch),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return Self.customTitles(in: data)
    }

    static func customTitles(in data: Data) -> [String] {
        data.split(separator: 0x0A).compactMap { bytes in
            guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  object["type"] as? String == "custom-title"
            else {
                return nil
            }
            return object["customTitle"] as? String
        }
    }
}
