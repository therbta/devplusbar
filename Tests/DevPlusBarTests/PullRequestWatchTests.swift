import Foundation
import Testing
@testable import DevPlusBar

private func pr(_ n: Int, review: ReviewDecision? = nil, checks: CheckState? = nil,
                merge: MergeBlock? = nil, unknown: Bool = false) -> Item {
    Item(kind: .pullRequest, repository: "me/app", number: n, title: "PR \(n)",
         url: "https://github.com/me/app/pull/\(n)", createdAt: Date(), isDraft: false,
         authorLogin: "me", authorIsBot: false, reviewDecision: review, checks: checks,
         merge: merge, mergeUnknown: unknown)
}

@Suite("PullRequestWatch")
struct PullRequestWatchTests {

    @Test("a pull request seen for the first time is not news") func firstSighting() {
        let result = PullRequestWatch.changes(previous: [:], open: [pr(1, review: .approved)], merged: [])
        #expect(result.events.isEmpty)
        #expect(result.next[pr(1).url] == [.approved])
    }

    @Test("a signal turning on is news, turning off is not") func transitions() {
        let previous: [String: Set<PRSignal>] = [pr(1).url: [], pr(2).url: [.failing]]
        let result = PullRequestWatch.changes(
            previous: previous, open: [pr(1, review: .approved), pr(2, checks: .passing)], merged: [])
        #expect(result.events.map(\.event) == [.became(.approved)])
    }

    @Test("one notification per pull request, the most pressing") func mostPressing() {
        let result = PullRequestWatch.changes(
            previous: [pr(1).url: []], open: [pr(1, review: .approved, checks: .failing)], merged: [])
        #expect(result.events.map(\.event) == [.became(.failing)])
    }

    @Test("an unknown mergeability keeps the last conflict") func unknownKeepsConflict() {
        let previous: [String: Set<PRSignal>] = [pr(1).url: [.conflicts]]
        let quiet = PullRequestWatch.changes(previous: previous, open: [pr(1, unknown: true)], merged: [])
        #expect(quiet.events.isEmpty)
        let back = PullRequestWatch.changes(previous: quiet.next, open: [pr(1, merge: .conflicts)], merged: [])
        #expect(back.events.isEmpty)
    }

    @Test("a watched pull request that merged is news; others are not") func merged() {
        let result = PullRequestWatch.changes(
            previous: [pr(1).url: []], open: [], merged: [pr(1), pr(9)])
        #expect(result.events.map(\.event) == [.merged])
        #expect(result.next.isEmpty)
    }

    @Test("state survives storage") func roundTrip() {
        let state: [String: Set<PRSignal>] = ["a": [.approved, .failing]]
        #expect(PullRequestWatch.decode(PullRequestWatch.encode(state)) == state)
    }
}
