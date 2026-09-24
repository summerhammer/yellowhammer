import Foundation
import Testing

/// Shared by ``SetupScheduledJobsInstallTests`` and ``SetupScheduledJobsExportTests``.
func freshHomeDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(component: "yh-home-\(UUID().uuidString)", directoryHint: .isDirectory)
}

func freshExportDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(component: "yh-export-\(UUID().uuidString)", directoryHint: .isDirectory)
}

func decodePlist(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.xml
    return try #require(
        PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
    )
}
