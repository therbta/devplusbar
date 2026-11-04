import Foundation
import Defaults

extension Defaults.Keys {
    static let notifyClaudeCap = Key<Bool>("notifyClaudeCap", default: true)
    /// Warnings already given this week: "<week start>#75", "#90", "#early".
    static let claudeCapAlerts = Key<[String]>("claudeCapAlerts", default: [])
}

/// Says when this week's Claude Code use crosses 75% and 90% of the learned cap, and when the
/// week's pace runs out before the reset. Each warning is given once a week.
///
/// The panel already shows the same numbers; this is for the hours it is closed. Crossing two
/// marks between scans gives one warning, about the higher one.
enum ClaudeCapWatch {
    static let thresholds = [75, 90]

    static func check(
        given: [String],
        used: Int,
        cap: Int?,
        week: DateInterval?,
        stopped: Bool,
        now: Date = Date()
    ) -> (notice: BarNotice?, given: [String]) {
        guard let week else { return (nil, given) }
        let prefix = "\(Int(week.start.timeIntervalSince1970))#"
        // Last week's warnings are forgotten with last week.
        let current = given.filter { $0.hasPrefix(prefix) }
        // Being stopped is its own message, from Claude Code itself.
        guard let cap, cap > 0, used > 0, !stopped else { return (nil, current) }

        let share = Double(used) / Double(cap)
        let crossed = thresholds.filter { share * 100 >= Double($0) }
        let newMarks = crossed.filter { !current.contains(prefix + "\($0)") }
        let runsOut = used < cap ? ClaudeLimits.runsOut(used: used, cap: cap, week: week, now: now) : nil
        let newEarly = runsOut != nil && !current.contains(prefix + "early")
        // A mark is only news going up: every lower mark counts as given with it.
        let next = current + crossed.map { prefix + "\($0)" }.filter { !current.contains($0) }
            + (newEarly ? [prefix + "early"] : [])
        guard !newMarks.isEmpty || newEarly else { return (nil, next) }

        let percent = min(Int((share * 100).rounded(.down)), 100)
        let title: String, detail: String
        if let runsOut, newMarks.isEmpty {
            title = "On pace to run out \(when(runsOut))"
            detail = "\(percent)% of this week's limit used, \(early(runsOut, week))."
        } else {
            title = "\(percent)% of this week's limit used"
            detail = runsOut.map { "At this pace you run out \(when($0)), \(early($0, week))." }
                ?? "Your pace lasts to the reset \(ClaudeLimits.dayPart(week.end))."
        }
        let mark = newMarks.max().map(String.init) ?? "early"
        let notice = BarNotice(id: "claude-cap-\(prefix)\(mark)", tone: .warning, symbol: "gauge.with.dots.needle.67percent",
                               heading: "Claude Code · weekly limit", title: title, detail: detail,
                               mode: .ai, sticky: percent >= 90 || runsOut != nil)
        return (notice, next)
    }

    /// "Friday around 5:00 PM", or "17:00" where the clock is 24-hour. A bare hour read as
    /// "around 17" in the running app.
    static func when(_ date: Date) -> String {
        let hour = Calendar.current.dateInterval(of: .hour, for: date.addingTimeInterval(1800))?.start ?? date
        return "\(date.formatted(.dateTime.weekday(.wide))) around \(hour.formatted(date: .omitted, time: .shortened))"
    }

    /// "about 4 hours before the reset", "2 days before the reset".
    static func early(_ runsOut: Date, _ week: DateInterval) -> String {
        let gap = week.end.timeIntervalSince(runsOut)
        if gap < 2 * 3600 { return "just before the reset" }
        if gap < 48 * 3600 { return "about \(Int((gap / 3600).rounded())) hours before the reset" }
        return "\(Int((gap / 86_400).rounded())) days before the reset"
    }
}
