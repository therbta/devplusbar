import AppKit

// Gizli bayrak: App Store ekran goruntulerini uretir ve cikar.
// Kullanim: swift run Dev+ Bar --render-screens <dizin>   (make screens)
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-screens") {
    _ = NSApplication.shared   // SwiftUI render icin app baglami yeterli, run() gerekmez
    let directory = CommandLine.arguments.indices.contains(flagIndex + 1)
        ? CommandLine.arguments[flagIndex + 1]
        : "build/screens"
    MainActor.assumeIsolated {
        ScreenshotRenderer.renderAll(to: directory)
    }
    exit(0)
}

// Gizli bayrak: paneli ornek veriyle ciz ve cik. Kullanim: swift run Dev+ Bar --render-panel out.png
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-panel"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    _ = NSApplication.shared
    MainActor.assumeIsolated { PanelPreview.render(to: CommandLine.arguments[flagIndex + 1]) }
    exit(0)
}

// Gizli bayrak: Deploys panelini ornek veriyle ciz. Kullanim: Dev+ Bar --render-deploys build/deploys
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-deploys"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    _ = NSApplication.shared
    MainActor.assumeIsolated { DeployPreview.render(prefix: CommandLine.arguments[flagIndex + 1]) }
    exit(0)
}

// Gizli bayrak: yerel AI kullanimini yazdir. Kullanim: Dev+ Bar --usage-report
if CommandLine.arguments.contains("--usage-report") {
    let started = Date()
    let snapshot = UsageScanner().scan()
    let stats = UsageStats(snapshot.records, tool: nil)
    print("records \(snapshot.records.count) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    if let w = stats.window { print("claude window \(w.tokens) tokens, \(w.messages) replies, ends \(w.end)") } else { print("no claude window") }
    print("peak5h \(stats.peakWindow) today \(stats.todayTotal) week \(stats.weekTotal)")
    print("models", stats.week.map { "\($0.name)=\(UsageStats.compact($0.tokens))" })
    print("projects", stats.projects.map { "\($0.name)=\(UsageStats.compact($0.tokens))" })
    let limits = ClaudeLimits().learning(from: snapshot.claudeHits, records: snapshot.records)
    print("hits", snapshot.claudeHits.map { "\($0.kind.rawValue) at \($0.at) resets \($0.resetsAt)" })
    print("learned 5h", limits.fiveHourCap ?? -1, "week", limits.weeklyCap ?? -1, "week now", limits.currentWeek(now: Date()).map { "\($0.start)–\($0.end)" } ?? "-")
    if let l = snapshot.codexLimits { print("codex", l.plan ?? "", l.primary.map { "\($0.usedPercent)% resets \($0.resetsAt)" } ?? "", l.secondary.map { "week \($0.usedPercent)%" } ?? "") }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
