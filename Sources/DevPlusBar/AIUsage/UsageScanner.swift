import Foundation

/// Follows the session logs on disk, reading only what was appended since the last scan.
/// Not on the main actor: a first scan reads megabytes.
final class UsageScanner: @unchecked Sendable {
    /// Two weeks: learning the weekly cap needs the whole week before a limit hit.
    static let keepDays = 15

    private let lock = NSLock()
    private var offsets: [String: UInt64] = [:]
    private var codexContexts: [String: UsageParser.CodexContext] = [:]
    private var records: [String: UsageRecord] = [:]
    private var codexLimits: CodexLimits?
    /// By kind and reset time; the earliest moment it stopped you.
    private var hits: [String: ClaudeLimitHit] = [:]
    private let claudeRoot: URL
    private let codexRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeRoot = home.appendingPathComponent(".claude/projects")
        codexRoot = home.appendingPathComponent(".codex/sessions")
    }

    func scan(now: Date = Date()) -> UsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        for file in Self.logs(under: claudeRoot, since: cutoff) { read(file, tool: .claude) }
        for file in Self.logs(under: codexRoot, since: cutoff) { read(file, tool: .codex) }
        records = records.filter { $0.value.date >= cutoff }
        return UsageSnapshot(records: records.values.sorted { $0.date < $1.date },
                             claudeHits: hits.values.sorted { $0.at < $1.at },
                             codexLimits: codexLimits, scannedAt: now)
    }

    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let quotaMarker = Data(#""quotaLimits""#.utf8)
    private static let codexUsageMarker = Data(#""token_usage_record""#.utf8)
    private static let codexCountMarker = Data(#""token_count""#.utf8)
    private static let codexContextMarker = Data(#""turn_context""#.utf8)
    private static let codexMetaMarker = Data(#""session_meta""#.utf8)

    /// A one-off read of older logs, kept out of the rolling state: the Claude records between
    /// two dates, for learning a cap whose week starts before the kept window.
    static func claudeRecords(from start: Date, to end: Date,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UsageRecord] {
        let scanner = UsageScanner(home: home)
        scanner.lock.lock(); defer { scanner.lock.unlock() }
        for file in logs(under: scanner.claudeRoot, since: start) { scanner.read(file, tool: .claude) }
        return scanner.records.values.filter { $0.tool == .claude && $0.date >= start && $0.date <= end }
    }

    private static func has(_ p: UnsafeRawPointer, _ n: Int, _ marker: Data) -> Bool {
        marker.withUnsafeBytes { m in memmem(p, n, m.baseAddress!, m.count) != nil }
    }

    static func contains(_ line: Data, _ marker: Data) -> Bool {
        line.withUnsafeBytes { has($0.baseAddress!, $0.count, marker) }
    }

    private static func wanted(_ p: UnsafeRawPointer, _ n: Int, tool: UsageTool) -> Bool {
        switch tool {
        case .claude:
            return has(p, n, assistantMarker) && (has(p, n, usageMarker) || has(p, n, quotaMarker))
        case .codex:
            return has(p, n, codexUsageMarker) || has(p, n, codexCountMarker)
                || has(p, n, codexContextMarker) || has(p, n, codexMetaMarker)
        }
    }

    private static func logs(under root: URL, since cutoff: Date) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) >= cutoff { found.append(url) }
        }
        return found
    }

    static let chunkSize = 8 << 20

    /// Raw-buffer line walk: memchr for newlines, memmem for markers. Data's generic search was
    /// ~30x slower over gigabytes of logs. Each wanted line is handled as it is found.
    private func process(_ complete: Data, tool: UsageTool, context: inout UsageParser.CodexContext) {
        complete.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            let count = buffer.count
            while start < count {
                let nl = memchr(base + start, 0x0A, count - start)
                let end = nl.map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? count
                let length = end - start
                if length > 0, Self.wanted(base + start, length, tool: tool) {
                    handle(Data(bytes: base + start, count: length), tool: tool, context: &context)
                }
                start = end + 1
            }
        }
    }

    private func handle(_ line: Data, tool: UsageTool, context: inout UsageParser.CodexContext) {
        if tool == .claude, !Self.contains(line, Self.quotaMarker) {
            guard let record = UsageParser.claudeFast(line) else { return }
            if let old = records[record.id], old.tokens >= record.tokens { return }
            records[record.id] = record
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch tool {
        case .claude:
            if let hit = UsageParser.claudeHit(object) {
                let key = "\(hit.kind.rawValue)-\(hit.resetsAt.timeIntervalSince1970)"
                if (hits[key]?.at ?? .distantFuture) > hit.at { hits[key] = hit }
            }
        case .codex:
            switch UsageParser.codex(object, context: &context) {
            case .record(let record): records[record.id] = record
            case .limits(let limits):
                if (codexLimits?.seenAt ?? .distantPast) <= limits.seenAt { codexLimits = limits }
            case .none: break
            }
        }
    }

    private func read(_ url: URL, tool: UsageTool) {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; codexContexts[path] = nil }   // rewritten file
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        var context = codexContexts[path] ?? UsageParser.CodexContext()
        // In chunks, not readToEnd: the first scan covers gigabytes, and reading each file
        // whole put the app at 2.3 GB for a few seconds after every launch.
        var carry = Data()
        while true {
            let chunk: Data = autoreleasepool { (try? handle.read(upToCount: Self.chunkSize)) ?? Data() }
            if chunk.isEmpty { break }
            var buffer = carry
            buffer.append(chunk)
            // Only whole lines; a line still being written is read next time.
            guard let lastNewline = buffer.lastIndex(of: 0x0A) else { carry = buffer; continue }
            let complete = buffer[buffer.startIndex...lastNewline]
            autoreleasepool { process(complete, tool: tool, context: &context) }
            offset += UInt64(complete.count)
            carry = Data(buffer[buffer.index(after: lastNewline)...])
        }
        offsets[path] = offset
        codexContexts[path] = context
    }
}
