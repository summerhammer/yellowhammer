import Config
import Repositories

extension ProjectConfiguration {
    /// What this Project's WIP Commits say. On the lenient load of `yh project remove`, a refused
    /// template and a refused `change_type` were already replaced by their defaults when the file was read.
    var wipCommit: WIPCommitMessage {
        WIPCommitMessage(template: wipCommitMessage, changeType: changeType, project: id.rawValue)
    }
}
