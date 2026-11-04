import Foundation

/// Vercel REST API, with a personal access token. https://vercel.com/docs/rest-api
struct VercelClient: DeployClient {
    let token: String
    /// Team scope; nil means the personal account.
    var teamID: String?
    var base = URL(string: "https://api.vercel.com")!
    var provider: DeployProvider { .vercel }

    /// The list can leave out `ready` (seen on live accounts), and without it there is no build
    /// time. Finished deployments without one are looked up one by one, a few per poll.
    func recent(limit: Int = 40, timed: Set<String> = []) async throws -> [Deployment] {
        let data = try await get("/v6/deployments", ["limit": "\(limit)"])
        var list = try VercelParser.deployments(data, teamSlug: nil)
        let missing = list.indices.filter {
            list[$0].state.isFinished && list[$0].readyAt == nil && !timed.contains(list[$0].id)
        }.prefix(Self.detailLookupsPerPoll)
        let details = await withTaskGroup(of: (Int, Deployment?).self) { group in
            for index in missing {
                let id = list[index].nativeID
                group.addTask {
                    guard let data = try? await get("/v13/deployments/\(id)", [:]),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (index, nil) }
                    return (index, VercelParser.deployment(object))
                }
            }
            var found: [(Int, Deployment?)] = []
            for await pair in group { found.append(pair) }
            return found
        }
        for (index, detail) in details {
            guard let detail else { continue }
            list[index].readyAt = detail.readyAt
            if list[index].projectID == nil { list[index].projectID = detail.projectID }
        }
        return list
    }

    static let detailLookupsPerPoll = 10

    /// The teams the token can see, for picking a scope.
    func teams() async throws -> [(id: String, name: String)] {
        let data = try await get("/v2/teams", [:])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["teams"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let id = t["id"] as? String else { return nil }
            return (id, t["name"] as? String ?? t["slug"] as? String ?? id)
        }
    }

    func projects() async throws -> [DeployProject] {
        let data = try await get("/v9/projects", ["limit": "100"])
        return try VercelParser.projects(data)
    }

    func failureSummary(for deployment: Deployment) async -> String? {
        guard let data = try? await get("/v3/deployments/\(deployment.nativeID)/events",
                                        ["limit": "-1", "direction": "backward"]) else { return nil }
        return VercelParser.failureLine(data)
    }

    func logLines(for deployment: Deployment, limit: Int) async -> [String] {
        guard let data = try? await get("/v3/deployments/\(deployment.nativeID)/events",
                                        ["limit": "\(max(limit * 2, 50))", "direction": "backward"]) else { return [] }
        return VercelParser.logLines(data, limit: limit)
    }

    func whoAmI() async throws -> String {
        let data = try await get("/v2/user", [:])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let user = object?["user"] as? [String: Any]
        return (user?["username"] as? String) ?? (user?["email"] as? String) ?? "Vercel"
    }

    /// Builds the same source again, to the same target.
    func redeploy(_ deployment: Deployment) async throws {
        var body: [String: Any] = ["name": deployment.project, "deploymentId": deployment.nativeID]
        if deployment.target.isProduction { body["target"] = "production" }
        _ = try await send("POST", "/v13/deployments", body: body)
    }

    /// Instant rollback: points production back at this deployment without a build.
    func rollback(to deployment: Deployment) async throws {
        guard deployment.target.isProduction, deployment.state == .ready else {
            throw DeployError.unsupported("Only a ready production deployment can be rolled back to.")
        }
        let project = deployment.projectID ?? deployment.project
        _ = try await send("POST", "/v9/projects/\(project)/rollback/\(deployment.nativeID)", body: nil)
    }

    // MARK: HTTP

    private func url(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let teamID, !teamID.isEmpty { items.append(URLQueryItem(name: "teamId", value: teamID)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> Data {
        try await send("GET", path, query: query, body: nil)
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:],
                      body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await DeployHTTP.send(request, provider: .vercel)
    }
}

/// Pure parsing, tested against recorded responses.
enum VercelParser {
    static func deployments(_ data: Data, teamSlug: String?) throws -> [Deployment] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["deployments"] as? [[String: Any]] else { return [] }
        return list.compactMap(deployment)
    }

    static func deployment(_ d: [String: Any]) -> Deployment? {
        guard let uid = d["uid"] as? String ?? d["id"] as? String else { return nil }
        let name = d["name"] as? String ?? "project"
        let created = (d["created"] as? Double ?? d["createdAt"] as? Double).map(date) ?? Date()
        let rawState = (d["readyState"] as? String ?? d["state"] as? String ?? "").uppercased()
        let state: DeployState = switch rawState {
        case "READY": .ready
        case "ERROR": .failed
        case "CANCELED": .canceled
        case "BUILDING", "INITIALIZING": .building
        default: .queued
        }
        let target: DeployTarget = switch d["target"] as? String {
        case "production": .production
        case nil, "preview": .preview
        case let other?: .other(other)
        }
        let meta = d["meta"] as? [String: Any] ?? [:]
        var commit: DeployCommit?
        if let sha = meta["githubCommitSha"] as? String ?? meta["gitlabCommitSha"] as? String
            ?? meta["bitbucketCommitSha"] as? String {
            let org = meta["githubCommitOrg"] as? String ?? meta["githubOrg"] as? String
            let repo = meta["githubCommitRepo"] as? String ?? meta["githubRepo"] as? String
            commit = DeployCommit(
                sha: sha,
                ref: meta["githubCommitRef"] as? String,
                message: meta["githubCommitMessage"] as? String,
                repository: org.flatMap { o in repo.map { "\(o)/\($0)" } },
                pullRequest: (meta["githubPrId"] as? String).flatMap(Int.init) ?? meta["githubPrId"] as? Int
            )
        }
        let creator = (d["creator"] as? [String: Any]).flatMap {
            $0["githubLogin"] as? String ?? $0["username"] as? String
        }
        let ready = (d["ready"] as? Double).map(date)
        let host = d["url"] as? String
        return Deployment(
            id: "vercel:\(uid)",
            provider: .vercel,
            project: name,
            projectID: d["projectId"] as? String ?? (d["project"] as? [String: Any])?["id"] as? String,
            target: target,
            state: state,
            url: host.flatMap { URL(string: "https://\($0)") },
            dashboardURL: (d["inspectorUrl"] as? String).flatMap(URL.init(string:)),
            commit: commit,
            creator: creator,
            createdAt: created,
            readyAt: state.isFinished ? ready : nil,
            failureSummary: d["errorMessage"] as? String,
            nativeID: uid
        )
    }

    static func projects(_ data: Data) throws -> [DeployProject] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["projects"] as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? String, let name = p["name"] as? String else { return nil }
            return DeployProject(id: id, name: name, provider: .vercel)
        }
    }

    /// Build log text in time order; events arrive newest first with `direction=backward`.
    static func logLines(_ data: Data, limit: Int) -> [String] {
        guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        // Events sharing a millisecond are common (seen live); the response's own order,
        // reversed, breaks the tie, since Swift's sort is not stable.
        let ordered = Array(events.reversed()).enumerated().sorted { a, b in
            let ta = a.element["created"] as? Double ?? 0, tb = b.element["created"] as? Double ?? 0
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
        let lines = ordered.flatMap { event -> [String] in
            let text = (event["text"] as? String) ?? ((event["payload"] as? [String: Any])?["text"] as? String) ?? ""
            return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return Array(lines.map(LogText.clean).filter { !$0.isEmpty }.suffix(limit))
    }

    /// The most telling line of a failed build log: the last one that mentions an error.
    static func failureLine(_ data: Data) -> String? {
        guard let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        // Fetched with direction=backward, so newest first; the picker wants time order.
        let ordered = events.enumerated().sorted { a, b in
            let ta = a.element["created"] as? Double ?? 0, tb = b.element["created"] as? Double ?? 0
            return ta != tb ? ta < tb : a.offset > b.offset
        }.map(\.element)
        let lines: [String] = ordered.compactMap { event in
            (event["text"] as? String) ?? ((event["payload"] as? [String: Any])?["text"] as? String)
        }
        return FailureLine.pick(lines)
    }

    private static func date(_ millis: Double) -> Date { Date(timeIntervalSince1970: millis / 1000) }
}

enum LogText {
    /// Strips terminal colour codes and trailing space.
    static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Picks one line from a build log to explain a failure.
enum FailureLine {
    static func pick(_ lines: [String]) -> String? {
        let cleaned = lines.flatMap { $0.split(separator: "\n").map(String.init) }
            .map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let markers = ["error", "failed", "err!", "cannot", "not found", "exit code"]
        // Vercel's generic trailer, `Error: [BUILD_UTILS_SPAWN_1] Command "…" exited with 1`, only
        // repeats the build command; the cause is printed before it.
        func isTrailer(_ lower: String) -> Bool {
            lower.contains("build_utils_spawn") || (lower.contains("command \"") && lower.contains("exited with"))
        }
        let hit = cleaned.last { line in
            let lower = line.lowercased()
            return markers.contains { lower.contains($0) } && !isTrailer(lower)
        } ?? cleaned.last { !isTrailer($0.lowercased()) } ?? cleaned.last
        return hit.map { String($0.prefix(240)) }
    }
}
