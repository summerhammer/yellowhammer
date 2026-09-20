/// A dotted classification of a Card's work, such as `impl.boilerplate`.
///
/// `*` is the root Kind, ``Kind/any``, and has no segments.
public struct Kind: Hashable, Sendable {
    public static let any = Kind(segments: [])

    /// The one Kind not read off a Card: the author Act resolves its model through the ordinary Routing
    /// Table under it (routing overview, "the author Act routes through the same table"). It is keyed
    /// with no Repo Role, so an entry for it applies to the author Act only as an any-Repo-Role entry.
    public static let authoring = Kind(segments: ["authoring"])

    public let segments: [String]

    private init(segments: [String]) {
        self.segments = segments
    }

    /// Accepts `*`, or dot-separated segments that are non-empty and contain neither whitespace nor `*`.
    public init?(_ string: String) {
        if string == "*" {
            self = .any
            return
        }
        let segments = string.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let valid = segments.allSatisfy { segment in
            !segment.isEmpty && !segment.contains("*") && !segment.contains(where: \.isWhitespace)
        }
        guard valid else { return nil }
        self.init(segments: segments)
    }

    /// How specific this Kind is: its segment count. `*` has none.
    public var specificity: Int { segments.count }

    /// True when this Kind's segments lead `other`'s, so a Routing Entry for this Kind applies to a
    /// Card of `other`. `*` is a prefix of every Kind, and every Kind is a prefix of itself. Resolution
    /// picks the longest such prefix (routing/resolve-a-route-for-a-card).
    public func isPrefix(of other: Kind) -> Bool {
        other.segments.starts(with: segments)
    }

    /// True when this Kind is ``authoring`` or sits under it: reserved for the author Act, so a Card may
    /// never carry it and a Routing Entry for it can never name a Repo Role.
    public var isReservedForAuthoring: Bool {
        Kind.authoring.isPrefix(of: self)
    }
}

extension Kind: CustomStringConvertible {
    public var description: String {
        segments.isEmpty ? "*" : segments.joined(separator: ".")
    }
}
