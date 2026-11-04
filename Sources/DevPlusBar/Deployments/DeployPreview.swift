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
        AIMonitor.shared.load(UsageScanner().scan())
        let ai = AIPanel(monitor: AIMonitor.shared)
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        write(ai, to: prefix + "-ai.png")
        // The Local side from this Mac's own repositories and servers.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in await LocalMonitor.shared.scanNow(); semaphore.signal() }
        while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let local = LocalPanel(monitor: LocalMonitor.shared, deploys: DeployMonitor.shared, state: LocalPanelState(), open: { _ in })
            .frame(width: 380).background(Ink.panel).foregroundStyle(Ink.primary).environment(\.colorScheme, .dark)
        write(local, to: prefix + "-local.png")
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
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
