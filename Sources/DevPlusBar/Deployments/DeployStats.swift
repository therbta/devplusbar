import Foundation

enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }
    /// Bars per hour for 24h, per day otherwise.
    var bucket: Calendar.Component { self == .day ? .hour : .day }
}

/// Numbers for the Insights view, computed from history. Pure and tested.
struct DeployStats: Sendable {
    struct Bucket: Sendable, Hashable, Identifiable {
        let start: Date
        var ready = 0
        var failed = 0
        var canceled = 0
        var id: Date { start }
        var total: Int { ready + failed + canceled }
    }

    struct DurationPoint: Sendable, Hashable, Identifiable {
        let start: Date
        let p50: TimeInterval
        let p95: TimeInterval
        var id: Date { start }
    }

    struct HeatCell: Sendable, Hashable, Identifiable {
        /// 1 = Sunday … 7 = Saturday, as Calendar counts.
        let weekday: Int
        let hour: Int
        let count: Int
        var id: Int { weekday * 100 + hour }
    }

    let buckets: [Bucket]
    let durations: [DurationPoint]
    let heatmap: [HeatCell]
    let total: Int
    let successRate: Double?
    /// Success rate of the period before, for the delta.
    let previousSuccessRate: Double?
    let medianDuration: TimeInterval?
    let p95Duration: TimeInterval?
    /// Mean time from a failed production deployment to the next ready one, per project.
    let mttr: TimeInterval?
    /// Mean time from a commit's first preview to its production deployment being ready.
    let leadTime: TimeInterval?
    let today: Int
    /// Ready production deployments in a row, newest first, until the first failure.
    let greenStreak: Int
    let slowestProject: (name: String, median: TimeInterval)?

    init(_ history: [Deployment], range: StatsRange, now: Date = Date(), calendar: Calendar = .current) {
        let start = now.addingTimeInterval(-range.seconds)
        let inRange = history.filter { $0.createdAt >= start && $0.createdAt <= now }
        let previous = history.filter {
            $0.createdAt >= start.addingTimeInterval(-range.seconds) && $0.createdAt < start
        }

        // Buckets, including empty ones so the axis has no gaps.
        var bucketStarts: [Date] = []
        var cursor = calendar.dateInterval(of: range.bucket, for: start)?.start ?? start
        while cursor <= now {
            bucketStarts.append(cursor)
            cursor = calendar.date(byAdding: range.bucket, value: 1, to: cursor) ?? now.addingTimeInterval(1)
        }
        var byStart = Dictionary(uniqueKeysWithValues: bucketStarts.map { ($0, Bucket(start: $0)) })
        var durationsByStart: [Date: [TimeInterval]] = [:]
        for d in inRange {
            guard let key = calendar.dateInterval(of: range.bucket, for: d.createdAt)?.start else { continue }
            switch d.state {
            case .ready: byStart[key, default: Bucket(start: key)].ready += 1
            case .failed: byStart[key, default: Bucket(start: key)].failed += 1
            case .canceled: byStart[key, default: Bucket(start: key)].canceled += 1
            default: break
            }
            if d.state == .ready, let duration = d.duration, d.nativeID.hasPrefix("release:") == false {
                durationsByStart[key, default: []].append(duration)
            }
        }
        buckets = byStart.values.sorted { $0.start < $1.start }
        durations = durationsByStart.keys.sorted().map { key in
            let values = durationsByStart[key]!.sorted()
            return DurationPoint(start: key, p50: Self.percentile(values, 0.5), p95: Self.percentile(values, 0.95))
        }

        var heat: [Int: Int] = [:]
        for d in inRange {
            let c = calendar.dateComponents([.weekday, .hour], from: d.createdAt)
            heat[(c.weekday ?? 1) * 100 + (c.hour ?? 0), default: 0] += 1
        }
        heatmap = heat.map { HeatCell(weekday: $0.key / 100, hour: $0.key % 100, count: $0.value) }
            .sorted { $0.id < $1.id }

        total = inRange.count
        successRate = Self.rate(inRange)
        previousSuccessRate = Self.rate(previous)
        let allDurations = inRange.filter { $0.state == .ready && !$0.nativeID.hasPrefix("release:") }
            .compactMap(\.duration).sorted()
        medianDuration = allDurations.isEmpty ? nil : Self.percentile(allDurations, 0.5)
        p95Duration = allDurations.isEmpty ? nil : Self.percentile(allDurations, 0.95)
        mttr = Self.mttr(history.filter { $0.createdAt >= start })
        leadTime = Self.leadTime(inRange + history.filter { $0.createdAt < start && $0.createdAt >= start.addingTimeInterval(-range.seconds) })

        let dayStart = calendar.startOfDay(for: now)
        today = history.filter { $0.createdAt >= dayStart }.count

        var streak = 0
        for d in history.filter({ $0.target.isProduction && $0.state.isFinished && $0.state != .canceled })
            .sorted(by: { $0.createdAt > $1.createdAt }) {
            if d.state == .ready { streak += 1 } else { break }
        }
        greenStreak = streak

        let medians = Self.medianByProject(inRange)
        slowestProject = medians.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    static func percentile(_ sorted: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        let weight = rank - Double(low)
        return sorted[low] * (1 - weight) + sorted[high] * weight
    }

    static func rate(_ list: [Deployment]) -> Double? {
        let finished = list.filter { $0.state == .ready || $0.state == .failed }
        guard !finished.isEmpty else { return nil }
        return Double(finished.filter { $0.state == .ready }.count) / Double(finished.count)
    }

    static func medianByProject(_ list: [Deployment]) -> [String: TimeInterval] {
        var grouped: [String: [TimeInterval]] = [:]
        for d in list where d.state == .ready && !d.nativeID.hasPrefix("release:") {
            if let duration = d.duration { grouped[d.project, default: []].append(duration) }
        }
        return grouped.mapValues { percentile($0.sorted(), 0.5) }
    }

    static func mttr(_ list: [Deployment]) -> TimeInterval? {
        var gaps: [TimeInterval] = []
        let prod = Dictionary(grouping: list.filter { $0.target.isProduction }, by: \.project)
        for (_, deployments) in prod {
            var failedAt: Date?
            for d in deployments.sorted(by: { $0.createdAt < $1.createdAt }) {
                if d.state == .failed, failedAt == nil { failedAt = d.readyAt ?? d.createdAt }
                if d.state == .ready, let since = failedAt, let readyAt = d.readyAt {
                    gaps.append(readyAt.timeIntervalSince(since))
                    failedAt = nil
                }
            }
        }
        return gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
    }

    static func leadTime(_ list: [Deployment]) -> TimeInterval? {
        let bySHA = Dictionary(grouping: list.filter { $0.commit != nil }, by: { $0.commit!.sha })
        var leads: [TimeInterval] = []
        for (_, group) in bySHA {
            guard let firstPreview = group.filter({ !$0.target.isProduction }).map(\.createdAt).min(),
                  let prodReady = group.filter({ $0.target.isProduction && $0.state == .ready })
                    .compactMap(\.readyAt).min(),
                  prodReady > firstPreview else { continue }
            leads.append(prodReady.timeIntervalSince(firstPreview))
        }
        return leads.isEmpty ? nil : leads.reduce(0, +) / Double(leads.count)
    }
}
