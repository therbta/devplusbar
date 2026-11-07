import Foundation

enum UsageTool: String, Codable, Sendable, CaseIterable, Hashable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// One model response, from the local session logs.
struct UsageRecord: Sendable, Hashable, Identifiable {
    /// Claude message id or Codex response id; logs repeat a response, this dedupes it.
    let id: String
    let tool: UsageTool
    let model: String
    /// Last path component of the working directory.
    let project: String
    let date: Date
    var input: Int
    var output: Int
    var cacheWrite: Int
    var cacheRead: Int

    /// What the meters count: new input, cache writes and output. Cache reads are cheap and
    /// would swamp the number, so they are shown apart.
    var tokens: Int { input + cacheWrite + output }
}

/// Codex writes its real plan limits into its logs.
struct CodexLimits: Sendable, Hashable {
    struct Window: Sendable, Hashable {
        let usedPercent: Double
        let minutes: Int
        let resetsAt: Date
    }
    let primary: Window?
    let secondary: Window?
    let plan: String?
    let seenAt: Date
}

/// Claude Code logs the official limit data only when a limit stops you: which limit, and
/// exactly when it resets. Each hit calibrates the meters.
struct ClaudeLimitHit: Sendable, Hashable {
    enum Kind: String, Sendable, Codable { case fiveHour = "five_hour", sevenDay = "seven_day", other }
    let kind: Kind
    let resetsAt: Date
    /// When the limit first stopped you.
    let at: Date
}

/// The weekly percentage Anthropic reports for Claude, the number behind claude.ai's meter and
/// /usage. Claude Code caches the latest one in ~/.claude.json (`cachedUsageUtilization`) each
/// time it asks, so it is exact when fetched and goes stale between Claude Code's checks.
struct ClaudeOfficialUsage: Sendable, Hashable {
    /// 0…100.
    let weeklyPercent: Double
    let weeklyResetsAt: Date
    let fetchedAt: Date
}

/// Everything the AI side draws.
struct UsageSnapshot: Sendable {
    var records: [UsageRecord] = []
    var claudeHits: [ClaudeLimitHit] = []
    var codexLimits: CodexLimits?
    var claudeOfficial: ClaudeOfficialUsage?
    var scannedAt: Date?
}
