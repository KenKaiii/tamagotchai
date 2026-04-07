import Foundation

/// Result of parsing a schedule string.
struct ParsedSchedule {
    enum ScheduleType: String, Codable {
        case at
        case every
        case cron
    }

    let type: ScheduleType
    var schedule: String?
    var runAt: Date?
    var intervalSeconds: Int?
}

/// Parses human-readable schedule strings into structured schedule data.
/// Supports: bare durations ("30m", "2h"), "every 2h", "tomorrow 3pm",
/// "in 10 minutes", and 5-field cron expressions.
enum ScheduleParser {
    // MARK: - Public API

    /// Parse a schedule string and determine its type.
    static func parseSchedule(_ input: String) -> ParsedSchedule? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // "every 30m", "every 2h", "every 1d"
        if let parsed = parseEveryPattern(trimmed) {
            return parsed
        }

        // Bare duration: "30m", "2h", "1d" → one-shot
        if let parsed = parseBareDuration(trimmed) {
            return parsed
        }

        // Relative/specific datetime: "today 3pm", "tomorrow 9am", "in 10 minutes"
        if let atDate = parseDateTime(trimmed) {
            let patterns = [
                "^(today|tomorrow|in\\s+\\d|monday|tuesday|wednesday|thursday|friday|saturday|sunday)",
            ]
            for pattern in patterns
                where trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            {
                return ParsedSchedule(type: .at, runAt: atDate)
            }
        }

        // 5-field cron expression
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count == 5, validateCron(trimmed) {
            return ParsedSchedule(type: .cron, schedule: trimmed)
        }

        // Fallback: try as datetime
        if let atDate = parseDateTime(trimmed) {
            return ParsedSchedule(type: .at, runAt: atDate)
        }

        return nil
    }

    /// Parse a datetime string into a Date.
    static func parseDateTime(_ input: String) -> Date? {
        let now = Date()

        // "today 3pm", "tomorrow 9am", "monday 2pm"
        let relativePattern =
            #"^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#
        if let match = input.range(of: relativePattern, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(input[match])
            return parseRelativeDay(matched, from: now)
        }

        // "in 2 hours", "in 30 minutes", "in 3 days"
        let inPattern = #"^in\s+(\d+)\s*(hour|hr|minute|min|day|d)s?$"#
        if let match = input.range(of: inPattern, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(input[match])
            return parseInDuration(matched, from: now)
        }

        // Try ISO 8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: input), date > now {
            return date
        }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: input), date > now {
            return date
        }

        return nil
    }

    /// Calculate the next run time for a scheduled job.
    static func calculateNextRun(
        type: ParsedSchedule.ScheduleType,
        schedule: String?,
        runAt: Date?,
        intervalSeconds: Int?
    ) -> Date? {
        let now = Date()

        switch type {
        case .at:
            guard let runAt else { return nil }
            return runAt > now ? runAt : nil

        case .every:
            guard let intervalSeconds else { return nil }
            return now.addingTimeInterval(Double(intervalSeconds))

        case .cron:
            guard let schedule else { return nil }
            return nextCronRun(schedule: schedule, after: now)
        }
    }

    /// Check if a cron field spec matches a value.
    static func matchesCronField(_ spec: String, value: Int, min: Int, max: Int) -> Bool {
        if spec == "*" { return true }

        return spec.split(separator: ",").contains { part in
            let partStr = String(part)
            let components = partStr.split(separator: "/", maxSplits: 1)
            let rangeStr = String(components[0])
            let step = components.count > 1 ? Int(components[1]) ?? 1 : 1

            let start: Int
            let end: Int

            if rangeStr == "*" {
                start = min
                end = max
            } else if rangeStr.contains("-") {
                let rangeParts = rangeStr.split(separator: "-")
                start = Int(rangeParts[0]) ?? min
                end = Int(rangeParts[1]) ?? max
            } else {
                if components.count == 1 {
                    return value == (Int(rangeStr) ?? -1)
                }
                start = Int(rangeStr) ?? min
                end = max
            }

            guard value >= start, value <= end else { return false }
            return (value - start) % step == 0
        }
    }

    // MARK: - Private Helpers

    private static func parseEveryPattern(_ input: String) -> ParsedSchedule? {
        let pattern = #"^every\s+(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))
        else {
            return nil
        }

        guard let amountRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let amount = Int(input[amountRange])
        else {
            return nil
        }

        let unit = String(input[unitRange]).lowercased()
        let seconds = durationToSeconds(amount: amount, unit: unit)
        return ParsedSchedule(type: .every, intervalSeconds: seconds)
    }

    private static func parseBareDuration(_ input: String) -> ParsedSchedule? {
        let pattern = #"^(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))
        else {
            return nil
        }

        guard let amountRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let amount = Int(input[amountRange])
        else {
            return nil
        }

        let unit = String(input[unitRange]).lowercased()
        let seconds = durationToSeconds(amount: amount, unit: unit)
        let runAt = Date().addingTimeInterval(Double(seconds))
        return ParsedSchedule(type: .at, runAt: runAt)
    }

    private static func durationToSeconds(amount: Int, unit: String) -> Int {
        if unit.hasPrefix("m") { return amount * 60 }
        if unit.hasPrefix("h") { return amount * 3600 }
        return amount * 86400
    }

    private static func parseRelativeDay(_ input: String, from now: Date) -> Date? {
        let pattern =
            #"^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))
        else {
            return nil
        }

        guard let dayRange = Range(match.range(at: 1), in: input),
              let hourRange = Range(match.range(at: 2), in: input)
        else {
            return nil
        }

        let dayStr = String(input[dayRange]).lowercased()
        var hour = Int(input[hourRange]) ?? 0
        let minute = if match.range(at: 3).location != NSNotFound,
                        let minRange = Range(match.range(at: 3), in: input)
        {
            Int(input[minRange]) ?? 0
        } else {
            0
        }

        let ampm: String? = if match.range(at: 4).location != NSNotFound,
                               let ampmRange = Range(match.range(at: 4), in: input)
        {
            String(input[ampmRange]).lowercased()
        } else {
            nil
        }

        if ampm == "pm", hour < 12 { hour += 12 }
        if ampm == "am", hour == 12 { hour = 0 }

        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: now)

        switch dayStr {
        case "tomorrow":
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
                components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            }
        case "today":
            break
        default:
            let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            if let targetDay = days.firstIndex(of: dayStr) {
                let currentDay = calendar.component(.weekday, from: now) - 1
                var daysToAdd = targetDay - currentDay
                if daysToAdd <= 0 { daysToAdd += 7 }
                if let future = calendar.date(byAdding: .day, value: daysToAdd, to: now) {
                    components = calendar.dateComponents([.year, .month, .day], from: future)
                }
            }
        }

        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func parseInDuration(_ input: String, from now: Date) -> Date? {
        let pattern = #"^in\s+(\d+)\s*(hour|hr|minute|min|day|d)s?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input))
        else {
            return nil
        }

        guard let amountRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let amount = Int(input[amountRange])
        else {
            return nil
        }

        let unit = String(input[unitRange]).lowercased()
        let seconds: Int = if unit.hasPrefix("hour") || unit == "hr" {
            amount * 3600
        } else if unit.hasPrefix("min") {
            amount * 60
        } else {
            amount * 86400
        }

        return now.addingTimeInterval(Double(seconds))
    }

    /// Validate a 5-field cron expression.
    private static func validateCron(_ schedule: String) -> Bool {
        let parts = schedule.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 5 else { return false }

        let ranges = [
            (0, 59), // minute
            (0, 23), // hour
            (1, 31), // day
            (1, 12), // month
            (0, 7), // weekday
        ]

        for i in 0 ..< 5 {
            let part = String(parts[i])
            if part == "*" { continue }
            if part.contains("/") { continue }
            if part.contains("-") { continue }
            if part.contains(",") { continue }

            guard let num = Int(part), num >= ranges[i].0, num <= ranges[i].1 else {
                return false
            }
        }

        return true
    }

    /// Find the next time a cron expression matches, iterating minute-by-minute up to 48h.
    private static func nextCronRun(schedule: String, after now: Date) -> Date? {
        let parts = schedule.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else { return nil }

        let (minSpec, hourSpec, domSpec, monSpec, dowSpec) =
            (parts[0], parts[1], parts[2], parts[3], parts[4])

        var calendar = Calendar.current
        calendar.timeZone = .current
        var candidate = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        candidate = calendar.date(bySetting: .nanosecond, value: 0, of: candidate) ?? candidate
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate

        let maxTime = now.addingTimeInterval(48 * 3600)

        while candidate <= maxTime {
            let comps = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            let weekday = (comps.weekday! - 1) // Convert to 0-based (Sunday = 0)

            if matchesCronField(minSpec, value: comps.minute!, min: 0, max: 59),
               matchesCronField(hourSpec, value: comps.hour!, min: 0, max: 23),
               matchesCronField(domSpec, value: comps.day!, min: 1, max: 31),
               matchesCronField(monSpec, value: comps.month!, min: 1, max: 12),
               matchesCronField(dowSpec, value: weekday, min: 0, max: 6)
            {
                return candidate
            }

            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
        }

        return nil
    }
}
