import Foundation

/// Asks GitHub how far the production branch is ahead of the commit production runs.
/// REST compare, with the GitHub token Dev+ Bar already has.
struct PendingCommitsClient: Sendable {
    let token: String
    var base = URL(string: "https://api.github.com")!

    /// With the ETag of the last answer, an unchanged comparison comes back as 304 (`nil`),
    /// which GitHub does not count against the rate limit.
    func pending(repository: String, sha: String, branch: String, etag: String?) async throws
        -> (result: PendingCommits?, etag: String?) {
        let (data, newTag) = try await get("/repos/\(repository)/compare/\(sha)...\(branch)", etag: etag)
        guard let data else { return (nil, etag) }
        return (try Self.parse(data, repository: repository, branch: branch), newTag)
    }

    func defaultBranch(_ repository: String) async throws -> String {
        let (data, _) = try await get("/repos/\(repository)", etag: nil)
        let object = try JSONSerialization.jsonObject(with: data ?? Data("{}".utf8)) as? [String: Any]
        return object?["default_branch"] as? String ?? "main"
    }

    static func parse(_ data: Data, repository: String, branch: String) throws -> PendingCommits {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let commits = (object["commits"] as? [[String: Any]]) ?? []
        // GitHub lists oldest first.
        let subjects = commits.reversed().compactMap { c -> String? in
            let message = (c["commit"] as? [String: Any])?["message"] as? String
            return message?.split(separator: "\n").first.map(String.init)
        }
        return PendingCommits(
            repository: repository, branch: branch,
            count: object["ahead_by"] as? Int ?? commits.count,
            subjects: Array(subjects.prefix(8)),
            compareURL: (object["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// nil data means 304 Not Modified.
    private func get(_ path: String, etag: String?) async throws -> (Data?, String?) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // URLSession's own cache would answer 304s itself and hide them; ask GitHub every time.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeployError.network("GitHub compare failed") }
        if http.statusCode == 304 { return (nil, etag) }
        guard (200..<300).contains(http.statusCode) else { throw DeployError.network("GitHub compare failed") }
        return (data, http.value(forHTTPHeaderField: "ETag"))
    }
}
