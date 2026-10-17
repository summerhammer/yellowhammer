import Foundation

/// A drafted Work Card or Feature Card whose description composes past the description budget, read back
/// from the rejection text `AuthoringDescriptionBudget` words. The wording is the only carrier across the
/// Journal, so ``marker`` is shared by the writer and this reader.
public struct DescriptionBudgetOverrun: Equatable, Sendable {
    /// The text between the composed size and the budget in the rejection wording.
    public static let marker = "over the description budget of"

    public enum Subject: String, Sendable {
        case workCard = "Work Card"
        case featureCard = "Feature Card"
    }

    public let subject: Subject
    public let title: String
    public let repository: String?
    public let size: Int
    public let budget: Int

    public init(subject: Subject, title: String, repository: String?, size: Int, budget: Int) {
        self.subject = subject
        self.title = title
        self.repository = repository
        self.size = size
        self.budget = budget
    }

    /// The first overrun found anywhere in `reason`, or nil when it holds none.
    public static func parse(_ reason: String) -> DescriptionBudgetOverrun? {
        let number = #"(\d[\d,]*)"#
        let pattern = #"(Work|Feature) Card "([^"]*)"(?: \(([^)]*)\))? composes "#
            + number + #" [A-Za-z0-9- ]+?, "# + NSRegularExpression.escapedPattern(for: marker) + " " + number
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: reason).map { String(reason[$0]) }
        }
        guard let kind = group(1), let title = group(2),
            let size = group(4).flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) }),
            let budget = group(5).flatMap({ Int($0.replacingOccurrences(of: ",", with: "")) })
        else { return nil }
        return DescriptionBudgetOverrun(
            subject: kind == "Work" ? .workCard : .featureCard, title: title, repository: group(3),
            size: size, budget: budget
        )
    }

    /// `Work Card "T" (repo) is 12,153 of 10,000 description budget`.
    public var oneLine: String {
        let named = repository.map { " (\($0))" } ?? ""
        return "\(subject.rawValue) \"\(title)\"\(named) is \(Self.grouped(size)) of \(Self.grouped(budget)) "
            + "description budget"
    }

    /// The one line a Route's rejection reads as on the Night Card: the overrun's ``oneLine`` when one
    /// parses, else the text after the last `returned invalid output: `, else the reason; first line only.
    public static func oneLineReason(_ reason: String) -> String {
        let text: String
        if let overrun = parse(reason) {
            text = overrun.oneLine
        } else if let range = reason.range(of: "returned invalid output: ", options: .backwards) {
            text = String(reason[range.upperBound...])
        } else {
            text = reason
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    public static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
