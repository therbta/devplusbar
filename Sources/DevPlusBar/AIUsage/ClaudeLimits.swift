import Foundation

/// Claude's plan limits, learned from the moments they stopped you.
///
/// Anthropic publishes no numbers, but each limit hit in the logs says which limit it was and
/// when it resets. The tokens used in that window up to the hit are, by definition, the cap in
/// the same units the meters count, so whatever Anthropic weighs, the meter agrees with it.
/// A weekly hit also fixes the week's boundary: every later week starts a multiple of 7 days
/// from its reset.
struct ClaudeLimits: Sendable, Equatable, Codable {
    var fiveHourCap: Int?
    var fiveHourLearnedAt: Date?
    var weeklyCap: Int?
    var weeklyLearnedAt: Date?
    /// A reset time of the weekly limit; weeks repeat from it.
    var weekAnchor: Date?
    /// The cap was raised because a week went past it without being stopped: the real cap is at
    /// least this, not exactly it.
    var weeklyCapIsFloor: Bool? = nil
    /// Share of tokens from the dominant model family when the cap was learned. Limits weigh
    /// models differently, so a different mix makes the meter an estimate.
    var mixAtLearn: [String: Double]? = nil
    /// Set by "Forget learned limits": older hits describe a plan that no longer applies.
    var ignoreBefore: Date? = nil
    /// When the cap was set from the percentage claude.ai showed, and that percentage.
    var calibratedAt: Date? = nil
    var calibratedPercent: Int? = nil

    static let week: TimeInterval = 7 * 86_400

    /// Folds in every hit; a newer hit replaces what an older one taught.
    func learning(from hits: [ClaudeLimitHit], records: [UsageRecord]) -> ClaudeLimits {
        var next = self
        let claude = records.filter { $0.tool == .claude }
        for hit in hits.sorted(by: { $0.at < $1.at }) {
            switch hit.kind {
            case .sevenDay:
                let start = hit.resetsAt.addingTimeInterval(-Self.week)
                let used = claude.filter { $0.date >= start && $0.date <= hit.at }.reduce(0) { $0 + $1.tokens }
                next.weekAnchor = hit.resetsAt
                // Only when the logs reach back to the week's start; otherwise the sum is short.
                if let first = claude.first?.date, first <= start.addingTimeInterval(3600), used > 0,
                   (next.weeklyLearnedAt ?? .distantPast) < hit.at {
                    next.weeklyCap = used
                    next.weeklyLearnedAt = hit.at
                    next.weeklyCapIsFloor = false
                    next.mixAtLearn = Self.mix(claude.filter { $0.date >= start && $0.date <= hit.at })
                }
                // A cap saved before the mix was recorded: add it from the same week.
                if next.weeklyLearnedAt == hit.at, next.mixAtLearn == nil,
                   let first = claude.first?.date, first <= start.addingTimeInterval(3600) {
                    next.mixAtLearn = Self.mix(claude.filter { $0.date >= start && $0.date <= hit.at })
                }
            case .fiveHour:
                let start = hit.resetsAt.addingTimeInterval(-UsageStats.windowLength)
                let used = claude.filter { $0.date >= start && $0.date <= hit.at }.reduce(0) { $0 + $1.tokens }
                if used > 0, (next.fiveHourLearnedAt ?? .distantPast) < hit.at {
                    next.fiveHourCap = used
                    next.fiveHourLearnedAt = hit.at
                }
            case .other:
                break
            }
        }
        return next
    }

    /// Learns the cap from a total read separately, when the kept logs did not reach the
    /// week's start (see `UsageScanner.claudeRecords(from:to:)`).
    func learningWeekly(from hit: ClaudeLimitHit, weekRecords: [UsageRecord]) -> ClaudeLimits {
        var next = self
        let used = weekRecords.reduce(0) { $0 + $1.tokens }
        guard used > 0, (weeklyLearnedAt ?? .distantPast) < hit.at else { return self }
        next.weekAnchor = hit.resetsAt
        next.weeklyCap = used
        next.weeklyLearnedAt = hit.at
        next.weeklyCapIsFloor = false
        next.mixAtLearn = Self.mix(weekRecords)
        return next
    }

    /// A week that went past the cap without a limit hit proves the cap is higher now (a plan
    /// change, or Anthropic raising it). The meter must never sit above 100% unstopped.
    func raisingFloor(used: Int, stopped: Bool) -> ClaudeLimits {
        guard !stopped, let cap = weeklyCap, used > cap else { return self }
        var next = self
        next.weeklyCap = used
        next.weeklyCapIsFloor = true
        return next
    }

    /// The cap that makes this week's tokens read as the percentage claude.ai shows. The official
    /// number is the truth: a cap learned from a limit hit only counts tokens logged on this Mac.
    func calibrating(used: Int, percent: Int, weekRecords: [UsageRecord], now: Date = Date()) -> ClaudeLimits {
        guard used > 0, (1...100).contains(percent) else { return self }
        var next = self
        next.weeklyCap = Int((Double(used) / (Double(percent) / 100)).rounded())
        next.weeklyCapIsFloor = false
        // Later than any hit already in the logs, so an older hit does not undo it; a new hit will.
        next.weeklyLearnedAt = now
        next.calibratedAt = now
        next.calibratedPercent = percent
        next.mixAtLearn = Self.mix(weekRecords)
        return next
    }

    /// When the week runs out at the pace of the week so far, the way claude.ai predicts it;
    /// nil when it lasts to the reset or too little of the week has passed to tell.
    static func runsOut(used: Int, cap: Int, week: DateInterval, now: Date = Date()) -> Date? {
        let elapsed = now.timeIntervalSince(week.start)
        guard elapsed > 6 * 3600, used > 0, cap > used else { return used >= cap && used > 0 ? now : nil }
        let at = now.addingTimeInterval(Double(cap - used) / (Double(used) / elapsed))
        return at < week.end ? at : nil
    }

    /// The share of the cap left at the reset, at the week's pace so far.
    static func leftAtReset(used: Int, cap: Int, week: DateInterval, now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(week.start)
        guard elapsed > 6 * 3600, cap > 0 else { return nil }
        return max(0, 1 - Double(used) / elapsed * week.duration / Double(cap))
    }

    /// "Thursday night", "Friday morning".
    static func dayPart(_ date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour < 5 ? "night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : "night"
        // Small hours belong to the night before.
        let day = hour < 5 ? date.addingTimeInterval(-6 * 3600) : date
        return "\(day.formatted(.dateTime.weekday(.wide))) \(part)"
    }

    /// Token share by model family: "opus", "sonnet", "haiku", or the model name.
    static func mix(_ records: [UsageRecord]) -> [String: Double] {
        let total = Double(records.reduce(0) { $0 + $1.tokens })
        guard total > 0 else { return [:] }
        var shares: [String: Double] = [:]
        for r in records { shares[family(r.model), default: 0] += Double(r.tokens) / total }
        return shares
    }

    static func family(_ model: String) -> String {
        for name in ["opus", "sonnet", "haiku", "fable"] where model.contains(name) { return name }
        return model
    }

    /// Limits weigh models differently; say so when this week's mix is not the one the cap
    /// was learned with.
    func mixNote(weekRecords: [UsageRecord]) -> String? {
        guard let learned = mixAtLearn, !learned.isEmpty else { return nil }
        let now = ClaudeLimits.mix(weekRecords)
        guard !now.isEmpty, ClaudeLimits.mixShift(learned, now) > 0.2 else { return nil }
        func describe(_ m: [String: Double]) -> String {
            m.sorted { $0.value > $1.value }.prefix(2).map { "\(Int(($0.value * 100).rounded()))% \($0.key)" }.joined(separator: ", ")
        }
        return "Estimate: this week is \(describe(now)); the cap was learned at \(describe(learned))"
    }

    /// The largest change in any family's share, 0…1.
    static func mixShift(_ a: [String: Double], _ b: [String: Double]) -> Double {
        Set(a.keys).union(b.keys).map { abs((a[$0] ?? 0) - (b[$0] ?? 0)) }.max() ?? 0
    }

    /// The weekly window `now` falls in, when a weekly reset has been seen.
    func currentWeek(now: Date) -> DateInterval? {
        guard let anchor = weekAnchor else { return nil }
        let periods = (now.timeIntervalSince(anchor) / Self.week).rounded(.down)
        let start = anchor.addingTimeInterval(periods * Self.week)
        return DateInterval(start: start, duration: Self.week)
    }

    /// A limit that is stopping you right now.
    static func active(_ hits: [ClaudeLimitHit], now: Date) -> ClaudeLimitHit? {
        hits.filter { $0.resetsAt > now }.max { $0.resetsAt < $1.resetsAt }
    }
}
