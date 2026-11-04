import Testing
import Foundation
@testable import DevPlusBar

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

/// Line shapes copied from this Mac's logs on 2026-11-02, trimmed.
@Suite("AI usage")
struct AIUsageTests {
    @Test func claudeAssistantLine() throws {
        let line = json(#"{"type":"assistant","timestamp":"2026-11-02T05:28:55.089Z","cwd":"/Users/me/Desktop/React/Dev+ Bar","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":51121,"cache_read_input_tokens":36768,"output_tokens":259}}}"#)
        let r = try #require(UsageParser.claude(line))
        #expect(r.id == "claude:msg_1")
        #expect(r.project == "Dev+ Bar")
        #expect(r.tokens == 2 + 51121 + 259)
        #expect(r.cacheRead == 36768)
        #expect(UsageParser.claude(json(#"{"type":"user","timestamp":"2026-11-02T05:28:55Z"}"#)) == nil)
    }

    @Test func codexLines() throws {
        var context = UsageParser.CodexContext()
        _ = UsageParser.codex(json(#"{"type":"session_meta","payload":{"cwd":"/Users/me/Travel"}}"#), context: &context)
        _ = UsageParser.codex(json(#"{"type":"turn_context","payload":{"cwd":"/Users/me/Travel","model":"gpt-5.6-terra"}}"#), context: &context)
        guard case .record(let r) = UsageParser.codex(json(#"{"timestamp":"2026-10-20T18:53:54.303Z","ordinal":259,"type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":80253,"cached_input_tokens":76544,"cache_write_input_tokens":0,"output_tokens":211}}}"#), context: &context) else {
            Issue.record("no record"); return
        }
        #expect(r.model == "gpt-5.6-terra")
        #expect(r.project == "Travel")
        #expect(r.input == 80253 - 76544)   // cached tokens are inside input_tokens
        #expect(r.cacheRead == 76544)

        guard case .limits(let l) = UsageParser.codex(json(#"{"timestamp":"2026-10-20T18:45:30.575Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":24.0,"window_minutes":300,"resets_at":1792538991},"secondary":{"used_percent":6.0,"window_minutes":10080,"resets_at":1793103014},"plan_type":"plus"}}}"#), context: &context) else {
            Issue.record("no limits"); return
        }
        #expect(l.primary?.usedPercent == 24)
        #expect(l.secondary?.minutes == 10080)
        #expect(l.plan == "plus")
    }

    @Test func fiveHourWindows() {
        let now = Date(timeIntervalSince1970: 100_000)
        func r(_ id: String, _ ago: TimeInterval, _ tokens: Int) -> UsageRecord {
            UsageRecord(id: id, tool: .claude, model: "m", project: "p", date: now.addingTimeInterval(-ago),
                        input: tokens, output: 0, cacheWrite: 0, cacheRead: 0)
        }
        // An old window (8h ago, 2 messages), then a current one opened 2h ago.
        let stats = UsageStats([r("a", 8 * 3600, 500), r("b", 7 * 3600, 500), r("c", 2 * 3600, 100), r("d", 600, 50)],
                               tool: nil, now: now)
        #expect(stats.window?.tokens == 150)
        #expect(stats.window?.messages == 2)
        #expect(stats.window?.end == now.addingTimeInterval(3 * 3600))
        #expect(stats.peakWindow == 1000)
    }

    @Test func noOpenWindowAfterFiveHours() {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = UsageRecord(id: "x", tool: .claude, model: "m", project: "p", date: now.addingTimeInterval(-6 * 3600),
                              input: 10, output: 0, cacheWrite: 0, cacheRead: 0)
        #expect(UsageStats([old], tool: nil, now: now).window == nil)
    }

    @Test func scannerReadsOnlyNewWholeLinesAndDedupes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = dir.appendingPathComponent("s.jsonl")
        let now = ISO8601DateFormatter().string(from: Date())
        let line = #"{"type":"assistant","timestamp":"\#(now)","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":5,"output_tokens":1}}}"#
        // The same message twice (one line per content block), and a half-written line.
        try (line + "\n" + line + "\n" + #"{"type":"assist"#).write(to: file, atomically: true, encoding: .utf8)
        let scanner = UsageScanner(home: home)
        #expect(scanner.scan().records.count == 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"ant","timestamp":"\#(now)","message":{"id":"m2","model":"claude-x","usage":{"input_tokens":7,"output_tokens":1}}}"#.utf8) + Data("\n".utf8))
        try handle.close()
        let again = scanner.scan().records
        #expect(again.count == 2)
        #expect(again.reduce(0) { $0 + $1.tokens } == 14)
    }
}

@Suite("Claude limit learning")
struct ClaudeLimitsTests {
    private func r(_ date: Date, _ tokens: Int) -> UsageRecord {
        UsageRecord(id: UUID().uuidString, tool: .claude, model: "m", project: "p", date: date,
                    input: tokens, output: 0, cacheWrite: 0, cacheRead: 0)
    }

    @Test func liveHitLineParses() throws {
        // Real line shape, 2026-10-30, trimmed.
        let line = try JSONSerialization.jsonObject(with: Data(#"{"type":"assistant","timestamp":"2026-10-30T22:21:08.963Z","isApiErrorMessage":true,"apiError":"usage_limit_reached","error":"rate_limit","quotaLimits":{"status":"rejected","resetsAt":1793412000,"rateLimitType":"seven_day","overageStatus":"rejected"},"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your weekly limit · resets 10pm (America/New_York)"}]}}"#.utf8)) as! [String: Any]
        let hit = try #require(UsageParser.claudeHit(line))
        #expect(hit.kind == .sevenDay)
        #expect(hit.resetsAt == Date(timeIntervalSince1970: 1793412000))
        #expect(UsageParser.claude(line) == nil)   // synthetic, not usage
    }

    @Test func learnsWeeklyCapAndBoundary() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let weekStart = reset.addingTimeInterval(-ClaudeLimits.week)
        let records = [r(weekStart.addingTimeInterval(-3600), 999),        // before the week: ignored
                       r(weekStart.addingTimeInterval(60), 600),
                       r(reset.addingTimeInterval(-7200), 400),
                       r(reset.addingTimeInterval(-60), 50)]                // after the hit: ignored
        let hit = ClaudeLimitHit(kind: .sevenDay, resetsAt: reset, at: reset.addingTimeInterval(-3600))
        let learned = ClaudeLimits().learning(from: [hit], records: records)
        #expect(learned.weeklyCap == 1000)
        #expect(learned.weekAnchor == reset)
        let later = reset.addingTimeInterval(ClaudeLimits.week * 2 + 100)
        #expect(learned.currentWeek(now: later)?.start == reset.addingTimeInterval(ClaudeLimits.week * 2))
    }

    @Test func noWeeklyCapWhenLogsStartMidWeek() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let records = [r(reset.addingTimeInterval(-86_400), 500)]   // logs only reach one day back
        let hit = ClaudeLimitHit(kind: .sevenDay, resetsAt: reset, at: reset.addingTimeInterval(-60))
        let learned = ClaudeLimits().learning(from: [hit], records: records)
        #expect(learned.weeklyCap == nil)
        #expect(learned.weekAnchor == reset)   // the boundary is still exact
    }

    @Test func fastParserMatchesFullParser() throws {
        let text = #"{"parentUuid":"x","type":"assistant","timestamp":"2026-11-02T05:28:55.089Z","cwd":"/Users/me/Dev+ Bar","message":{"id":"msg_9","model":"claude-opus-5-5","content":[{"type":"tool_use","input":{"content":"func a() { if x { \"}\" } }"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":51121,"cache_read_input_tokens":36768,"output_tokens":259,"cache_creation":{"ephemeral_1h_input_tokens":51121}}}}"#
        let full = try #require(UsageParser.claude(JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]))
        let fast = try #require(UsageParser.claudeFast(Data(text.utf8)))
        #expect(fast.id == full.id)
        #expect(fast.tokens == full.tokens)
        #expect(fast.cacheRead == full.cacheRead)
        #expect(fast.project == full.project)
        #expect(fast.model == full.model)
    }
}

@Suite("Claude limit drift")
struct ClaudeLimitDriftTests {
    private func r(_ date: Date, _ tokens: Int, model: String = "claude-opus-5-5") -> UsageRecord {
        UsageRecord(id: UUID().uuidString, tool: .claude, model: model, project: "p", date: date,
                    input: tokens, output: 0, cacheWrite: 0, cacheRead: 0)
    }

    @Test func goingPastTheCapUnstoppedRaisesIt() {
        var limits = ClaudeLimits()
        limits.weeklyCap = 1000
        let raised = limits.raisingFloor(used: 1500, stopped: false)
        #expect(raised.weeklyCap == 1500)
        #expect(raised.weeklyCapIsFloor == true)
        #expect(limits.raisingFloor(used: 1500, stopped: true).weeklyCap == 1000)   // stopped: cap holds
        #expect(limits.raisingFloor(used: 900, stopped: false) == limits)
    }

    @Test func aLaterHitReplacesAFloor() {
        let reset = Date(timeIntervalSince1970: 2_000_000)
        let start = reset.addingTimeInterval(-ClaudeLimits.week)
        var limits = ClaudeLimits()
        limits.weeklyCap = 5000
        limits.weeklyCapIsFloor = true
        limits.weeklyLearnedAt = start.addingTimeInterval(-86_400)
        let hit = ClaudeLimitHit(kind: .sevenDay, resetsAt: reset, at: reset.addingTimeInterval(-60))
        let learned = limits.learning(from: [hit], records: [r(start.addingTimeInterval(-10), 1), r(start.addingTimeInterval(60), 3000)])
        #expect(learned.weeklyCap == 3000)
        #expect(learned.weeklyCapIsFloor == false)
    }

    @Test func deepReadLearnsWhenKeptLogsAreShort() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let iso = ISO8601DateFormatter()
        let reset = Date().addingTimeInterval(86_400)
        let inWeek = iso.string(from: reset.addingTimeInterval(-3 * 86_400))
        let before = iso.string(from: reset.addingTimeInterval(-9 * 86_400))
        let lines = [
            #"{"type":"assistant","timestamp":"\#(before)","message":{"id":"old","model":"claude-opus-5-5","usage":{"input_tokens":999,"output_tokens":0}}}"#,
            #"{"type":"assistant","timestamp":"\#(inWeek)","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":700,"output_tokens":0}}}"#,
            #"{"type":"assistant","timestamp":"\#(inWeek)","message":{"id":"b","model":"claude-sonnet-5-5","usage":{"input_tokens":300,"output_tokens":0}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let hit = ClaudeLimitHit(kind: .sevenDay, resetsAt: reset, at: reset.addingTimeInterval(-3600))
        let week = UsageScanner.claudeRecords(from: reset.addingTimeInterval(-ClaudeLimits.week), to: hit.at, home: home)
        let learned = ClaudeLimits().learningWeekly(from: hit, weekRecords: week)
        #expect(learned.weeklyCap == 1000)
        #expect(learned.mixAtLearn?["opus"] == 0.7)
    }

    @Test func mixShiftIsFlagged() {
        var limits = ClaudeLimits()
        limits.weeklyCap = 100
        limits.mixAtLearn = ["opus": 0.998, "sonnet": 0.002]
        let now = Date()
        let sonnetHeavy = [r(now, 40), r(now, 60, model: "claude-sonnet-5-5")]
        #expect(limits.mixNote(weekRecords: sonnetHeavy)?.contains("60% sonnet") == true)
        #expect(limits.mixNote(weekRecords: [r(now, 100)]) == nil)
    }

    @Test func oldStoredLimitsStillDecode() throws {
        let old = #"{"weeklyCap":83722705,"weeklyLearnedAt":815091668.963,"weekAnchor":815104800}"#
        let decoded = try JSONDecoder().decode(ClaudeLimits.self, from: Data(old.utf8))
        #expect(decoded.weeklyCap == 83722705)
    }
}

@Suite("Claude weekly pace and calibration")
struct ClaudePaceTests {
    /// claude.ai on 2026-11-02: 49% used, resets Friday 21:00, "you'll run out Thursday night".
    @Test func weekPaceMatchesTheOfficialPrediction() {
        var parts = DateComponents(); parts.year = 2026; parts.month = 10; parts.day = 30; parts.hour = 21
        let start = Calendar.current.date(from: parts)!
        let week = DateInterval(start: start, duration: ClaudeLimits.week)
        let now = start.addingTimeInterval(2 * 86_400 + 22 * 3600)   // Monday 19:00, when it was read
        let out = ClaudeLimits.runsOut(used: 49, cap: 100, week: week, now: now)
        #expect(out.map(ClaudeLimits.dayPart) == "Thursday night")
        // A lighter week lasts, and says how much is left.
        #expect(ClaudeLimits.runsOut(used: 30, cap: 100, week: week, now: now) == nil)
        let left = ClaudeLimits.leftAtReset(used: 30, cap: 100, week: week, now: now)!
        #expect(abs(left - 0.28) < 0.01)   // 30% in 70 h is 72% by the 168th
    }

    @Test func matchingTheOfficialPercentSetsTheCap() {
        let limits = ClaudeLimits(weeklyCap: 83_700_000, weeklyLearnedAt: Date(timeIntervalSinceNow: -3 * 86_400))
        let next = limits.calibrating(used: 44_500_000, percent: 49, weekRecords: [])
        #expect(next.weeklyCap == 90_816_327)
        #expect(next.calibratedPercent == 49)
        #expect(next.weeklyCapIsFloor == false)
        // An older hit does not undo it.
        let hit = ClaudeLimitHit(kind: .sevenDay, resetsAt: Date(timeIntervalSinceNow: 86_400), at: Date(timeIntervalSinceNow: -86_400))
        #expect(next.learning(from: [hit], records: []).weeklyCap == 90_816_327)
        #expect(limits.calibrating(used: 10, percent: 0, weekRecords: []) == limits)
    }

    @Test func smallHoursBelongToTheNightBefore() {
        var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 6; parts.hour = 2
        #expect(ClaudeLimits.dayPart(Calendar.current.date(from: parts)!) == "Thursday night")
    }
}
