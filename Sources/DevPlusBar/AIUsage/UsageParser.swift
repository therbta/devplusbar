import Foundation

/// Byte-level lookups of top-level-looking fields in a JSON line.
enum Fields {
    private static func find(_ needle: String, in bytes: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        let n = Array(needle.utf8)
        guard from < bytes.count, let base = bytes.baseAddress,
              let hit = memmem(base + from, bytes.count - from, n, n.count) else { return nil }
        return (hit - UnsafeMutableRawPointer(mutating: base)) + n.count
    }

    /// The first `"key":"value"` (after `after`, if given), unescaped minimally.
    static func string(_ key: String, in line: Data, after: String? = nil) -> String? {
        line.withUnsafeBytes { bytes -> String? in
            var from = 0
            if let after, let i = find(after, in: bytes) { from = i }
            guard var i = find("\"\(key)\":\"", in: bytes, from: from) else { return nil }
            var out: [UInt8] = []
            while i < bytes.count, bytes[i] != 0x22 {
                if bytes[i] == 0x5C, i + 1 < bytes.count { i += 1 }
                out.append(bytes[i]); i += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    /// The `{…}` value of `"key":`, by brace depth (strings with braces inside are handled).
    static func object(_ key: String, in line: Data) -> Data? {
        line.withUnsafeBytes { bytes -> Data? in
            guard let after = find("\"\(key)\":{", in: bytes) else { return nil }
            let start = after - 1
            var depth = 0, inString = false, i = start
            while i < bytes.count {
                let b = bytes[i]
                if inString {
                    if b == 0x5C { i += 1 } else if b == 0x22 { inString = false }
                } else if b == 0x22 { inString = true }
                else if b == 0x7B { depth += 1 }
                else if b == 0x7D { depth -= 1; if depth == 0 { return Data(bytes[start...i]) } }
                i += 1
            }
            return nil
        }
    }
}

/// Reads lines of Claude Code and Codex session logs. Pure, tested against real line shapes.
enum UsageParser {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    static func project(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// A Claude Code `assistant` line → a record. Synthetic and zero-usage lines are skipped.
    static func claude(_ object: [String: Any]) -> UsageRecord? {
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = date(object["timestamp"]) else { return nil }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return nil }
        let id = message["id"] as? String ?? object["requestId"] as? String ?? object["uuid"] as? String ?? UUID().uuidString
        let record = UsageRecord(
            id: "claude:\(id)", tool: .claude, model: model, project: project(object["cwd"] as? String), date: date,
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
        return record.tokens + record.cacheRead > 0 ? record : nil
    }

    /// The same record as `claude(_:)`, without parsing the whole line: assistant lines carry
    /// tool inputs (whole files) and full JSON parsing of them dominated the scan.
    static func claudeFast(_ line: Data) -> UsageRecord? {
        guard let model = Fields.string("model", in: line), model != "<synthetic>",
              let usageData = Fields.object("usage", in: line),
              let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
              let date = date(Fields.string("timestamp", in: line)) else { return nil }
        let id = Fields.string("id", in: line, after: #""message":"#) ?? Fields.string("requestId", in: line) ?? UUID().uuidString
        let record = UsageRecord(
            id: "claude:\(id)", tool: .claude, model: model, project: project(Fields.string("cwd", in: line)), date: date,
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
        return record.tokens + record.cacheRead > 0 ? record : nil
    }

    /// A "You've hit your … limit" line with its `quotaLimits`.
    static func claudeHit(_ object: [String: Any]) -> ClaudeLimitHit? {
        guard let quota = object["quotaLimits"] as? [String: Any],
              quota["status"] as? String == "rejected",
              let reset = quota["resetsAt"] as? Double,
              let at = date(object["timestamp"]) else { return nil }
        let kind = ClaudeLimitHit.Kind(rawValue: quota["rateLimitType"] as? String ?? "") ?? .other
        return ClaudeLimitHit(kind: kind, resetsAt: Date(timeIntervalSince1970: reset), at: at)
    }

    /// The weekly utilization Claude Code cached from Anthropic, read from ~/.claude.json.
    static func claudeOfficial(_ config: [String: Any]) -> ClaudeOfficialUsage? {
        guard let cache = config["cachedUsageUtilization"] as? [String: Any],
              let fetchedMs = cache["fetchedAtMs"] as? Double,
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        // Claude Code drops a cache that belongs to another account, and so does this.
        if let owner = cache["accountUuid"] as? String,
           let current = (config["oauthAccount"] as? [String: Any])?["accountUuid"] as? String,
           owner != current { return nil }
        let week = utilization["seven_day"] as? [String: Any]
        let all = (utilization["limits"] as? [[String: Any]])?.first { $0["kind"] as? String == "weekly_all" }
        guard let percent = week?["utilization"] as? Double ?? all?["percent"] as? Double,
              let reset = isoDate(week?["resets_at"]) ?? isoDate(all?["resets_at"]) else { return nil }
        // Whole seconds: the API adds microseconds, which would move the stored week each read.
        return ClaudeOfficialUsage(weeklyPercent: percent,
                                   weeklyResetsAt: Date(timeIntervalSince1970: reset.timeIntervalSince1970.rounded()),
                                   fetchedAt: Date(timeIntervalSince1970: fetchedMs / 1000))
    }

    /// Like `date(_:)`, also for the six fractional digits Anthropic's API writes.
    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        if let d = date(s) { return d }
        return date(s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }

    /// Per-file state while reading a Codex log: the session's folder and the current model.
    struct CodexContext: Sendable {
        var project = "—"
        var model = "unknown"
    }

    enum CodexLine {
        case record(UsageRecord)
        case limits(CodexLimits)
        case none
    }

    static func codex(_ object: [String: Any], context: inout CodexContext) -> CodexLine {
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            context.project = project(payload["cwd"] as? String)
        case "turn_context":
            if let cwd = payload["cwd"] as? String { context.project = project(cwd) }
            if let model = payload["model"] as? String { context.model = model }
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any], let date = date(object["timestamp"]) else { break }
            let id = payload["response_id"] as? String ?? "\(payload["turn_id"] ?? "")-\(object["ordinal"] ?? "")"
            let input = usage["input_tokens"] as? Int ?? 0
            let cached = usage["cached_input_tokens"] as? Int ?? 0
            // Codex counts cached tokens inside input_tokens; split them like Claude's.
            return .record(UsageRecord(
                id: "codex:\(id)", tool: .codex, model: context.model, project: context.project, date: date,
                input: max(0, input - cached), output: usage["output_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0, cacheRead: cached))
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let date = date(object["timestamp"]) else { break }
            func window(_ key: String) -> CodexLimits.Window? {
                guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double,
                      let reset = w["resets_at"] as? Double else { return nil }
                return .init(usedPercent: used, minutes: w["window_minutes"] as? Int ?? 0,
                             resetsAt: Date(timeIntervalSince1970: reset))
            }
            return .limits(CodexLimits(primary: window("primary"), secondary: window("secondary"),
                                       plan: limits["plan_type"] as? String, seenAt: date))
        default: break
        }
        return .none
    }
}
