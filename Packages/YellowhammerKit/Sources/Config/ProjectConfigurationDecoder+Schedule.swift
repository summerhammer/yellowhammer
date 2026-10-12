import Domain

extension ProjectConfigurationDecoder {
    /// `[schedule]`: the Night's start and end and the build interval. A 24-hour window (equal start and
    /// end) is refused here, at load (Schedule Window Validity Ruling).
    func schedule(in root: TOMLTable) throws(ConfigurationError) -> Schedule {
        let defaults = Schedule()
        guard let value = root["schedule"] else { return defaults }
        let table = try decoding.table(value, key: "schedule")
        try decoding.rejectUnknownKeys(
            in: table, path: "schedule", allowed: ["night_start", "night_end", "build_every_minutes"]
        )
        let schedule = Schedule(
            nightStart: try timeOfDay("night_start", in: table) ?? defaults.nightStart,
            nightEnd: try timeOfDay("night_end", in: table) ?? defaults.nightEnd,
            buildEveryMinutes: try decoding.positiveInteger("build_every_minutes", in: table, path: "schedule")
                ?? defaults.buildEveryMinutes
        )
        guard schedule.nightStart != schedule.nightEnd else {
            let line = table["night_end"]?.line ?? table.line
            throw decoding.error(
                line: line, key: "schedule.night_end", .twentyFourHourNightWindow(schedule.nightEnd.description)
            )
        }
        return schedule
    }

    func timeOfDay(_ key: String, in table: TOMLTable) throws(ConfigurationError) -> TimeOfDay? {
        guard let string = try decoding.optionalString(key, in: table, path: "schedule") else { return nil }
        guard let time = TimeOfDay(string) else {
            let line = table[key]?.line ?? table.line
            throw decoding.error(line: line, key: "schedule.\(key)", .invalidTimeOfDay(string))
        }
        return time
    }
}
