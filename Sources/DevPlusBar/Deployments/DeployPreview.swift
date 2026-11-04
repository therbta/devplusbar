import AppKit
import SwiftUI

/// `Dev+ Bar --render-deploys <prefix>`: draws the Deploys panel and Insights with sample data
/// to `<prefix>-activity.png` and `<prefix>-insights.png`, then exits.
@MainActor
enum DeployPreview {
    static func sample(now: Date = Date()) -> [Deployment] {
        var list: [Deployment] = []
        func add(_ id: String, _ provider: DeployProvider, _ project: String, _ target: DeployTarget,
                 _ state: DeployState, ago: TimeInterval, took: TimeInterval?, message: String? = nil,
                 failure: String? = nil, pr: Int? = nil) {
            let created = now.addingTimeInterval(-ago)
            list.append(Deployment(
                id: "\(provider.rawValue):\(id)", provider: provider, project: project, target: target, state: state,
                url: URL(string: "https://\(project).example.app"), dashboardURL: URL(string: "https://example.com"),
                commit: message.map { DeployCommit(sha: String(id.hashValue, radix: 16).replacingOccurrences(of: "-", with: "") + "abcdef",
                                                   ref: target.isProduction ? "main" : "feature/checkout",
                                                   message: $0, repository: "acme/\(project)", pullRequest: pr) },
                creator: "octocat", createdAt: created,
                readyAt: state.isFinished ? took.map { created.addingTimeInterval($0) } : nil,
                failureSummary: failure, nativeID: id))
        }
        add("d1", .vercel, "storefront", .production, .building, ago: 48, took: nil, message: "Speed up product grid")
        add("d2", .heroku, "orders-api", .production, .failed, ago: 600, took: 95, message: "Add refund webhook",
            failure: "Error: Cannot find module 'stripe-node'")
        add("d3", .vercel, "storefront", .preview, .ready, ago: 1500, took: 71, message: "Fix checkout tax", pr: 42)
        add("d4", .vercel, "docs", .production, .ready, ago: 4000, took: 38, message: "Document refunds")
        add("d5", .heroku, "orders-api", .production, .ready, ago: 9000, took: 128, message: "Bump Rails")
        // A week of history for the charts.
        var seed: UInt64 = 7
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for i in 0..<70 {
            let ago = 12_000 + next() * 6.5 * 86_400
            let state: DeployState = next() < 0.12 ? .failed : (next() < 0.04 ? .canceled : .ready)
            let projects = ["storefront", "docs", "orders-api"]
            let project = projects[i % 3]
            add("h\(i)", project == "orders-api" ? .heroku : .vercel, project,
                next() < 0.5 ? .production : .preview, state, ago: ago, took: 30 + next() * 120, message: "Change \(i)")
        }
        return list.sorted { $0.createdAt > $1.createdAt }
    }

    static func render(prefix: String) {
        let monitor = DeployMonitor(demo: sample())
        let failing = CIRun(id: 9001, workflow: "Integration tests", workflowID: 1, event: "push", status: "completed",
                            conclusion: "failure", sha: "4f2a9c1e0b7d", createdAt: Date().addingTimeInterval(-2400),
                            url: URL(string: "https://github.com/acme/orders-api/actions/runs/9001"))
        let stuck = CIRun(id: 9002, workflow: "Secret scan", workflowID: 2, event: "schedule", status: "completed",
                          conclusion: "failure", sha: "4f2a9c1e0b7d", createdAt: Date().addingTimeInterval(-9 * 3600),
                          url: URL(string: "https://github.com/acme/orders-api/actions/runs/9002"))
        monitor.loadDemo(ci: ["heroku:orders-api": CIStatus(repository: "acme/orders-api", branch: "main",
                                                             failing: [failing, stuck], running: [], passing: 3,
                                                             streaks: [9001: CIStreak(failures: 1, since: failing.createdAt, atLeast: false),
                                                                       9002: CIStreak(failures: 4, since: Date().addingTimeInterval(-3.5 * 86_400), atLeast: false)])],
                         logs: [9001: CIFailureLog(job: "test", step: "Run integration tests", lines: [
                             "PASS src/orders.test.ts", "FAIL src/refunds.test.ts",
                             "  ● refund webhook › rejects a replayed event",
                             "    Expected: 409", "    Received: 200"], url: failing.url)])
        let demoRun = CIRun(id: 9100, workflow: "Verify live (scheduled)", workflowID: 77, event: "schedule",
                            status: "completed", conclusion: "failure", sha: "abc", createdAt: Date().addingTimeInterval(-3600), url: nil)
        WorkflowMonitor.shared.loadDemo(neverPassed: [
            NeverPassedWorkflow(repository: "acme/site", workflowID: 77, workflow: "Verify live (scheduled)", event: "schedule",
                                failures: 67, since: Date().addingTimeInterval(-34 * 86_400), latest: demoRun),
            NeverPassedWorkflow(repository: "acme/mobile", workflowID: 78, workflow: "CI", event: "schedule",
                                failures: 50, since: Date().addingTimeInterval(-50 * 86_400), latest: demoRun),
        ])
        let state = DeployPanelState()
        state.cursor = "heroku:d2"
        state.expanded = ["ci:9001", NeverPassedStrip.id]
        let activity = DeploysPanel(monitor: monitor, state: state, open: { _ in }, openSettings: {})
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        let insights = DeployInsights(history: monitor.history)
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        write(activity, to: prefix + "-activity.png")
        write(insights, to: prefix + "-insights.png")
        // Sample data by default, so the pictures can go in the README. DEVPLUSBAR_REAL_PREVIEW=1
        // draws this Mac's own AI logs, repositories and servers instead, to check the layout.
        let real = ProcessInfo.processInfo.environment["DEVPLUSBAR_REAL_PREVIEW"] == "1"
        if real {
            AIMonitor.shared.load(UsageScanner().scan())
        } else {
            let usage = sampleUsage()
            AIMonitor.shared.load(usage.snapshot, limits: usage.limits)
        }
        let ai = AIPanel(monitor: AIMonitor.shared)
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        write(ai, to: prefix + "-ai.png")
        if real {
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in await LocalMonitor.shared.scanNow(); semaphore.signal() }
            while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        } else {
            LocalMonitor.shared.load(repos: sampleRepos(), servers: sampleServers())
        }
        let local = LocalPanel(monitor: LocalMonitor.shared, deploys: real ? DeployMonitor.shared : monitor,
                               state: LocalPanelState(), open: { _ in })
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        write(local, to: prefix + "-local.png")
    }

    /// Made-up repositories in every state the Local side draws: unpushed, never pushed, parked,
    /// edits only, and clean.
    static func sampleRepos(now: Date = Date()) -> [RepoState] {
        func repo(_ name: String, branch: String, upstream: String?, ahead: Int = 0, changed: Int = 0,
                  unpushed: [String] = [], newest: TimeInterval? = nil, oldest: TimeInterval? = nil) -> RepoState {
            var r = RepoState(path: "/Users/sam/Code/\(name)")
            r.branch = branch
            r.upstream = upstream
            r.ahead = ahead
            r.changed = changed
            r.github = "acme/\(name)"
            r.hasRemote = true
            r.unpushed = unpushed
            r.unpushedNewest = newest.map { now.addingTimeInterval(-$0) }
            r.unpushedOldest = oldest.map { now.addingTimeInterval(-$0) }
            r.statusRead = true
            return r
        }
        return [
            repo("storefront", branch: "feature/apple-pay", upstream: "origin/feature/apple-pay", ahead: 3, changed: 2,
                 unpushed: ["Show Apple Pay on Safari 18", "Hide the button when the wallet is empty", "Tests for the wallet check"],
                 newest: 40 * 60, oldest: 22 * 3600),
            repo("orders-api", branch: "refunds-v2", upstream: nil,
                 unpushed: ["Partial refunds", "Refund reason codes"], newest: 5 * 3600, oldest: 2 * 86_400),
            repo("design-system", branch: "spacing-tokens", upstream: "origin/spacing-tokens", ahead: 1,
                 unpushed: ["Try a 4px spacing scale"], newest: 12 * 86_400, oldest: 12 * 86_400),
            repo("mobile", branch: "main", upstream: "origin/main", changed: 5),
            repo("docs", branch: "main", upstream: "origin/main"),
        ]
    }

    static func sampleServers() -> [DevServer] {
        [
            DevServer(pids: [41210], command: "node", detail: "vite", ports: [5173], cwd: "/Users/sam/Code/storefront",
                      memoryKB: 412_000, kind: .dev),
            DevServer(pids: [41388], command: "node", detail: "next", ports: [3000], cwd: "/Users/sam/Code/docs",
                      memoryKB: 690_000, kind: .dev),
            DevServer(pids: [40977], command: "ruby", detail: "puma", ports: [3001], cwd: "/Users/sam/Code/orders-api",
                      memoryKB: 238_000, kind: .dev),
            DevServer(pids: [512], command: "postgres", detail: nil, ports: [5432], cwd: nil, memoryKB: 96_000, kind: .database),
            DevServer(pids: [518], command: "redis-server", detail: nil, ports: [6379], cwd: nil, memoryKB: 14_000, kind: .database),
        ]
    }

    /// A week of made-up Claude Code and Codex use, about two thirds of the way to the weekly cap.
    static func sampleUsage(now: Date = Date()) -> (snapshot: UsageSnapshot, limits: ClaudeLimits) {
        var seed: UInt64 = 11
        func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let projects = ["storefront", "orders-api", "mobile", "docs"]
        var records: [UsageRecord] = []
        for i in 0..<560 {
            // Most work in the last three days, a burst in the past two hours.
            let ago = i < 40 ? next() * 2 * 3600 : next() * 6.5 * 86_400
            let claude = next() < 0.85
            let model = claude ? (next() < 0.7 ? "claude-opus-5-5" : "claude-sonnet-5-5") : "gpt-5.4-codex"
            let input = Int(2_000 + next() * 9_000), output = Int(1_500 + next() * 6_000)
            let write = Int(next() * 50_000), read = Int(80_000 + next() * 400_000)
            records.append(UsageRecord(id: "sample-\(i)", tool: claude ? .claude : .codex, model: model,
                                       project: projects[Int(next() * Double(projects.count)) % projects.count],
                                       date: now.addingTimeInterval(-ago), input: input, output: output,
                                       cacheWrite: write, cacheRead: read))
        }
        var limits = ClaudeLimits()
        limits.weekAnchor = now.addingTimeInterval(-3.4 * 86_400)
        limits.weeklyCap = 16_000_000
        limits.weeklyLearnedAt = now.addingTimeInterval(-9 * 86_400)
        limits.fiveHourCap = 2_400_000
        limits.fiveHourLearnedAt = now.addingTimeInterval(-9 * 86_400)
        let codex = CodexLimits(primary: .init(usedPercent: 38, minutes: 300, resetsAt: now.addingTimeInterval(2.5 * 3600)),
                                secondary: .init(usedPercent: 21, minutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400)),
                                plan: "plus", seenAt: now.addingTimeInterval(-1800))
        return (UsageSnapshot(records: records.sorted { $0.date < $1.date }, claudeHits: [], codexLimits: codex, scannedAt: now), limits)
    }

    /// NSHostingView rather than ImageRenderer: ImageRenderer draws scroll views and pickers blank.
    private static func write(_ view: some View, to path: String) {
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        let size = NSSize(width: 380, height: max(200, fitting.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try? hosting.pngData()?.write(to: URL(fileURLWithPath: path))
    }
}
