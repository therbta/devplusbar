import Foundation

/// Heroku Platform API v3, with an API key or an authorization token.
/// https://devcenter.heroku.com/articles/platform-api-reference
///
/// Heroku has no single "deployment": a build makes a slug, then a release runs it. Builds and
/// releases are merged here; a release without a build (a config change, a rollback) stands on
/// its own.
struct HerokuClient: DeployClient {
    let token: String
    /// App names to watch. Empty means the most recently updated apps.
    var apps: [String] = []
    var base = URL(string: "https://api.heroku.com")!
    var provider: DeployProvider { .heroku }
    static let defaultAppCap = 8

    func recent(limit: Int = 20, timed: Set<String> = []) async throws -> [Deployment] {
        let names = apps.isEmpty ? try await projects().prefix(Self.defaultAppCap).map(\.name) : apps
        return try await withThrowingTaskGroup(of: [Deployment].self) { group in
            for app in names {
                group.addTask {
                    async let builds = get("/apps/\(app)/builds", range: "created_at ..; order=desc, max=\(limit)")
                    async let releases = get("/apps/\(app)/releases", range: "version ..; order=desc, max=\(limit)")
                    return try HerokuParser.merge(app: app, builds: try await builds, releases: try await releases)
                }
            }
            var all: [Deployment] = []
            for try await list in group { all += list }
            return all.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func projects() async throws -> [DeployProject] {
        let data = try await get("/apps", range: "updated_at ..; order=desc, max=100")
        return try HerokuParser.apps(data)
    }

    func failureSummary(for deployment: Deployment) async -> String? {
        guard deployment.nativeID.hasPrefix("build:") else { return deployment.failureSummary }
        let id = deployment.nativeID.dropFirst("build:".count)
        guard let data = try? await get("/apps/\(deployment.project)/builds/\(id)", range: nil),
              let build = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (build["output_stream_url"] as? String).flatMap(URL.init(string:)),
              let (log, _) = try? await URLSession.shared.data(from: stream) else { return nil }
        return FailureLine.pick([String(decoding: log, as: UTF8.self)])
    }

    /// Dynos currently crashed, by name ("web.1").
    func crashedDynos(app: String) async throws -> [String] {
        let data = try await get("/apps/\(app)/dynos", range: nil)
        return HerokuParser.crashedDynos(data)
    }

    /// Heroku streams a running build's log at `output_stream_url` and keeps the connection open
    /// until the build ends, so this reads for a moment and keeps what arrived.
    func logLines(for deployment: Deployment, limit: Int) async -> [String] {
        guard deployment.nativeID.hasPrefix("build:") else { return [] }
        let id = deployment.nativeID.dropFirst("build:".count)
        guard let data = try? await get("/apps/\(deployment.project)/builds/\(id)", range: nil),
              let build = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (build["output_stream_url"] as? String).flatMap(URL.init(string:)) else { return [] }
        let reader = Task { () -> [String] in
            var lines: [String] = []
            guard let (bytes, _) = try? await URLSession.shared.bytes(from: stream) else { return lines }
            do {
                for try await line in bytes.lines {
                    lines.append(LogText.clean(line))
                    if lines.count > limit * 4 { lines.removeFirst(lines.count - limit) }
                }
            } catch {}
            return lines
        }
        let deadline = Task { try? await Task.sleep(for: .seconds(2.5)); reader.cancel() }
        let lines = await reader.value
        deadline.cancel()
        return Array(lines.filter { !$0.isEmpty }.suffix(limit))
    }

    func whoAmI() async throws -> String {
        let data = try await get("/account", range: nil)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["email"] as? String ?? "Heroku"
    }

    func redeploy(_ deployment: Deployment) async throws {
        throw DeployError.unsupported("Heroku builds from a push; redeploy by pushing again, or roll back to this release.")
    }

    /// Creates a new release that runs this release's slug and config.
    func rollback(to deployment: Deployment) async throws {
        guard let version = deployment.version else {
            throw DeployError.unsupported("This build never became a release.")
        }
        _ = try await send("POST", "/apps/\(deployment.project)/releases", range: nil,
                           body: ["release": "\(version)"])
    }

    private func get(_ path: String, range: String?) async throws -> Data {
        try await send("GET", path, range: range, body: nil)
    }

    private func send(_ method: String, _ path: String, range: String?, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.heroku+json; version=3", forHTTPHeaderField: "Accept")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await DeployHTTP.send(request, provider: .heroku)
    }
}

enum HerokuParser {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }

    /// `version_description` is a changelog, newest first: "  * Name: subject\n  * …".
    /// The first entry's subject is the message; plain descriptions pass through.
    static func subject(_ description: String) -> String {
        let first = description.split(separator: "\n").first.map(String.init) ?? description
        var line = first.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("* ") else { return description }
        line.removeFirst(2)
        if let colon = line.range(of: ": ") { line = String(line[colon.upperBound...]) }
        return line
    }

    static func crashedDynos(_ data: Data) -> [String] {
        let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return list.filter { $0["state"] as? String == "crashed" }.compactMap { $0["name"] as? String }.sorted()
    }

    static func apps(_ data: Data) throws -> [DeployProject] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { a in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            return DeployProject(id: id, name: name, provider: .heroku)
        }
    }

    static func merge(app: String, builds: Data, releases: Data) throws -> [Deployment] {
        let buildList = (try JSONSerialization.jsonObject(with: builds) as? [[String: Any]]) ?? []
        let releaseList = (try JSONSerialization.jsonObject(with: releases) as? [[String: Any]]) ?? []
        var releasesByID: [String: [String: Any]] = [:]
        var releasesBySlug: [String: [String: Any]] = [:]
        for r in releaseList {
            if let id = r["id"] as? String { releasesByID[id] = r }
            // A config change makes a new release on the same slug; the build belongs to the
            // first release that ran it, the lowest version.
            if let slug = (r["slug"] as? [String: Any])?["id"] as? String {
                let version = r["version"] as? Int ?? .max
                if version < (releasesBySlug[slug]?["version"] as? Int ?? .max) { releasesBySlug[slug] = r }
            }
        }
        var claimed: Set<String> = []
        let dashboard = URL(string: "https://dashboard.heroku.com/apps/\(app)/activity")

        var result: [Deployment] = buildList.compactMap { b in
            guard let id = b["id"] as? String, let created = date(b["created_at"]) else { return nil }
            let releaseRef = (b["release"] as? [String: Any])?["id"] as? String
            let slugRef = (b["slug"] as? [String: Any])?["id"] as? String
            let release = releaseRef.flatMap { releasesByID[$0] } ?? slugRef.flatMap { releasesBySlug[$0] }
            if let rid = release?["id"] as? String { claimed.insert(rid) }

            var state: DeployState = switch b["status"] as? String {
            case "succeeded": .ready
            case "failed": .failed
            default: .building
            }
            var readyAt = state.isFinished ? date(b["updated_at"]) : nil
            if state == .ready, let release {
                switch release["status"] as? String {
                case "pending": state = .building; readyAt = nil
                case "failed": state = .failed; readyAt = date(release["updated_at"])
                default: readyAt = date(release["updated_at"]) ?? readyAt
                }
            }
            let blob = b["source_blob"] as? [String: Any] ?? [:]
            let sha = blob["version"] as? String
            return Deployment(
                id: "heroku:\(app):build:\(id)",
                provider: .heroku,
                project: app,
                projectID: (b["app"] as? [String: Any])?["id"] as? String,
                target: .production,
                state: state,
                url: nil,
                dashboardURL: dashboard,
                commit: sha.map { DeployCommit(sha: $0, ref: nil, message: (blob["version_description"] as? String).map(Self.subject)) },
                creator: (b["user"] as? [String: Any])?["email"] as? String,
                createdAt: created,
                readyAt: readyAt,
                failureSummary: nil,
                version: release?["version"] as? Int,
                nativeID: "build:\(id)"
            )
        }

        for r in releaseList {
            guard let id = r["id"] as? String, !claimed.contains(id), let created = date(r["created_at"]) else { continue }
            let state: DeployState = switch r["status"] as? String {
            case "succeeded": .ready
            case "failed": .failed
            default: .building
            }
            let version = r["version"] as? Int
            let description = r["description"] as? String
            // "Deploy dfef9365": a code release whose build is not in the list (older than it, or
            // made by a pipeline promotion). It carries the short SHA.
            var commit: DeployCommit?
            if let description, description.hasPrefix("Deploy "),
               let sha = description.split(separator: " ").dropFirst().first,
               sha.allSatisfy(\.isHexDigit) {
                commit = DeployCommit(sha: String(sha))
            }
            result.append(Deployment(
                id: "heroku:\(app):release:\(id)",
                provider: .heroku,
                project: app,
                target: .production,
                state: state,
                url: nil,
                dashboardURL: dashboard,
                commit: commit,
                creator: (r["user"] as? [String: Any])?["email"] as? String,
                createdAt: created,
                // A release without a build has no build time to chart.
                readyAt: state.isFinished ? created : nil,
                failureSummary: nil,
                note: description.map { "v\(version ?? 0) · \($0)" },
                version: version,
                nativeID: "release:\(id)"
            ))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }
}
