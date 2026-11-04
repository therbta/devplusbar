import Foundation
import Defaults

extension Defaults.Keys {
    /// Tokens a Claude 5-hour window may hold, for the ring; 0 = compare with your own peak.
    static let claudeWindowCap = Key<Int>("claudeWindowCap", default: 0)
    static let showAIUsage = Key<Bool>("showAIUsage", default: true)
    /// Plans differ: some cap every 5 hours, some only weekly. A 5-hour limit hit turns it on.
    static let claudeHasFiveHourLimit = Key<Bool>("claudeHasFiveHourLimit", default: true)
    /// What the limit hits taught, kept after the logs that taught it are pruned.
    static let claudeLimits = Key<String>("claudeLimits", default: "")
}

/// Rescans the local session logs once a minute, off the main thread.
@MainActor
final class AIMonitor: ObservableObject {
    static let shared = AIMonitor()
    static let interval: Duration = .seconds(60)

    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var limits: ClaudeLimits = {
        (try? JSONDecoder().decode(ClaudeLimits.self, from: Data(Defaults[.claudeLimits].utf8))) ?? ClaudeLimits()
    }()
    var onChange: (() -> Void)?
    private let scanner = UsageScanner()
    private var loop: Task<Void, Never>?
    private var scanning = false
    private var deepReadDone: Set<Date> = []

    /// After a plan change: start over and learn from the next limit hit.
    func forgetLimits() {
        // Hits from before the change would teach the old plan's cap again.
        limits = ClaudeLimits(ignoreBefore: Date())
        Defaults[.claudeLimits] = ""
        deepReadDone = []
    }

    var hasData: Bool { !snapshot.records.isEmpty || snapshot.codexLimits != nil }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// For screenshots: a scan's result without the loop.
    func load(_ fresh: UsageSnapshot) {
        snapshot = fresh
        limits = limits.learning(from: fresh.claudeHits, records: fresh.records)
    }

    /// Sets the cap so this week reads as the percentage claude.ai shows.
    func match(officialPercent percent: Int) {
        let now = Date()
        let week = limits.currentWeek(now: now) ?? DateInterval(start: now.addingTimeInterval(-ClaudeLimits.week), end: now)
        let records = snapshot.records.filter { $0.tool == .claude && week.contains($0.date) }
        let used = records.reduce(0) { $0 + $1.tokens }
        let next = limits.calibrating(used: used, percent: percent, weekRecords: records, now: now)
        guard next != limits else { return }
        limits = next
        if let data = try? JSONEncoder().encode(next) { Defaults[.claudeLimits] = String(decoding: data, as: UTF8.self) }
    }

    func scanNow() async {
        guard Defaults[.showAIUsage], !scanning else { return }
        scanning = true
        let scanner = scanner
        let fresh = await Task.detached(priority: .utility) { scanner.scan() }.value
        scanning = false
        let hadData = hasData
        snapshot = fresh
        let hits = fresh.claudeHits.filter { $0.at > (limits.ignoreBefore ?? .distantPast) }
        // Being stopped by a 5-hour limit proves the plan has one.
        if fresh.claudeHits.contains(where: { $0.kind == .fiveHour }) { Defaults[.claudeHasFiveHourLimit] = true }
        var next = limits.learning(from: hits, records: fresh.records)
        // Logs kept for 15 days may not reach back to the start of a hit's week: read that
        // stretch once, apart from the rolling scan.
        if next.weeklyCap == nil,
           let hit = hits.filter({ $0.kind == .sevenDay }).max(by: { $0.at < $1.at }),
           !deepReadDone.contains(hit.resetsAt) {
            deepReadDone.insert(hit.resetsAt)
            let start = hit.resetsAt.addingTimeInterval(-ClaudeLimits.week)
            let week = await Task.detached(priority: .utility) { UsageScanner.claudeRecords(from: start, to: hit.at) }.value
            next = next.learningWeekly(from: hit, weekRecords: week)
        }
        if let week = next.currentWeek(now: Date()) {
            let used = fresh.records.filter { $0.tool == .claude && week.contains($0.date) }.reduce(0) { $0 + $1.tokens }
            next = next.raisingFloor(used: used, stopped: ClaudeLimits.active(fresh.claudeHits, now: Date()) != nil)
        }
        let learned = next
        if learned != limits {
            limits = learned
            if let data = try? JSONEncoder().encode(learned) { Defaults[.claudeLimits] = String(decoding: data, as: UTF8.self) }
        }
        if hadData != hasData { onChange?() }
        checkCap(fresh, now: Date())
    }

    /// Called with a warning about this week's Claude limit; see `ClaudeCapWatch`.
    var onCapNotice: ((BarNotice) -> Void)?

    private func checkCap(_ fresh: UsageSnapshot, now: Date) {
        guard Defaults[.notifyClaudeCap] else { return }
        let week = limits.currentWeek(now: now)
        let used = week.map { w in fresh.records.filter { $0.tool == .claude && w.contains($0.date) }.reduce(0) { $0 + $1.tokens } } ?? 0
        let result = ClaudeCapWatch.check(given: Defaults[.claudeCapAlerts], used: used, cap: limits.weeklyCap, week: week,
                                          stopped: ClaudeLimits.active(fresh.claudeHits, now: now)?.kind == .sevenDay, now: now)
        if result.given != Defaults[.claudeCapAlerts] { Defaults[.claudeCapAlerts] = result.given }
        if let notice = result.notice { onCapNotice?(notice) }
    }
}
