import Foundation

/// One GitHub Actions run on a project's production branch.
struct CIRun: Sendable, Hashable, Identifiable {
    let id: Int
    let workflow: String
    let workflowID: Int
    let event: String
    /// queued, in_progress, completed.
    let status: String
    /// success, failure, cancelled, skipped, timed_out… once completed.
    let conclusion: String?
    let sha: String
    let createdAt: Date
    let url: URL?

    var isRunning: Bool { status != "completed" }
}

/// How long a workflow has been red: its unbroken run of decisive failures.
struct CIStreak: Sendable, Hashable {
    let failures: Int
    /// The oldest failure of the streak in the fetched runs.
    let since: Date
    /// Every decisive run fetched failed, so the streak may reach further back.
    let atLeast: Bool

    /// Every run fetched failed, and enough of them: see `WorkflowWatch.neverPassed`.
    var neverPassed: Bool { atLeast && failures >= WorkflowWatch.neverPassedAfter }

    /// Two failures in a row, or one older than a day, is a workflow left red, not a fresh break.
    func isStuck(now: Date = Date()) -> Bool { failures >= 2 || now.timeIntervalSince(since) > 86_400 }

    /// "35d+", "5h": the age alone, for a narrow column.
    func short(now: Date = Date()) -> String {
        let age = now.timeIntervalSince(since)
        let value = age >= 86_400 ? "\(Int(age / 86_400))d" : age >= 3600 ? "\(Int(age / 3600))h" : "\(max(1, Int(age / 60)))m"
        return value + (atLeast ? "+" : "")
    }

    /// "red for 4 days · 4 runs", "red for 3 hours · 2 runs".
    func text(now: Date = Date()) -> String {
        let age = now.timeIntervalSince(since)
        let span = age >= 86_400 ? "\(Int(age / 86_400)) day\(age >= 2 * 86_400 ? "s" : "")"
            : age >= 3600 ? "\(Int(age / 3600)) hour\(age >= 7200 ? "s" : "")" : "\(max(1, Int(age / 60))) min"
        return "red for \(atLeast ? "at least " : "")\(span) · \(failures)\(atLeast ? "+" : "") run\(failures == 1 ? "" : "s")"
    }
}

/// Where the production branch's workflows stand: each workflow judged by its latest run that
/// decided something (cancelled and skipped runs say nothing about the code).
struct CIStatus: Sendable, Hashable {
    let repository: String
    let branch: String
    /// Workflows whose latest decisive run failed, newest first.
    let failing: [CIRun]
    /// Workflows with a run going right now.
    let running: [CIRun]
    let passing: Int
    /// By failing run id.
    var streaks: [Int: CIStreak] = [:]

    var isFailing: Bool { !failing.isEmpty }
    /// Red for a new failure; amber when every red workflow has been red a while.
    var hasFreshBreak: Bool { failing.contains { !(streaks[$0.id]?.isStuck() ?? false) } }

    /// Fresh breaks first, newest first; workflows left red after them.
    func ordered(now: Date = Date()) -> [CIRun] {
        failing.sorted { a, b in
            let sa = streaks[a.id]?.isStuck(now: now) ?? false, sb = streaks[b.id]?.isStuck(now: now) ?? false
            return sa != sb ? !sa : a.createdAt > b.createdAt
        }
    }

    var summary: String {
        if let first = failing.first {
            return failing.count == 1 ? "\(first.workflow) failed on \(branch)"
                : "\(failing.count) workflows failing on \(branch)"
        }
        if !running.isEmpty { return "CI running on \(branch)" }
        return "CI passing on \(branch)"
    }
}

/// The failed step of a run, for the expanded row and the prompt.
struct CIFailureLog: Sendable, Hashable {
    let job: String?
    let step: String?
    let lines: [String]
    let url: URL?
}

enum CIParser {
    /// Events that run on the branch without being about its code: Dependabot's update jobs.
    static let ignoredEvents: Set<String> = ["dynamic"]
    static let decisive: Set<String> = ["success", "failure", "timed_out", "startup_failure"]
    /// A workflow that has not decided anything for two weeks is not part of today's picture.
    static let staleAfter: TimeInterval = 14 * 86_400

    static func runs(_ data: Data) -> [CIRun] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["workflow_runs"] as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let id = r["id"] as? Int, let workflowID = r["workflow_id"] as? Int else { return nil }
            return CIRun(id: id, workflow: r["name"] as? String ?? "Workflow", workflowID: workflowID,
                         event: r["event"] as? String ?? "", status: r["status"] as? String ?? "completed",
                         conclusion: r["conclusion"] as? String, sha: r["head_sha"] as? String ?? "",
                         createdAt: (r["created_at"] as? String).flatMap(date) ?? .distantPast,
                         url: (r["html_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func status(_ runs: [CIRun], repository: String, branch: String, now: Date = Date()) -> CIStatus {
        let byWorkflow = Dictionary(grouping: runs.filter { !ignoredEvents.contains($0.event) }, by: \.workflowID)
        var failing: [CIRun] = [], running: [CIRun] = [], passing = 0
        var streaks: [Int: CIStreak] = [:]
        for list in byWorkflow.values {
            let sorted = list.sorted { $0.createdAt > $1.createdAt }
            if let newest = sorted.first, newest.isRunning { running.append(newest) }
            let decided = sorted.filter { !$0.isRunning && decisive.contains($0.conclusion ?? "") }
            guard let last = decided.first, now.timeIntervalSince(last.createdAt) < staleAfter else { continue }
            if last.conclusion == "success" { passing += 1; continue }
            failing.append(last)
            let streak = decided.prefix { $0.conclusion != "success" }
            streaks[last.id] = CIStreak(failures: streak.count, since: streak.last?.createdAt ?? last.createdAt,
                                        atLeast: streak.count == decided.count)
        }
        return CIStatus(repository: repository, branch: branch,
                        failing: failing.sorted { $0.createdAt > $1.createdAt },
                        running: running.sorted { $0.createdAt > $1.createdAt }, passing: passing, streaks: streaks)
    }

    /// The failed step's own output from a job log: from the end of its header (the `env:`
    /// block GitHub prints) up to the error, without timestamps or colour.
    static func tail(_ log: String, limit: Int = 30) -> [String] {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = Substring(line)
            if s.count > 29, s.dropFirst(4).first == "-", let space = s.firstIndex(of: " "), s[s.startIndex..<space].hasSuffix("Z") {
                s = s[s.index(after: space)...]
            }
            return String(s).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        let errorAt = lines.firstIndex { $0.contains("##[error]") }
        let end = errorAt ?? lines.lastIndex { $0.hasPrefix("Post job cleanup") } ?? lines.count
        var start = 0
        if let header = lines[..<end].lastIndex(where: { $0.hasPrefix("##[endgroup]") || $0.hasPrefix("##[group]Run ") }) {
            start = header + 1
        }
        var picked = Array(lines[start..<end])
        if let errorAt {
            // Every error line of the step, minus the runner's generic exit-code trailer.
            picked += lines[errorAt...].prefix { !$0.hasPrefix("Post job cleanup") }
                .filter { $0.contains("##[error]") && !$0.contains("Process completed with exit code") }
                .map { $0.replacingOccurrences(of: "##[error]", with: "") }
        }
        let cleaned = picked.map(LogText.clean).filter { !$0.isEmpty && !$0.hasPrefix("##[") }
        return Array(cleaned.suffix(limit))
    }

    static func ownedRepositories(_ data: Data) -> [CIClient.OwnedRepository] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { r in
            guard let fullName = r["full_name"] as? String, let name = r["name"] as? String,
                  r["fork"] as? Bool != true,
                  let pushed = (r["pushed_at"] as? String).flatMap(date) else { return nil }
            return CIClient.OwnedRepository(fullName: fullName, name: name,
                                            defaultBranch: r["default_branch"] as? String ?? "main",
                                            pushedAt: pushed, archived: r["archived"] as? Bool ?? false)
        }
    }

    static func failedJob(_ data: Data) -> (id: Int, name: String, step: String?, url: URL?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]],
              let job = jobs.first(where: { ($0["conclusion"] as? String) == "failure" }),
              let id = job["id"] as? Int else { return nil }
        let step = (job["steps"] as? [[String: Any]])?.first { ($0["conclusion"] as? String) == "failure" }?["name"] as? String
        return (id, job["name"] as? String ?? "job", step, (job["html_url"] as? String).flatMap(URL.init(string:)))
    }

    private static func date(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
}

/// GitHub Actions over REST, with the token Dev+ Bar already has.
struct CIClient: Sendable {
    let token: String
    var base = URL(string: "https://api.github.com")!

    /// nil result means 304 Not Modified, which costs no rate limit.
    func runs(repository: String, branch: String, etag: String?, perPage: Int = 50) async throws -> (runs: [CIRun]?, etag: String?) {
        var components = URLComponents(url: base.appendingPathComponent("/repos/\(repository)/actions/runs"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "branch", value: branch), URLQueryItem(name: "per_page", value: String(perPage))]
        var request = authorized(components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeployError.network("GitHub Actions failed") }
        if http.statusCode == 304 { return (nil, etag) }
        guard (200..<300).contains(http.statusCode) else { throw DeployError.network("GitHub Actions answered \(http.statusCode)") }
        return (CIParser.runs(data), http.value(forHTTPHeaderField: "ETag"))
    }

    struct OwnedRepository: Sendable, Hashable {
        let fullName: String
        let name: String
        let defaultBranch: String
        let pushedAt: Date
        let archived: Bool
    }

    /// Repositories you own that are not forks, most recently pushed first. Forks are left out:
    /// GitHub keeps Actions off in them until their owner turns it on.
    func ownedRepositories() async throws -> [OwnedRepository] {
        var components = URLComponents(url: base.appendingPathComponent("/user/repos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "affiliation", value: "owner"),
                                 URLQueryItem(name: "sort", value: "pushed"),
                                 URLQueryItem(name: "per_page", value: "100")]
        let (data, response) = try await URLSession.shared.data(for: authorized(components.url!))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeployError.network("GitHub repositories failed")
        }
        return CIParser.ownedRepositories(data)
    }

    /// Stops the workflow from running, on schedule and on push, until it is enabled again.
    func disableWorkflow(repository: String, id: Int) async throws {
        var request = authorized(base.appendingPathComponent("/repos/\(repository)/actions/workflows/\(id)/disable"))
        request.httpMethod = "PUT"
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DeployError.network(code == 403 || code == 404
                ? "GitHub refused (\(code)): the sign-in Dev+ Bar uses cannot change Actions in \(repository)."
                : "GitHub answered \(code) when disabling the workflow.")
        }
    }

    func failureLog(repository: String, run: CIRun, limit: Int = 30) async -> CIFailureLog {
        let jobsURL = base.appendingPathComponent("/repos/\(repository)/actions/runs/\(run.id)/jobs")
        guard let (data, _) = try? await URLSession.shared.data(for: authorized(jobsURL)),
              let job = CIParser.failedJob(data) else { return CIFailureLog(job: nil, step: nil, lines: [], url: run.url) }
        // The log answer is a redirect to signed storage, which refuses a second credential.
        let logURL = base.appendingPathComponent("/repos/\(repository)/actions/jobs/\(job.id)/logs")
        var lines: [String] = []
        if let (logData, response) = try? await URLSession.shared.data(for: authorized(logURL), delegate: DropAuthOnRedirect()),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            lines = CIParser.tail(String(decoding: logData, as: UTF8.self), limit: limit)
        }
        return CIFailureLog(job: job.name, step: job.step, lines: lines, url: job.url ?? run.url)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }
}

private final class DropAuthOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        return next
    }
}

/// A self-contained prompt for a coding agent about a red workflow on the production branch.
enum CIPrompt {
    static func text(_ run: CIRun, status: CIStatus, log: CIFailureLog?) -> String {
        var out = ["The GitHub Actions workflow \"\(run.workflow)\" failed on \(status.branch) in \(status.repository).", ""]
        out.append("Commit: \(run.sha)")
        out.append("Trigger: \(run.event)")
        if let job = log?.job { out.append("Job: \(job)") }
        if let step = log?.step { out.append("Failed step: \(step)") }
        if let streak = status.streaks[run.id], streak.failures > 1 {
            out.append("History: \(streak.text()) (first failure in the fetched runs: \(ISO8601DateFormatter().string(from: streak.since))). "
                + "Look at what changed around the first failure, not only at the latest commit.")
        }
        if let url = log?.url ?? run.url { out.append("Run: \(url.absoluteString)") }
        if let lines = log?.lines, !lines.isEmpty {
            out += ["", "Last \(lines.count) lines of the failed step:", "```"] + lines + ["```"]
        }
        out += ["", "Check out \(status.branch) at that commit, reproduce the failing step locally with the same command "
            + "the workflow runs (read the workflow file under .github/workflows), fix the cause rather than the symptom, "
            + "and verify the step passes before proposing a push."]
        return out.joined(separator: "\n")
    }
}
