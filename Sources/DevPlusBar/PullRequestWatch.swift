import Foundation

/// The parts of a pull request's state worth telling its author about.
enum PRSignal: String, Sendable, Hashable, CaseIterable {
    case conflicts, failing, changesRequested, approved

    static func of(_ item: Item) -> Set<PRSignal> {
        var signals: Set<PRSignal> = []
        if item.merge == .conflicts { signals.insert(.conflicts) }
        if item.checks == .failing { signals.insert(.failing) }
        switch item.reviewDecision {
        case .approved: signals.insert(.approved)
        case .changesRequested: signals.insert(.changesRequested)
        default: break
        }
        return signals
    }
}

/// Something that just happened to one of your pull requests.
enum PREvent: Sendable, Hashable {
    case became(PRSignal)
    case merged

    var title: String {
        switch self {
        case .became(.conflicts): "Merge conflict"
        case .became(.failing): "Checks failed"
        case .became(.changesRequested): "Changes requested"
        case .became(.approved): "Approved"
        case .merged: "Merged"
        }
    }
}

/// Compares your open pull requests with how they were last time and says what changed.
///
/// Only changes you would act on count: a signal turning on, or the pull request being merged.
/// A signal turning off (checks fixed, conflict resolved) is your own doing, so it stays quiet.
enum PullRequestWatch {

    static func changes(
        previous: [String: Set<PRSignal>],
        open: [Item],
        merged: [Item]
    ) -> (events: [(item: Item, event: PREvent)], next: [String: Set<PRSignal>]) {
        var events: [(Item, PREvent)] = []
        var next: [String: Set<PRSignal>] = [:]

        for item in open {
            var signals = PRSignal.of(item)
            let old = previous[item.url]
            // While GitHub is still working out mergeability it says nothing either way; keep
            // the last answer so a conflict does not vanish and come back as "new".
            if item.mergeUnknown, old?.contains(.conflicts) == true { signals.insert(.conflicts) }
            next[item.url] = signals
            // A pull request seen for the first time is not a change.
            guard let old else { continue }
            // One notification per pull request: the most pressing new signal.
            if let signal = PRSignal.allCases.first(where: { signals.contains($0) && !old.contains($0) }) {
                events.append((item, .became(signal)))
            }
        }
        for item in merged where previous[item.url] != nil && next[item.url] == nil {
            events.append((item, .merged))
        }
        return (events, next)
    }

    static func decode(_ stored: [String: [String]]) -> [String: Set<PRSignal>] {
        stored.mapValues { Set($0.compactMap(PRSignal.init(rawValue:))) }
    }

    static func encode(_ state: [String: Set<PRSignal>]) -> [String: [String]] {
        state.mapValues { $0.map(\.rawValue).sorted() }
    }
}
