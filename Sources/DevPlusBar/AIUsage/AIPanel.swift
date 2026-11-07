import AppKit
import Charts
import SwiftUI
import Defaults

/// The AI side of the panel: Claude Code and Codex usage from the logs on this Mac.
struct AIPanel: View {
    @ObservedObject var monitor: AIMonitor
    @Default(.claudeWindowCap) private var cap
    @Default(.claudeHasFiveHourLimit) private var hasFiveHour
    @State private var tool: UsageTool?

    static let caps = [0, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000]

    var body: some View {
        let stats = UsageStats(monitor.snapshot.records, tool: tool)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tool) {
                    Text("All").tag(UsageTool?.none)
                    ForEach(UsageTool.allCases, id: \.self) { Text($0.title).tag(UsageTool?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                Menu {
                    Picker("Claude plan limits", selection: $hasFiveHour) {
                        Text("Weekly only").tag(false)
                        Text("5-hour and weekly").tag(true)
                    }
                    Divider()
                    Button("Match claude.ai's percentage…") { Self.askOfficialPercent(monitor) }
                    Button("Forget learned limits (after a plan change)") { monitor.forgetLimits() }
                        .disabled(monitor.limits.weeklyCap == nil && monitor.limits.fiveHourCap == nil)
                    if hasFiveHour && monitor.limits.fiveHourCap == nil {
                        Picker("5-hour cap", selection: $cap) {
                            Text("Auto (your 7-day peak)").tag(0)
                            ForEach(Self.caps.dropFirst(), id: \.self) { Text("\(UsageStats.compact($0)) tokens").tag($0) }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("What the Claude ring measures against")
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            Rectangle().fill(Ink.hairline).frame(height: 1)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if tool != .codex { hasFiveHour ? AnyView(claudeWindow(stats)) : AnyView(claudeWeeklyHero(stats)) }
                    // Codex bars only while they say something: after every window reset with no
                    // new Codex use, they would read 0% on old data.
                    if tool != .claude, let limits = monitor.snapshot.codexLimits {
                        if [limits.primary, limits.secondary].compactMap({ $0 }).contains(where: { $0.resetsAt > Date() }) {
                            codexLimits(limits)
                        } else if tool == .codex {
                            Text("No Codex use since its limits last reset (\(limits.seenAt.formatted(.dateTime.month(.abbreviated).day()))).")
                                .font(Ink.meta).foregroundStyle(Ink.tertiary)
                        }
                    }
                    totals(stats)
                    if stats.weekTotal > 0 {
                        chart(stats)
                        breakdown("By model, 7 days", stats.week)
                        breakdown("Top projects, 7 days", stats.projects)
                    }
                    Text("Read from ~/.claude, ~/.claude.json and ~/.codex on this Mac. Nothing leaves it. Right-click for more.")
                        .font(.system(size: 10)).foregroundStyle(Ink.tertiary)
                }
                .padding(16)
                .contentShape(Rectangle())
                .contextMenu { panelMenu(stats) }
            }
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task { await monitor.scanNow() }
    }

    /// Asks for the "% used" on claude.ai › Settings › Usage and fits the cap to it.
    @MainActor static func askOfficialPercent(_ monitor: AIMonitor) {
        let alert = NSAlert()
        alert.messageText = "Match claude.ai"
        alert.informativeText = "Type the “% used” shown for this week at claude.ai › Settings › Usage (or /usage in Claude Code). Dev+ Bar sets the cap so its meter reads the same, and keeps learning from limit hits after that."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.placeholderString = "49"
        alert.accessoryView = field
        alert.addButton(withTitle: "Match")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let percent = Int(field.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " %"))),
              (1...100).contains(percent) else { return }
        monitor.match(officialPercent: percent)
    }

    // MARK: right-click

    @ViewBuilder private func panelMenu(_ stats: UsageStats) -> some View {
        Button("Rescan Logs Now") { Task { await monitor.scanNow() } }
        Picker("Show", selection: $tool) {
            Text("All").tag(UsageTool?.none)
            ForEach(UsageTool.allCases, id: \.self) { Text($0.title).tag(UsageTool?.some($0)) }
        }
        Divider()
        Button("Copy Usage Summary") {
            var lines = ["AI usage on this Mac (\(tool?.title ?? "Claude Code + Codex")):",
                         "Last 7 days: \(UsageStats.compact(stats.weekTotal)) tokens"]
            if let window = stats.window { lines.append("Current 5-hour window: \(UsageStats.compact(window.tokens)) tokens") }
            if let cap = monitor.limits.weeklyCap { lines.append("Learned Claude weekly cap: \(UsageStats.compact(cap)) tokens") }
            DeployCommands.copy(lines.joined(separator: "\n"))
        }
        Button("Show Claude Logs in Finder") { reveal("~/.claude/projects") }
        Button("Show Codex Logs in Finder") { reveal("~/.codex/sessions") }
        Divider()
        Picker("Claude plan limits", selection: $hasFiveHour) {
            Text("Weekly only").tag(false)
            Text("5-hour and weekly").tag(true)
        }
        Button("Match claude.ai's Percentage…") { Self.askOfficialPercent(monitor) }
        Button("Forget Learned Limits") { monitor.forgetLimits() }
            .disabled(monitor.limits.weeklyCap == nil && monitor.limits.fiveHourCap == nil)
    }

    private func reveal(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSSound.beep() }
    }

    // MARK: Claude

    @ViewBuilder private func claudeWindow(_ stats: UsageStats) -> some View {
        let now = Date()
        let limits = monitor.limits
        let stopped = ClaudeLimits.active(monitor.snapshot.claudeHits, now: now)
        // The cap, best source first: learned from a hit, set by you, your own peak.
        let (limit, source): (Int, String) = {
            if let learned = limits.fiveHourCap { return (learned, "learned from your limit hit \(Self.day(limits.fiveHourLearnedAt))") }
            if cap > 0 { return (cap, "of a \(UsageStats.compact(cap)) cap you set") }
            return (max(stats.peakWindow, 1), "estimate: vs your 7-day peak")
        }()
        let used = stats.window?.tokens ?? 0
        let fiveStopped = stopped?.kind == .fiveHour
        let fraction = fiveStopped ? 1 : min(1, Double(used) / Double(limit))
        VStack(alignment: .leading, spacing: 10) {
            if let stopped {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                    Text("\(stopped.kind == .sevenDay ? "Weekly" : "5-hour") limit reached · resets \(stopped.resetsAt.formatted(date: .omitted, time: .shortened)) (in \(Self.until(stopped.resetsAt, now: now)))")
                }
                .font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.red)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Ink.red.opacity(0.12)))
            }
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Ink.raised, lineWidth: 7)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Self.tint(fraction), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code · 5 hours").font(Ink.meta).foregroundStyle(Ink.secondary)
                    if let window = stats.window {
                        Text("\(UsageStats.compact(window.tokens)) of \(UsageStats.compact(limit)) · \(window.messages) replies")
                            .font(Ink.body.weight(.medium))
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("Resets in \(Self.until(window.end, now: context.date)) · at \(window.end.formatted(date: .omitted, time: .shortened))")
                                .font(Ink.meta).foregroundStyle(Ink.tertiary)
                        }
                    } else {
                        Text("No window open").font(Ink.body.weight(.medium))
                        Text("The next message starts a fresh 5 hours.").font(Ink.meta).foregroundStyle(Ink.tertiary)
                    }
                    Text(source).font(.system(size: 10)).foregroundStyle(limits.fiveHourCap != nil ? Ink.green : Ink.tertiary)
                }
                Spacer(minLength: 0)
            }
            weekly(stats, limits: limits, stopped: stopped?.kind == .sevenDay ? stopped : nil, now: now)
        }
        .help("Claude's limits are not published. Each time a limit stops you, Claude Code logs which one and when it resets; Dev+ Bar learns the cap from the tokens you had used by then.")
    }

    /// Plans without a 5-hour cap: the week is the one meter, drawn as the ring.
    @ViewBuilder private func claudeWeeklyHero(_ stats: UsageStats) -> some View {
        let now = Date()
        let limits = monitor.limits
        let stopped = ClaudeLimits.active(monitor.snapshot.claudeHits, now: now)
        let claude = monitor.snapshot.records.filter { $0.tool == .claude }
        let week = limits.currentWeek(now: now)
        let used = claude.filter { week?.contains($0.date) ?? ($0.date >= now.addingTimeInterval(-ClaudeLimits.week)) }
            .reduce(0) { $0 + $1.tokens }
        let fraction: Double? = stopped != nil ? 1 : limits.weeklyCap.map { min(1, Double(used) / Double(max($0, 1))) }
        VStack(alignment: .leading, spacing: 10) {
            if let stopped {
                Label("Weekly limit reached · resets \(Self.weekday(stopped.resetsAt)) (in \(Self.until(stopped.resetsAt, now: now)))",
                      systemImage: "hand.raised.fill")
                    .font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.red)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Ink.red.opacity(0.12)))
            }
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Ink.raised, lineWidth: 7)
                    Circle().trim(from: 0, to: fraction ?? 0)
                        .stroke(Self.tint(fraction ?? 0), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claude Code · this week").font(Ink.meta).foregroundStyle(Ink.secondary)
                    Text("\(UsageStats.compact(used))\(limits.weeklyCap.map { " of \(UsageStats.compact($0))" } ?? "") tokens")
                        .font(Ink.body.weight(.medium))
                    if let week {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("Resets \(Self.weekday(week.end)) · in \(Self.until(week.end, now: context.date))")
                                .font(Ink.meta).foregroundStyle(Ink.tertiary)
                        }
                    }
                    // The week's pace so far, as claude.ai predicts it; one busy day does not swing it.
                    if let cap = limits.weeklyCap, let week, stopped == nil {
                        if let out = ClaudeLimits.runsOut(used: used, cap: cap, week: week, now: now) {
                            Text("At this pace you run out \(ClaudeLimits.dayPart(out)), before \(week.end.formatted(.dateTime.weekday(.wide)))'s reset")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.warning)
                        } else if let left = ClaudeLimits.leftAtReset(used: used, cap: cap, week: week, now: now) {
                            Text("At this pace you reach the reset with \(Int((left * 100).rounded()))% left")
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Ink.green)
                        }
                    }
                    if let note = limits.mixNote(weekRecords: claude.filter { week?.contains($0.date) ?? false }) {
                        Text(note).font(.system(size: 10)).foregroundStyle(Ink.warning)
                    }
                    Text(limits.weeklySource(now: now)
                         ?? (week != nil ? "Reset time official; the cap is learned at your next weekly limit"
                                         : "Learns your cap and reset time from Claude Code's next usage check or weekly limit"))
                        .font(.system(size: 10)).foregroundStyle(Ink.tertiary)
                    Button("Not what claude.ai says? Match it…") { Self.askOfficialPercent(monitor) }
                        .buttonStyle(.link).font(.system(size: 10))
                }
                Spacer(minLength: 0)
            }
        }
        .help("Claude Code caches the weekly percentage Anthropic reports each time it checks your usage. Dev+ Bar reads it from ~/.claude.json, fits the cap to it, and counts on with the tokens logged since. Nothing is sent anywhere.")
    }

    /// The weekly meter: exact week boundaries once a weekly reset has been seen.
    @ViewBuilder private func weekly(_ stats: UsageStats, limits: ClaudeLimits, stopped: ClaudeLimitHit?, now: Date) -> some View {
        let records = monitor.snapshot.records.filter { $0.tool == .claude }
        if let week = limits.currentWeek(now: now) {
            let used = records.filter { week.contains($0.date) }.reduce(0) { $0 + $1.tokens }
            let fraction = stopped != nil ? 1 : limits.weeklyCap.map { min(1, Double(used) / Double(max($0, 1))) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Week").font(Ink.meta)
                    Spacer()
                    Text([fraction.map { "\(Int(($0 * 100).rounded()))%" },
                          "\(UsageStats.compact(used))\(limits.weeklyCap.map { " of \(UsageStats.compact($0))" } ?? "")",
                          "resets \(Self.weekday(week.end)) in \(Self.until(week.end, now: now))"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Ink.meta).monospacedDigit().foregroundStyle(Ink.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ink.raised)
                        Capsule().fill(Self.tint(fraction ?? 0)).frame(width: max(4, geo.size.width * (fraction ?? 0)))
                    }
                }
                .frame(height: 6)
                Text(limits.weeklySource(now: now) ?? "reset time is official; the cap is learned the next time the weekly limit stops you")
                    .font(.system(size: 10)).foregroundStyle(limits.weeklyCap != nil ? Ink.green : Ink.tertiary)
            }
        } else {
            HStack {
                Text("Last 7 days").font(Ink.meta)
                Spacer()
                Text(UsageStats.compact(records.filter { $0.date >= now.addingTimeInterval(-ClaudeLimits.week) }.reduce(0) { $0 + $1.tokens }))
                    .font(Ink.meta).monospacedDigit().foregroundStyle(Ink.tertiary)
            }
        }
    }

    static func day(_ date: Date?) -> String {
        guard let date else { return "" }
        return "on " + date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: Codex

    private func codexLimits(_ limits: CodexLimits) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Codex plan limits").font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.secondary)
                if let plan = limits.plan {
                    Text(plan.capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(Ink.purple)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Ink.purple.opacity(0.15)))
                }
                Spacer()
                Text("official").font(.system(size: 10)).foregroundStyle(Ink.tertiary)
            }
            if let w = limits.primary { bar(w, title: w.minutes == 300 ? "5 hours" : "\(w.minutes / 60)h") }
            if let w = limits.secondary { bar(w, title: w.minutes == 10080 ? "Week" : "\(w.minutes / 1440)d") }
        }
    }

    private func bar(_ w: CodexLimits.Window, title: String) -> some View {
        // A window that has reset since the last log line is back to zero.
        let reset = w.resetsAt <= Date()
        let fraction = reset ? 0 : min(1, w.usedPercent / 100)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(Ink.meta)
                Spacer()
                Text(reset ? "reset" : "\(Int(w.usedPercent))% · resets in \(Self.until(w.resetsAt, now: Date()))")
                    .font(Ink.meta).monospacedDigit().foregroundStyle(Ink.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.raised)
                    Capsule().fill(Self.tint(fraction)).frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: totals, chart, lists

    private func totals(_ stats: UsageStats) -> some View {
        HStack(spacing: 8) {
            tile("Today", UsageStats.compact(stats.todayTotal), sub: stats.today.first.map { "mostly \(Self.shortModel($0.name))" } ?? "")
            tile("7 days", UsageStats.compact(stats.weekTotal), sub: "\(stats.week.count) model\(stats.week.count == 1 ? "" : "s")")
            tile("Cache reads", UsageStats.compact(stats.week.reduce(0) { $0 + $1.cacheRead }), sub: "7 days, not counted")
        }
    }

    private func chart(_ stats: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tokens per day").font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.secondary)
            Chart(stats.days) { day in
                BarMark(x: .value("Day", day.start, unit: .day), y: .value("Tokens", day.tokens))
                    .foregroundStyle(by: .value("Tool", day.tool.title))
            }
            .chartForegroundStyleScale(["Claude Code": Ink.accent, "Codex": Ink.purple])
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let n = value.as(Int.self) { Text(UsageStats.compact(n)) } }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 110)
        }
    }

    private func breakdown(_ title: String, _ slices: [UsageStats.Slice]) -> some View {
        let top = slices.first?.tokens ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.secondary)
            ForEach(slices.prefix(5)) { slice in
                HStack(spacing: 8) {
                    Text(Self.shortModel(slice.name)).font(Ink.meta).lineLimit(1).frame(width: 120, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Ink.accent.opacity(0.55))
                            .frame(width: max(3, geo.size.width * Double(slice.tokens) / Double(max(top, 1))))
                    }
                    .frame(height: 5)
                    Text(UsageStats.compact(slice.tokens)).font(Ink.meta).monospacedDigit().foregroundStyle(Ink.tertiary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private func tile(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().lineLimit(1)
            Text(sub).font(.system(size: 10)).foregroundStyle(Ink.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
    }

    static func tint(_ fraction: Double) -> Color {
        fraction >= 0.9 ? Ink.red : fraction >= 0.7 ? Ink.warning : Ink.green
    }

    static func until(_ date: Date, now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s >= 86_400 { return "\(s / 86_400)d \((s % 86_400) / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 60)m"
    }

    /// "claude-opus-5-5" -> "opus-5-5"
    static func shortModel(_ name: String) -> String {
        name.hasPrefix("claude-") ? String(name.dropFirst(7)) : name
    }
}
