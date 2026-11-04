import Foundation

/// Turns successive polls into state changes. Pure, so it is tested without a network.
///
/// The first poll of a provider only records what is there: launching the app must not replay
/// a day of deployments as notifications.
struct DeployTracker: Sendable {
    private(set) var known: [String: DeployState] = [:]
    private(set) var seeded: Set<DeployProvider> = []

    /// Records `polled` and returns what changed since the last poll of that provider.
    mutating func ingest(_ polled: [Deployment], from provider: DeployProvider) -> [DeployTransition] {
        let first = !seeded.contains(provider)
        seeded.insert(provider)
        var changes: [DeployTransition] = []
        for deployment in polled where deployment.provider == provider {
            let previous = known[deployment.id]
            known[deployment.id] = deployment.state
            guard !first, previous != deployment.state else { continue }
            // A poll that lands on an older state (an out-of-order response) is not news.
            if let previous, previous.isFinished, deployment.state.isActive { known[deployment.id] = previous; continue }
            changes.append(DeployTransition(deployment: deployment, from: previous, to: deployment.state))
        }
        return changes
    }

    mutating func forget(_ provider: DeployProvider) {
        seeded.remove(provider)
        known = known.filter { !$0.key.hasPrefix(provider.rawValue + ":") }
    }
}

/// What to do about one change, per the user's rules.
struct DeployAlert: Sendable, Hashable {
    enum Tone: String, Sendable { case success, failure, started }
    let transition: DeployTransition
    let notify: Bool
    let toast: Bool
    let tone: Tone?
    let timeSensitive: Bool
    /// A dyno crashed after this release went live; the transition itself was ready → ready.
    var crash = false
}

struct DeployAlertRules: Sendable, Equatable {
    var productionStarted = false
    var productionReady = true
    var productionFailed = true
    var previewReady = false
    var previewFailed = true
    var toastPreviews = true
    var mineReady = true
    var slowBuilds = true
    var sounds = true

    /// A build slower than this many times the project's median is called out.
    static let slowFactor = 2.0

    func alerts(for changes: [DeployTransition], myLogins: Set<String>,
                medians: [String: TimeInterval]) -> [DeployAlert] {
        changes.compactMap { change in
            let d = change.deployment
            let prod = d.target.isProduction
            let mine = d.creator.map { myLogins.contains($0.lowercased()) } ?? false
            switch change.to {
            case .building, .queued:
                // Once per deployment: when it first appears, not again at queued → building.
                guard change.from == nil, prod else { return nil }
                return DeployAlert(transition: change, notify: productionStarted, toast: true,
                                   tone: productionStarted && sounds ? .started : nil, timeSensitive: false)
            case .ready:
                var slow = false
                if slowBuilds, let duration = d.duration, let median = medians[d.project], median > 0 {
                    slow = duration > median * Self.slowFactor
                }
                let notify = (prod && productionReady) || (!prod && previewReady) || (mine && mineReady) || slow
                let toast = prod || toastPreviews
                guard notify || toast else { return nil }
                return DeployAlert(transition: change, notify: notify, toast: toast,
                                   tone: sounds && (prod || mine) ? .success : nil, timeSensitive: false)
            case .failed:
                let notify = prod ? productionFailed : previewFailed
                return DeployAlert(transition: change, notify: notify, toast: true,
                                   tone: sounds ? .failure : nil, timeSensitive: prod)
            case .canceled:
                return nil
            }
        }
    }
}
