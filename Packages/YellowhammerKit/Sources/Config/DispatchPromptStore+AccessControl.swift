import Darwin
import Foundation

/// Extended ACL checks. POSIX owner and mode bits alone do not prove a path is current-user-only:
/// an ACL entry can grant another user access even on a 0700 directory or a 0600 file.
extension DispatchPromptStore {
    /// Whether the path carries any extended ACL entry. `nil` means the ACL could not be read.
    static func hasExtendedACL(path: String) -> Bool? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? false : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return aclHasEntries(acl)
    }

    /// Removes every extended ACL entry from a directory, then verifies none remain.
    static func clearExtendedACL(path: String) -> Result<Void, RestrictionError> {
        guard let present = hasExtendedACL(path: path) else {
            return .failure(RestrictionError(message: "could not read the ACL of \(path): \(errnoText())"))
        }
        guard present else { return .success(()) }
        guard let empty = acl_init(0) else {
            return .failure(RestrictionError(message: "could not allocate an empty ACL: \(errnoText())"))
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_link_np(path, ACL_TYPE_EXTENDED, empty) != 0 {
            return .failure(RestrictionError(message: "could not remove the ACL of \(path): \(errnoText())"))
        }
        guard hasExtendedACL(path: path) == false else {
            return .failure(RestrictionError(message: "ACL entries remain on \(path) after removal"))
        }
        return .success(())
    }

    /// Removes every extended ACL entry from an open file, then verifies none remain.
    static func clearExtendedACL(fd: Int32) -> Result<Void, RestrictionError> {
        guard let present = hasExtendedACL(fd: fd) else {
            return .failure(RestrictionError(message: "could not read the ACL of the temporary file: \(errnoText())"))
        }
        guard present else { return .success(()) }
        guard let empty = acl_init(0) else {
            return .failure(RestrictionError(message: "could not allocate an empty ACL: \(errnoText())"))
        }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED) != 0 {
            return .failure(
                RestrictionError(message: "could not remove the ACL of the temporary file: \(errnoText())")
            )
        }
        guard hasExtendedACL(fd: fd) == false else {
            return .failure(RestrictionError(message: "ACL entries remain on the temporary file after removal"))
        }
        return .success(())
    }

    private static func hasExtendedACL(fd: Int32) -> Bool? {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? false : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return aclHasEntries(acl)
    }

    private static func aclHasEntries(_ acl: acl_t) -> Bool {
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
