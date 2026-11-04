import AppKit
import Defaults

extension Defaults.Keys {
    static let showLocal = Key<Bool>("showLocal", default: true)
    /// Folders to look for repositories in, comma-separated; empty = the usual places.
    static let localRoots = Key<String>("localRoots", default: "")
    static let notifyUnpushed = Key<Bool>("notifyUnpushed", default: true)
    /// Repositories already nudged about (path -> date of the oldest unpushed commit then).
    static let unpushedNudged = Key<[String: Double]>("unpushedNudged", default: [:])
}

/// Says once when work committed recently has sat a day without being pushed.
///
/// Parked repositories (nothing new committed for a week) are left alone: they are set aside on
/// purpose, and nudging about a four-month-old branch every launch is how a nudge gets ignored.
/// A repository is nudged again only after it was pushed and new work sat a day again.
enum UnpushedWatch {
    static let after: TimeInterval = 86_400

    static func check(nudged: [String: Double], repos: [RepoState], now: Date = Date())
        -> (due: [RepoState], next: [String: Double]) {
        var due: [RepoState] = []
        // A repository missing from this scan, or one git did not answer for, keeps its record:
        // forgetting it would nudge about the same work again on the next scan.
        let read = Set(repos.filter(\.statusRead).map(\.path))
        var next = nudged.filter { !read.contains($0.key) }
        for repo in repos where repo.statusRead && repo.hasUnpushed {
            guard let oldest = repo.unpushedOldest else { continue }
            let stamp = oldest.timeIntervalSince1970
            // Kept while the same work is still waiting; pushing clears it.
            if let given = nudged[repo.path], given == stamp { next[repo.path] = given; continue }
            guard now.timeIntervalSince(oldest) >= after, !repo.isParked(now: now) else { continue }
            due.append(repo)
            next[repo.path] = stamp
        }
        return (due.sorted { ($0.unpushedOldest ?? now) < ($1.unpushedOldest ?? now) }, next)
    }

    static func notice(_ repo: RepoState, now: Date = Date()) -> BarNotice {
        let age = repo.unpushedOldest.map { RepoState.age(now.timeIntervalSince($0)) } ?? "a day"
        let title = repo.ahead > 0
            ? "\(repo.ahead) commit\(repo.ahead == 1 ? "" : "s") only on this Mac for \(age)"
            : "Branch \(repo.branch ?? "") never pushed, \(age) old"
        return BarNotice(id: "unpushed-\(repo.path)-\(Int(repo.unpushedOldest?.timeIntervalSince1970 ?? 0))",
                         tone: .warning, symbol: "arrow.up.circle.fill",
                         heading: "Not pushed · \(repo.name)", title: title,
                         detail: repo.unpushed.first.map { "“\($0)”" }, mode: .local)
    }
}

/// The repositories and dev servers on this Mac, scanned every two minutes and whenever the
/// Local side opens. Only git, lsof and ps are run; nothing leaves the Mac.
@MainActor
final class LocalMonitor: ObservableObject {
    static let shared = LocalMonitor()
    static let interval: Duration = .seconds(120)
    /// Repositories are looked for again this often; their state is read on every scan.
    static let discoverEvery: TimeInterval = 600

    @Published private(set) var repos: [RepoState] = []
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanning = false
    /// Processes already sent SIGTERM; a second Stop on them force-quits.
    private(set) var terminated: Set<Int32> = []
    var onChange: (() -> Void)?
    private var loop: Task<Void, Never>?
    private var paths: [String] = []
    private var discoveredAt: Date?
    private var rootsUsed = ""

    var hasData: Bool { !repos.isEmpty || !servers.isEmpty }
    /// Recent commits that exist only on this Mac, the longest waiting first.
    var unpushed: [RepoState] { Self.recent(repos, now: Date()) }
    /// Unpushed work nothing was added to for a week, the most recent first.
    var parked: [RepoState] { Self.parked(repos, now: Date()) }

    nonisolated static func recent(_ repos: [RepoState], now: Date) -> [RepoState] {
        repos.filter { $0.hasUnpushed && !$0.isParked(now: now) }.sorted {
            ($0.unpushedOldest ?? now, -$0.ahead) < ($1.unpushedOldest ?? now, -$1.ahead)
        }
    }

    nonisolated static func parked(_ repos: [RepoState], now: Date) -> [RepoState] {
        repos.filter { $0.isParked(now: now) }.sorted { ($0.unpushedNewest ?? now) > ($1.unpushedNewest ?? now) }
    }
    /// Edits not committed yet, in repositories that are otherwise pushed.
    var uncommitted: [RepoState] {
        repos.filter { $0.changed > 0 && $0.ahead == 0 && !$0.isUnpublished }.sorted { $0.changed > $1.changed }
    }
    /// For the badge: parked work does not count.
    var unpushedCount: Int { unpushed.count }
    /// Called with repositories whose recent work has waited a day; see `UnpushedWatch`.
    var onNudge: (([RepoState]) -> Void)?

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanNow()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func scanIfStale(_ age: TimeInterval = 10) async {
        if let lastScan, Date().timeIntervalSince(lastScan) < age { return }
        await scanNow()
    }

    func scanNow() async {
        guard Defaults[.showLocal], !scanning else { return }
        scanning = true
        defer { scanning = false }
        let setting = Defaults[.localRoots]
        if discoveredAt == nil || setting != rootsUsed || Date().timeIntervalSince(discoveredAt!) > Self.discoverEvery {
            let roots = LocalScanner.roots(setting)
            paths = await Task.detached(priority: .utility) { LocalScanner.discover(roots: roots) }.value
            discoveredAt = Date()
            rootsUsed = setting
        }
        let paths = paths
        async let freshRepos = Task.detached(priority: .utility) { await LocalScanner.repos(paths) }.value
        async let freshServers = Task.detached(priority: .utility) { LocalScanner.servers() }.value
        let (r, s) = await (freshRepos, freshServers)
        let hadData = hasData, hadUnpushed = unpushedCount
        repos = r.sorted { $0.name.lowercased() < $1.name.lowercased() }
        servers = s
        terminated.formIntersection(Set(s.flatMap(\.pids)))
        lastScan = Date()
        if hadData != hasData || hadUnpushed != unpushedCount { onChange?() }
        if Defaults[.notifyUnpushed] {
            let result = UnpushedWatch.check(nudged: Defaults[.unpushedNudged], repos: repos)
            if result.next != Defaults[.unpushedNudged] { Defaults[.unpushedNudged] = result.next }
            if !result.due.isEmpty { onNudge?(result.due) }
        }
    }

    /// For screenshots.
    func load(repos: [RepoState], servers: [DevServer]) {
        self.repos = repos
        self.servers = servers
        lastScan = Date()
    }

    /// The repository a folder belongs to, for naming a server by its project.
    func repo(containing folder: String?) -> RepoState? {
        guard let folder else { return nil }
        return repos.filter { folder == $0.path || folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    // MARK: actions

    /// Asks first; SIGTERM, then SIGKILL if it is still there the second time.
    func stop(_ server: DevServer) {
        guard server.kind == .dev else { NSSound.beep(); return }
        let force = !terminated.isDisjoint(with: server.pids)
        let alert = NSAlert()
        let project = repo(containing: server.cwd)?.name ?? server.cwd.map { ($0 as NSString).lastPathComponent }
        alert.messageText = (force ? "Force quit " : "Stop ") + server.title
            + (server.ports.first.map { " on :\($0)" } ?? "") + (project.map { " (\($0))" } ?? "") + "?"
        alert.informativeText = force
            ? "It did not stop last time. This sends SIGKILL to process \(server.pids.map(String.init).joined(separator: ", ")); unsaved work in it is lost."
            : "Sends SIGTERM to process \(server.pids.map(String.init).joined(separator: ", ")), the same as Ctrl-C in its terminal."
        alert.alertStyle = .warning
        alert.addButton(withTitle: force ? "Force Quit" : "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for pid in server.pids { kill(pid, force ? SIGKILL : SIGTERM) }
        terminated.formUnion(server.pids)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await self.scanNow()
        }
    }

    static let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                          "com.sublimetext.4", "com.jetbrains.WebStorm", "com.apple.dt.Xcode"]
    static let terminals = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]

    func openInEditor(_ path: String) { open(path, with: Self.editors) }
    func openInTerminal(_ path: String) { open(path, with: Self.terminals) }

    private func open(_ path: String, with bundleIDs: [String]) {
        let url = URL(fileURLWithPath: path)
        guard let app = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            NSWorkspace.shared.activateFileViewerSelecting([url]); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
