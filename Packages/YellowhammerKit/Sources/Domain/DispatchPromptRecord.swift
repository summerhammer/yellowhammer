import Foundation

/// A captured dispatch prompt record containing the resolved instruction and schema supplied
/// to a CLI Adapter, along with its provenance and launch status.
public struct DispatchPromptRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provenance: DispatchProvenance
    public let route: String
    public let pass: RunPass
    public let dispatchedAt: Date
    public let defaultVersion: Int
    public let projectInstructions: ProjectInstructionsUse
    public let session: DispatchSession
    public let instruction: String
    public let outputSchema: String?
    public var launch: DispatchLaunch

    /// The retention limit: records older than 30 days are expired and never served.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public init(
        provenance: DispatchProvenance,
        route: String,
        pass: RunPass,
        dispatchedAt: Date,
        defaultVersion: Int,
        projectInstructions: ProjectInstructionsUse = .absent,
        session: DispatchSession,
        instruction: String,
        outputSchema: String?,
        launch: DispatchLaunch = .pending
    ) {
        self.id = provenance.recordID
        self.provenance = provenance
        self.route = route
        self.pass = pass
        self.dispatchedAt = dispatchedAt
        self.defaultVersion = defaultVersion
        self.projectInstructions = projectInstructions
        self.session = session
        self.instruction = instruction
        self.outputSchema = outputSchema
        self.launch = launch
    }

    public init(
        id: String,
        provenance: DispatchProvenance,
        route: String,
        pass: RunPass,
        dispatchedAt: Date,
        defaultVersion: Int,
        projectInstructions: ProjectInstructionsUse = .absent,
        session: DispatchSession,
        instruction: String,
        outputSchema: String?,
        launch: DispatchLaunch = .pending
    ) {
        self.id = id
        self.provenance = provenance
        self.route = route
        self.pass = pass
        self.dispatchedAt = dispatchedAt
        self.defaultVersion = defaultVersion
        self.projectInstructions = projectInstructions
        self.session = session
        self.instruction = instruction
        self.outputSchema = outputSchema
        self.launch = launch
    }

    /// Whether this record is expired at the given instant.
    public func isExpired(at date: Date) -> Bool {
        date.timeIntervalSince(dispatchedAt) >= Self.retention
    }

    /// Creates a JSONEncoder configured with sorted keys and ISO-8601 dates.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Creates a JSONDecoder configured for ISO-8601 dates.
    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Protocol for recording dispatch prompt records and updating their launch status.
public protocol DispatchPromptRecording: Sendable {
    func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture
    func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool
}

/// The outcome of looking up a prompt record by id.
public enum DispatchPromptLookup: Equatable, Sendable {
    case available(DispatchPromptRecord)
    case expired(dispatchedAt: Date)
    case deleted(deletedAt: Date)
    case missing
    case unreadable(cause: String)
}

/// One entry in a prompt store scope listing.
public struct DispatchPromptEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let lookup: DispatchPromptLookup

    public init(id: String, lookup: DispatchPromptLookup) {
        self.id = id
        self.lookup = lookup
    }
}

/// The result of deleting an individual prompt record.
public enum DispatchPromptDeletion: Equatable, Sendable {
    case deleted
    case alreadyMissing
    case failed(cause: String)
}

/// A tombstone representing a deleted prompt record on disk.
public struct DispatchPromptTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let dispatchedAt: Date
    public let deletedAt: Date
    /// The deleted record's run, when its provenance named one. Absent in older tombstones.
    public let runID: String?
    /// The deleted record's prompt family, when the record decoded. Absent in older tombstones.
    public let family: PromptFamily?

    public init(
        id: String,
        dispatchedAt: Date,
        deletedAt: Date,
        runID: String? = nil,
        family: PromptFamily? = nil
    ) {
        self.id = id
        self.dispatchedAt = dispatchedAt
        self.deletedAt = deletedAt
        self.runID = runID
        self.family = family
    }
}
