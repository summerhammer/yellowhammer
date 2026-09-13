import Domain

public struct EngineInvocation: Sendable {
    public let act: Act

    public init(act: Act) {
        self.act = act
    }

    public func run() async throws {
        throw EngineInvocationError.notImplemented(act)
    }
}

public enum EngineInvocationError: Error, Sendable, Equatable {
    case notImplemented(Act)
}

extension EngineInvocationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notImplemented(let act):
            return "Act '\(act.rawValue)' is not implemented"
        }
    }
}
