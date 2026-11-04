import Foundation

/// Where a deployment came from.
enum DeployProvider: String, Codable, Sendable, CaseIterable, Hashable {
    case vercel
    case heroku

    var title: String {
        switch self {
        case .vercel: "Vercel"
        case .heroku: "Heroku"
        }
    }

    /// Keychain account holding this provider's token, next to the GitHub token.
    var keychainAccount: String { "\(rawValue)-token" }
}

/// One state machine for both providers.
enum DeployState: String, Codable, Sendable, Hashable {
    case queued
    case building
    case ready
    case failed
    case canceled

    var isActive: Bool { self == .queued || self == .building }
    var isFinished: Bool { !isActive }

    var title: String {
        switch self {
        case .queued: "Queued"
        case .building: "Building"
        case .ready: "Ready"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }
}

/// Production, preview, or a named environment (Vercel custom environment, Heroku pipeline stage).
enum DeployTarget: Codable, Sendable, Hashable {
    case production
    case preview
    case other(String)

    var isProduction: Bool { self == .production }

    var title: String {
        switch self {
        case .production: "Production"
        case .preview: "Preview"
        case .other(let name): name.capitalized
        }
    }
}

struct DeployCommit: Codable, Sendable, Hashable {
    var sha: String
    var ref: String?
    var message: String?
    /// "owner/name" on GitHub, when the provider knows it.
    var repository: String?
    /// The pull request the deployment was built for, when the provider says so.
    var pullRequest: Int?

    var shortSHA: String { String(sha.prefix(7)) }
    var firstLine: String? { message?.split(separator: "\n").first.map(String.init) }

    /// "#42" from the provider, else from a squash/merge subject: "Fix tax (#42)", "Merge pull request #42".
    var resolvedPullRequest: Int? {
        if let pullRequest { return pullRequest }
        guard let line = firstLine else { return nil }
        for pattern in [#"\(#(\d+)\)\s*$"#, #"^Merge pull request #(\d+)"#] {
            if let range = line.range(of: pattern, options: .regularExpression) {
                let digits = line[range].filter(\.isNumber)
                return Int(digits)
            }
        }
        return nil
    }
}

struct Deployment: Identifiable, Codable, Sendable, Hashable {
    /// Globally unique: "vercel:dpl_123", "heroku:app:build-uuid".
    let id: String
    let provider: DeployProvider
    /// Vercel project name or Heroku app name.
    let project: String
    /// Vercel project id or Heroku app id; needed by redeploy and rollback.
    var projectID: String? = nil
    let target: DeployTarget
    var state: DeployState
    var url: URL?
    var dashboardURL: URL?
    var commit: DeployCommit?
    var creator: String?
    let createdAt: Date
    var readyAt: Date?
    var failureSummary: String?
    /// A line describing a deployment that has no commit, such as a Heroku config release.
    var note: String? = nil
    /// Dynos found crashed shortly after this release went live ("web.1"); nil when fine.
    var crashedDynos: [String]? = nil
    /// Heroku release version, Vercel has none.
    var version: Int? = nil
    /// The provider's own id, without our prefix.
    var nativeID: String

    var duration: TimeInterval? { readyAt.map { max(0, $0.timeIntervalSince(createdAt)) } }

    var isCrashed: Bool { !(crashedDynos ?? []).isEmpty }

    /// What a release without a build did, read from Heroku's description.
    var releaseKind: ReleaseKind? {
        guard nativeID.hasPrefix("release:"), let note else { return nil }
        let text = note.split(separator: "·", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? note
        return ReleaseKind(description: text)
    }

    /// The GitHub pull request page this deployment came from, if it is known.
    var pullRequestURL: String? {
        guard let repo = commit?.repository, let number = commit?.resolvedPullRequest else { return nil }
        return "https://github.com/\(repo)/pull/\(number)"
    }
}

/// Heroku releases that are not builds.
enum ReleaseKind: Sendable, Hashable {
    /// "Set A, B config vars" / "Remove A config vars". Only the names; Heroku never sends values.
    case config(action: String, keys: [String])
    /// "Rollback to v2077"
    case rollback(version: Int?)
    /// "Deploy dfef9365": code whose build is not in the list.
    case deploy
    /// "Attach DATABASE (@ref:postgresql-…)", "Update REDIS by …" and the rest.
    case other(String)

    init(description: String) {
        let words = description.split(separator: " ").map(String.init)
        if let first = words.first, ["Set", "Remove", "Unset"].contains(first), description.hasSuffix("config vars") || description.hasSuffix("config var") {
            let names = words.dropFirst().prefix { $0 != "config" }.joined(separator: " ")
            let keys = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            self = .config(action: first == "Set" ? "Set" : "Removed", keys: keys)
        } else if description.hasPrefix("Rollback to v") {
            self = .rollback(version: Int(description.dropFirst("Rollback to v".count).prefix { $0.isNumber }))
        } else if description.hasPrefix("Deploy ") {
            self = .deploy
        } else {
            self = .other(description)
        }
    }

    var isConfig: Bool { if case .config = self { true } else { false } }
}

/// Commits on the production branch that production is not running yet.
struct PendingCommits: Sendable, Hashable {
    let repository: String
    let branch: String
    let count: Int
    /// Newest first, subjects only.
    let subjects: [String]
    let compareURL: URL?
}

/// A change worth telling someone about.
struct DeployTransition: Sendable, Hashable {
    let deployment: Deployment
    /// nil when the deployment was first seen.
    let from: DeployState?
    let to: DeployState
}

/// What a provider client can do. Both clients are plain structs around a token.
protocol DeployClient: Sendable {
    var provider: DeployProvider { get }
    /// `timed`: ids whose finish time is already known, so they need no detail lookup.
    func recent(limit: Int, timed: Set<String>) async throws -> [Deployment]
    func projects() async throws -> [DeployProject]
    func failureSummary(for deployment: Deployment) async -> String?
    /// The last `limit` lines of the build log, oldest first; empty when there is none.
    func logLines(for deployment: Deployment, limit: Int) async -> [String]
    /// Who the token belongs to; validates it.
    func whoAmI() async throws -> String
    func redeploy(_ deployment: Deployment) async throws
    func rollback(to deployment: Deployment) async throws
}

struct DeployProject: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let provider: DeployProvider
}

enum DeployError: Error, LocalizedError, Equatable {
    case unauthorized(DeployProvider)
    case rateLimited(DeployProvider, Date?)
    case http(DeployProvider, Int)
    case network(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let p): "\(p.title) rejected the token. Reconnect it in Settings › Deployments."
        case .rateLimited(let p, _): "\(p.title) rate limit reached; trying again later."
        case .http(let p, let code): "\(p.title) answered HTTP \(code)."
        case .network(let message): message
        case .unsupported(let message): message
        }
    }
}

/// Shared HTTP plumbing for both clients.
enum DeployHTTP {
    static func send(_ request: URLRequest, provider: DeployProvider,
                     session: URLSession = .shared) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DeployError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DeployError.network("No response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw DeployError.unauthorized(provider)
        case 429:
            let reset = (http.value(forHTTPHeaderField: "x-ratelimit-reset")).flatMap(TimeInterval.init)
                .map { Date(timeIntervalSince1970: $0) }
            throw DeployError.rateLimited(provider, reset ?? Date().addingTimeInterval(60))
        default: throw DeployError.http(provider, http.statusCode)
        }
    }
}
