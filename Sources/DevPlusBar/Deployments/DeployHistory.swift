import Foundation

/// Every deployment seen in the last 90 days, kept on disk so charts survive a relaunch.
/// One JSON file; a few thousand rows load in milliseconds.
struct DeployHistory: Sendable {
    static let keepDays = 90
    static let cap = 5_000

    private(set) var byID: [String: Deployment] = [:]
    let url: URL

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DevPlusBar/deploys.json")
    }

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let list = try? Self.decoder.decode([Deployment].self, from: data) {
            byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var all: [Deployment] { byID.values.sorted { $0.createdAt > $1.createdAt } }

    /// Newer data wins, but a failure summary fetched earlier is kept.
    mutating func merge(_ polled: [Deployment]) {
        for var d in polled {
            if let old = byID[d.id] {
                if d.failureSummary == nil { d.failureSummary = old.failureSummary }
                if d.readyAt == nil, d.state == old.state { d.readyAt = old.readyAt }
                if d.projectID == nil { d.projectID = old.projectID }
                if d.crashedDynos == nil { d.crashedDynos = old.crashedDynos }
            }
            byID[d.id] = d
        }
    }

    mutating func setFailureSummary(_ summary: String, for id: String) {
        byID[id]?.failureSummary = summary
    }

    mutating func setCrashed(_ dynos: [String]?, for id: String) {
        byID[id]?.crashedDynos = dynos
    }

    mutating func remove(provider: DeployProvider) {
        byID = byID.filter { $0.value.provider != provider }
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        var kept = byID.values.filter { $0.createdAt >= cutoff }
        if kept.count > Self.cap {
            kept.sort { $0.createdAt > $1.createdAt }
            kept = Array(kept.prefix(Self.cap))
        }
        byID = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(all)
        try data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
