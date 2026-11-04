import AppKit
import Defaults

/// Polls Vercel and Heroku, keeps history, and reports what changed.
///
/// No server: each provider is asked directly with the user's own token. While something
/// builds the poll runs every 15 seconds; otherwise at the GitHub refresh interval.
@MainActor
final class DeployMonitor: ObservableObject {
    static let shared = DeployMonitor()
    static let activeInterval: TimeInterval = 15

    @Published private(set) var deployments: [Deployment] = []
    @Published private(set) var history: [Deployment] = []
    @Published private(set) var errors: [DeployProvider: String] = [:]
    @Published private(set) var connected: Set<DeployProvider> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var seen: Set<String> = Set(Defaults[.deploySeen])
    /// Commits waiting on the production branch, by "provider:project".
    @Published private(set) var pending: [String: PendingCommits] = [:]
    /// GitHub Actions on the production branch, by "provider:project".
    @Published private(set) var ci: [String: CIStatus] = [:]
    /// Failed-step logs, by run id, fetched when a CI row is opened.
    @Published private(set) var ciLogs: [Int: CIFailureLog] = [:]
    private var ciTags: [String: String] = [:]
    private var ciCheckedAt: [String: Date] = [:]
    /// The GitHub token, for comparing production with the branch.
    var githubToken: (() async -> String?)?
    private var pendingCheckedAt: [String: (sha: String, at: Date)] = [:]
    /// ETag of the last comparison per project; a 304 costs no rate limit.
    private var compareTags: [String: String] = [:]
    private var defaultBranches: [String: String] = [:]
    /// How often an unchanged production is compared again.
    static let pendingInterval: TimeInterval = 300
    /// How long after a Heroku release its dynos are watched for crashes.
    static let crashWatch: TimeInterval = 600

    /// Alerts for the app delegate to show; sounds are played here.
    var onAlerts: (([DeployAlert]) -> Void)?
    /// Called after every poll, so the menu bar icon can follow.
    var onChange: (() -> Void)?
    /// The GitHub login, to recognise your own deployments.
    var githubLogin: String?

    private var store = DeployHistory(url: DeployHistory.defaultURL)
    private var tracker = DeployTracker()
    private var loop: Task<Void, Never>?
    private var relayLoop: Task<Void, Never>?
    private var pausedUntil: [DeployProvider: Date] = [:]
    private var running = false
    /// Failed deployments whose build log was already read for a better failure line.
    private var summaryTried: Set<String> = []

    /// No line, or one that only says the build command failed.
    nonisolated static func isVague(_ line: String?) -> Bool {
        guard let line else { return true }
        return line.hasPrefix("Command \"") || line.lowercased().contains("exited with")
    }
    private var again = false

    /// Sample data for previews and screenshots; never polls.
    init(demo: [Deployment]) {
        store = DeployHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("devplusbar-demo.json"))
        history = demo
        connected = Set(DeployProvider.allCases)
        seen = Set(demo.dropFirst(3).map(\.id))
        recompute()
    }

    /// Screenshots only.
    func loadDemo(ci: [String: CIStatus], logs: [Int: CIFailureLog] = [:]) {
        self.ci = ci
        ciLogs = logs
    }

    init() {
        history = store.all
        connected = Set(DeployProvider.allCases.filter { Self.token(for: $0) != nil })
        recompute()
    }

    // MARK: lifecycle

    func start() {
        schedule(after: 1)
        startRelay()
    }

    /// Polls now, and from then on at the right pace.
    func refresh() { schedule(after: 0) }

    private func schedule(after delay: TimeInterval) {
        loop?.cancel()
        loop = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.poll()
            guard !Task.isCancelled else { return }
            self.schedule(after: self.nextInterval)
        }
    }

    var nextInterval: TimeInterval {
        if history.prefix(50).contains(where: { $0.state.isActive }) { return Self.activeInterval }
        if !crashWatchList.isEmpty { return Self.activeInterval * 2 }
        let idle = Defaults[.deployIdleSeconds]
        return idle > 0 ? TimeInterval(max(30, idle)) : Settings.refreshInterval()
    }

    var hasActive: Bool { deployments.contains { $0.state.isActive } }
    var hasRecentFailure: Bool {
        let latest = deployments.first { $0.target.isProduction && $0.state.isFinished && $0.state != .canceled }
        return (latest?.state == .failed || latest?.isCrashed == true)
            && deployments.contains { ($0.state == .failed || $0.isCrashed) && !seen.contains($0.id) }
    }

    // MARK: tokens

    static func token(for provider: DeployProvider) -> String? {
        Keychain.token(account: provider.keychainAccount)
    }

    func client(for provider: DeployProvider) -> DeployClient? {
        guard let token = Self.token(for: provider) else { return nil }
        switch provider {
        case .vercel: return VercelClient(token: token, teamID: Defaults[.vercelTeamID])
        case .heroku: return HerokuClient(token: token, apps: Defaults[.herokuApps])
        }
    }

    /// Validates `token` with the provider, then stores it.
    func connect(_ provider: DeployProvider, token: String, teamID: String = "") async throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var teamID = teamID
        let client: DeployClient = switch provider {
        case .vercel: VercelClient(token: trimmed, teamID: teamID)
        case .heroku: HerokuClient(token: trimmed)
        }
        let who = try await client.whoAmI()
        // Projects usually live under a team, and the personal scope then lists nothing. With
        // one team and no choice made, that team is the scope.
        if provider == .vercel, teamID.isEmpty,
           let teams = try? await VercelClient(token: trimmed).teams(), teams.count == 1 {
            teamID = teams[0].id
        }
        guard Keychain.save(token: trimmed, account: provider.keychainAccount) else {
            throw DeployError.unsupported("The token could not be saved to the Keychain.")
        }
        switch provider {
        case .vercel: Defaults[.vercelAccount] = who; Defaults[.vercelTeamID] = teamID
        case .heroku: Defaults[.herokuAccount] = who
        }
        connected.insert(provider)
        tracker.forget(provider)
        refresh()
        return who
    }

    func disconnect(_ provider: DeployProvider) {
        Keychain.delete(account: provider.keychainAccount)
        switch provider {
        case .vercel: Defaults[.vercelAccount] = nil
        case .heroku: Defaults[.herokuAccount] = nil
        }
        connected.remove(provider)
        errors[provider] = nil
        tracker.forget(provider)
        store.remove(provider: provider)
        try? store.save()
        history = store.all
        recompute()
        onChange?()
    }

    // MARK: polling

    private func poll() async {
        guard !running else { again = true; return }
        running = true
        isRefreshing = true
        defer {
            running = false
            isRefreshing = false
            if again { again = false; Task { await self.poll() } }
        }

        var alerts: [DeployAlert] = []
        let rules = DeployAlertRules.fromDefaults()
        for provider in DeployProvider.allCases {
            guard let client = client(for: provider) else { continue }
            if let until = pausedUntil[provider], until > Date() { continue }
            do {
                let timed = Set(store.byID.values.filter { $0.provider == provider && $0.readyAt != nil }.map(\.id))
                let polled = try await client.recent(limit: 40, timed: timed)
                errors[provider] = nil
                let changes = tracker.ingest(polled, from: provider)
                store.merge(polled)
                let medians = DeployStats.medianByProject(store.all)
                alerts += rules.alerts(for: changes.filter { visible($0.deployment) },
                                       myLogins: myLogins, medians: medians)
                // A provider seen for the first time: its history is not news. Orange stays for what
                // happens from now on.
                if !seen.contains(where: { $0.hasPrefix(provider.rawValue + ":") }) {
                    markSeen(polled.map(\.id))
                }
                // Explain failures with a line from the build log: new ones, and older ones whose
                // only explanation is Vercel's generic "Command … exited with 1" (a few per poll).
                let vague = polled.filter { d in
                    d.state == .failed && !summaryTried.contains(d.id)
                        && Self.isVague(store.byID[d.id]?.failureSummary)
                }.prefix(3)
                for d in Set(changes.filter { $0.to == .failed }.map(\.deployment) + vague) {
                    summaryTried.insert(d.id)
                    if let line = await client.failureSummary(for: d) {
                        store.setFailureSummary(line, for: d.id)
                    }
                }
            } catch DeployError.rateLimited(_, let until) {
                pausedUntil[provider] = until
                errors[provider] = DeployError.rateLimited(provider, until).errorDescription
            } catch {
                errors[provider] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        alerts += await checkCrashes()
        store.prune()
        try? store.save()
        history = store.all
        lastRefresh = Date()
        recompute()
        await refreshPending()

        // Alerts carry the stored copy, which has the failure line.
        let enriched = alerts.map { alert in
            DeployAlert(transition: DeployTransition(
                deployment: store.byID[alert.transition.deployment.id] ?? alert.transition.deployment,
                from: alert.transition.from, to: alert.transition.to),
                notify: alert.notify, toast: alert.toast, tone: alert.tone, timeSensitive: alert.timeSensitive,
                crash: alert.crash)
        }
        if !enriched.isEmpty {
            DeploySound.play(enriched.compactMap(\.tone))
            onAlerts?(enriched)
        }
        onChange?()
    }

    // MARK: logs and prompts

    func logLines(for d: Deployment, limit: Int = 8) async -> [String] {
        guard let client = client(for: d.provider) else { return [] }
        return await client.logLines(for: d, limit: limit)
    }

    /// Everything a coding agent needs to fix this deployment, on the clipboard.
    func copyPrompt(for d: Deployment) async {
        let log = await logLines(for: d, limit: 40)
        let repo = d.commit?.repository ?? Defaults[.deployRepoMap]["\(d.provider.rawValue):\(d.project)"]
        let text = DeployPrompt.text(d, repository: repo, log: log)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: crashes after a release

    /// The newest production release of each Heroku app, while it is young enough to watch.
    private var crashWatchList: [Deployment] {
        var newest: [String: Deployment] = [:]
        for d in store.byID.values where d.provider == .heroku && d.target.isProduction && d.state == .ready {
            if (newest[d.project]?.createdAt ?? .distantPast) < d.createdAt { newest[d.project] = d }
        }
        return newest.values.filter { Date().timeIntervalSince($0.readyAt ?? $0.createdAt) < Self.crashWatch }
    }

    /// Checks the dynos of freshly released apps; a new crash becomes an alert.
    private func checkCrashes() async -> [DeployAlert] {
        guard let heroku = client(for: .heroku) as? HerokuClient else { return [] }
        var alerts: [DeployAlert] = []
        for d in crashWatchList where visible(d) {
            guard let crashed = try? await heroku.crashedDynos(app: d.project) else { continue }
            let before = d.crashedDynos ?? []
            store.setCrashed(crashed.isEmpty ? nil : crashed, for: d.id)
            guard let now = store.byID[d.id], !Set(crashed).subtracting(before).isEmpty else { continue }
            seen.remove(d.id)
            alerts.append(DeployAlert(transition: DeployTransition(deployment: now, from: .ready, to: .ready),
                                      notify: Defaults[.deployNotifyProductionFailed], toast: true,
                                      tone: Defaults[.deploySoundsEnabled] ? .failure : nil,
                                      timeSensitive: true, crash: true))
        }
        return alerts
    }

    // MARK: merged, not deployed

    /// For each project's production deployment, how many commits its branch has on top.
    /// Checked when production changes, and at most every two minutes otherwise.
    private func refreshPending() async {
        guard let tokenSource = githubToken, let token = await tokenSource() else { return }
        let client = PendingCommitsClient(token: token)
        let latest = productionHeads()
        var next = pending.filter { latest[$0.key] != nil }
        var nextCI = ci.filter { latest[$0.key] != nil }
        for (key, d) in latest {
            guard let commit = d.commit,
                  let repo = await repository(for: d, key: key, token: token),
                  let branch = await branch(for: d, repo: repo, client: client) else { continue }
            if let status = await checkCI(key: key, repo: repo, branch: branch, token: token) { nextCI[key] = status }
            if let last = pendingCheckedAt[key], last.sha == commit.sha,
               Date().timeIntervalSince(last.at) < Self.pendingInterval { continue }
            let tagKey = "\(key)@\(commit.sha)"
            guard let answer = try? await client.pending(repository: repo, sha: commit.sha, branch: branch,
                                                         etag: compareTags[tagKey]) else { continue }
            if let result = answer.result { next[key] = result }
            if let tag = answer.etag { compareTags = compareTags.filter { !$0.key.hasPrefix(key + "@") }; compareTags[tagKey] = tag }
            pendingCheckedAt[key] = (commit.sha, Date())
        }
        if next != pending { pending = next }
        if nextCI != ci { ci = nextCI }
    }

    /// Each project's production deployment that came from a commit, from all of history:
    /// a quiet project's production is older than the 60 cards shown.
    private func productionHeads() -> [String: Deployment] {
        var latest: [String: Deployment] = [:]
        for d in history where connected.contains(d.provider) && visible(d) && d.target.isProduction && d.state == .ready && d.commit != nil && d.releaseKind?.isConfig != true {
            let key = "\(d.provider.rawValue):\(d.project)"
            if latest[key] == nil { latest[key] = d }
        }
        return latest
    }

    /// Vercel says which branch production builds from; Heroku does not, so the default branch.
    private func branch(for d: Deployment, repo: String, client: PendingCommitsClient) async -> String? {
        if d.provider == .vercel, let ref = d.commit?.ref { return ref }
        if defaultBranches[repo] == nil { defaultBranches[repo] = try? await client.defaultBranch(repo) }
        return defaultBranches[repo]
    }

    /// The branch's workflow runs, at most every five minutes, with an ETag so an unchanged
    /// list is free. nil keeps what was known.
    private func checkCI(key: String, repo: String, branch: String, token: String) async -> CIStatus? {
        guard Defaults[.deployWatchCI] else { return nil }
        if let at = ciCheckedAt[key], Date().timeIntervalSince(at) < Self.pendingInterval { return nil }
        let tagKey = "\(repo)@\(branch)"
        guard let answer = try? await CIClient(token: token).runs(repository: repo, branch: branch, etag: ciTags[tagKey]) else { return nil }
        ciCheckedAt[key] = Date()
        if let tag = answer.etag { ciTags[tagKey] = tag }
        // A 304 still gets judged again: "stale after two weeks" moves with the clock.
        guard let runs = answer.runs ?? ciRuns[tagKey] else { return nil }
        ciRuns[tagKey] = runs
        return CIParser.status(WorkflowWatch.droppingDisabled(runs, repository: repo, disabled: Defaults[.disabledWorkflows]),
                               repository: repo, branch: branch)
    }
    private var ciRuns: [String: [CIRun]] = [:]

    /// Judges the runs already fetched again, after a workflow was disabled.
    func rejudgeCI() {
        let disabled = Defaults[.disabledWorkflows]
        var next = ci
        for (key, status) in ci {
            guard let runs = ciRuns["\(status.repository)@\(status.branch)"] else { continue }
            next[key] = CIParser.status(WorkflowWatch.droppingDisabled(runs, repository: status.repository, disabled: disabled),
                                        repository: status.repository, branch: status.branch)
        }
        if next != ci { ci = next }
    }

    /// The failed step's log for an opened CI row, fetched once per run.
    func loadCILog(_ run: CIRun, status: CIStatus) async {
        guard ciLogs[run.id] == nil, let tokenSource = githubToken, let token = await tokenSource() else { return }
        ciLogs[run.id] = await CIClient(token: token).failureLog(repository: status.repository, run: run)
    }

    func copyCIPrompt(_ run: CIRun, status: CIStatus) async {
        await loadCILog(run, status: status)
        DeployCommands.copy(CIPrompt.text(run, status: status, log: ciLogs[run.id]))
    }

    /// The CI state of a GitHub repository, from whichever project deploys it.
    func ci(forRepository repo: String) -> CIStatus? {
        ci.values.first { $0.repository.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// Vercel names the repository; for a Heroku app it is found once by searching its commit.
    private func repository(for d: Deployment, key: String, token: String) async -> String? {
        if let repo = d.commit?.repository { return repo }
        if let known = Defaults[.deployRepoMap][key] { return known }
        // Only a full SHA: a short one matches commits in strangers' public repositories
        // ("fee0653a" did, on 2026-11-02).
        guard let sha = d.commit?.sha, sha.count == 40 else { return nil }
        var components = URLComponents(string: "https://api.github.com/search/commits")!
        components.queryItems = [URLQueryItem(name: "q", value: "hash:\(sha)")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (object["items"] as? [[String: Any]])?.first,
              let repo = (item["repository"] as? [String: Any])?["full_name"] as? String else { return nil }
        Defaults[.deployRepoMap][key] = repo
        return repo
    }

    private var myLogins: Set<String> {
        Set([githubLogin, Defaults[.vercelAccount], Defaults[.herokuAccount]].compactMap { $0?.lowercased() })
    }

    private func visible(_ d: Deployment) -> Bool {
        if Defaults[.deployHiddenProjects].contains("\(d.provider.rawValue):\(d.project)") { return false }
        if !Defaults[.deployShowPreviews], !d.target.isProduction { return false }
        return true
    }

    func recompute() {
        deployments = Array(history.filter { connected.contains($0.provider) && visible($0) }.prefix(60))
    }

    /// Every project seen, for the Settings picker.
    var knownProjects: [String] {
        Array(Set(history.map { "\($0.provider.rawValue):\($0.project)" })).sorted()
    }

    // MARK: seen

    func markSeen(_ ids: [String]) {
        seen.formUnion(ids)
        let recent = Set(history.prefix(500).map(\.id))
        Defaults[.deploySeen] = Array(seen.intersection(recent))
        onChange?()
    }

    func markAllSeen() { markSeen(deployments.map(\.id)) }
    var unseenCount: Int { deployments.filter { $0.state.isFinished && !seen.contains($0.id) }.count }

    // MARK: actions (opt-in, confirmed by the caller)

    func redeploy(_ d: Deployment) async throws {
        guard let client = client(for: d.provider) else { return }
        try await client.redeploy(d)
        refresh()
    }

    func rollback(to d: Deployment) async throws {
        guard let client = client(for: d.provider) else { return }
        try await client.rollback(to: d)
        refresh()
    }

    // MARK: relay

    /// With a relay configured, a webhook arriving there triggers a poll within seconds.
    func startRelay() {
        relayLoop?.cancel()
        let address = Defaults[.deployRelayURL].trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: address), base.scheme == "https" else { return }
        relayLoop = Task { [weak self] in
            var since = Date().timeIntervalSince1970
            while !Task.isCancelled {
                var components = URLComponents(url: base.appendingPathComponent("events"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "since", value: String(Int(since)))]
                if let url = components.url,
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = object["count"] as? Int {
                    if let latest = object["latest"] as? Double { since = max(since, latest) }
                    if count > 0 { self?.refresh() }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
