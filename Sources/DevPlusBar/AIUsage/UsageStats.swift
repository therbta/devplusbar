import Foundation

/// Numbers for the AI side. Pure.
struct UsageStats: Sendable {
    /// Claude's plan limit runs in 5-hour windows that start with the first message after the
    /// previous window ended.
    static let windowLength: TimeInterval = 5 * 3600

    struct Window: Sendable, Hashable {
        let start: Date
        var end: Date { start.addingTimeInterval(UsageStats.windowLength) }
        let tokens: Int
        let messages: Int
    }

    struct Slice: Sendable, Hashable, Identifiable {
        let name: String
        let tokens: Int
        let cacheRead: Int
        var id: String { name }
    }

    struct Day: Sendable, Hashable, Identifiable {
        let start: Date
        let tool: UsageTool
        let tokens: Int
        var id: String { "\(tool.rawValue)-\(start.timeIntervalSince1970)" }
    }

    let window: Window?
    /// The largest 5-hour window of the last 7 days, the yardstick when no cap is set.
    let peakWindow: Int
    let today: [Slice]
    let week: [Slice]
    let projects: [Slice]
    let days: [Day]
    let todayTotal: Int
    let weekTotal: Int

    init(_ records: [UsageRecord], tool: UsageTool?, now: Date = Date(), calendar: Calendar = .current) {
        let list = records.filter { tool == nil || $0.tool == tool }.sorted { $0.date < $1.date }
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let dayStart = calendar.startOfDay(for: now)

        // Windows over Claude records only: Codex reports its own.
        var windows: [Window] = []
        var start: Date?, tokens = 0, messages = 0
        for r in records where r.tool == .claude && r.date <= now {
            if let s = start, r.date < s.addingTimeInterval(Self.windowLength) {
                tokens += r.tokens; messages += 1
            } else {
                if let s = start { windows.append(Window(start: s, tokens: tokens, messages: messages)) }
                start = r.date; tokens = r.tokens; messages = 1
            }
        }
        if let s = start { windows.append(Window(start: s, tokens: tokens, messages: messages)) }
        window = windows.last.flatMap { $0.end > now ? $0 : nil }
        peakWindow = windows.filter { $0.start >= weekStart }.map(\.tokens).max() ?? 0

        func slices(_ subset: [UsageRecord], by key: (UsageRecord) -> String) -> [Slice] {
            Dictionary(grouping: subset, by: key).map { name, group in
                Slice(name: name, tokens: group.reduce(0) { $0 + $1.tokens }, cacheRead: group.reduce(0) { $0 + $1.cacheRead })
            }.sorted { $0.tokens > $1.tokens }
        }
        let todays = list.filter { $0.date >= dayStart }
        let weeks = list.filter { $0.date >= weekStart }
        today = slices(todays, by: \.model)
        week = slices(weeks, by: \.model)
        projects = Array(slices(weeks, by: \.project).prefix(5))
        todayTotal = todays.reduce(0) { $0 + $1.tokens }
        weekTotal = weeks.reduce(0) { $0 + $1.tokens }

        var byDay: [String: Day] = [:]
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: offset, to: weekStart)!
            for t in UsageTool.allCases where tool == nil || tool == t {
                byDay["\(t.rawValue)-\(day.timeIntervalSince1970)"] = Day(start: day, tool: t, tokens: 0)
            }
        }
        for r in weeks {
            let day = calendar.startOfDay(for: r.date)
            let key = "\(r.tool.rawValue)-\(day.timeIntervalSince1970)"
            byDay[key] = Day(start: day, tool: r.tool, tokens: (byDay[key]?.tokens ?? 0) + r.tokens)
        }
        days = byDay.values.sorted { $0.start < $1.start }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: "\(n / 1000)k"
        case 1000...: String(format: "%.1fk", Double(n) / 1000)
        default: "\(n)"
        }
    }
}
