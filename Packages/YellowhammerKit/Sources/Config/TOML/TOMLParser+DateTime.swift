extension TOMLParser {
    /// Whether the token is an offset or local date-time, a local date or a local time. Returns false
    /// when it does not have that shape; throws when it does but a field is out of range.
    func dateTime(_ token: String) throws(ConfigurationError) -> Bool {
        let dateTime = #/
            ([0-9]{4}) - ([0-9]{2}) - ([0-9]{2})
            [Tt\x20]
            ([0-9]{2}) : ([0-9]{2}) : ([0-9]{2}) (?: \. [0-9]+ )?
            (?: [Zz] | [+\-] ([0-9]{2}) : ([0-9]{2}) )?
            /#
        let valid: Bool
        if let match = token.wholeMatch(of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})/#) {
            valid = Self.isValidDate(year: match.1, month: match.2, day: match.3)
        } else if let match = token.wholeMatch(of: #/([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?/#) {
            valid = Self.isValidTime(hour: match.1, minute: match.2, second: match.3)
        } else if let match = token.wholeMatch(of: dateTime) {
            valid = Self.isValidDate(year: match.1, month: match.2, day: match.3)
                && Self.isValidTime(hour: match.4, minute: match.5, second: match.6)
                && Self.isValidOffset(hour: match.7, minute: match.8)
        } else {
            return false
        }
        guard valid else {
            throw syntax("date-time '\(token)' is out of range")
        }
        return true
    }

    private static func isValidDate(year: Substring, month: Substring, day: Substring) -> Bool {
        guard let year = Int(year), let month = Int(month), let day = Int(day), (1...12).contains(month) else {
            return false
        }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(day)
    }

    private static func isValidTime(hour: Substring, minute: Substring, second: Substring) -> Bool {
        guard let hour = Int(hour), let minute = Int(minute), let second = Int(second) else {
            return false
        }
        return hour <= 23 && minute <= 59 && second <= 60
    }

    private static func isValidOffset(hour: Substring?, minute: Substring?) -> Bool {
        guard let hour, let minute else { return true }
        guard let hour = Int(hour), let minute = Int(minute) else { return false }
        return hour <= 23 && minute <= 59
    }
}
