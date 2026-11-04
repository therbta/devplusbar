import Foundation
import Testing
@testable import DevPlusBar

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func run(_ id: Int, workflow: Int = 1, _ conclusion: String?, hoursAgo: Double,
                 status: String = "completed", event: String = "schedule") -> CIRun {
    CIRun(id: id, workflow: "Verify live", workflowID: workflow, event: event, status: status,
          conclusion: conclusion, sha: "abc", createdAt: now.addingTimeInterval(-hoursAgo * 3600),
          url: URL(string: "https://github.com/me/site/actions/runs/\(id)"))
}

private func repo(_ name: String, daysAgo: Double, archived: Bool = false) -> CIClient.OwnedRepository {
    CIClient.OwnedRepository(fullName: "me/\(name)", name: name, defaultBranch: "main",
                             pushedAt: now.addingTimeInterval(-daysAgo * 86_400), archived: archived)
}

@Suite("WorkflowWatch")
struct WorkflowWatchTests {
    private let key = WorkflowWatch.key("me/site", 1)

    private func changes(_ previous: WorkflowWatch.State, _ runs: [CIRun]) -> (events: [WorkflowFailure], next: WorkflowWatch.State) {
        WorkflowWatch.changes(previous: previous, repository: "me/site", branch: "main", runs: runs, now: now)
    }

    @Test("a workflow seen for the first time sets the baseline quietly") func firstSighting() {
        let result = changes([:], [run(2, "failure", hoursAgo: 1)])
        #expect(result.events.isEmpty)
        #expect(result.next[key] == true)
    }

    @Test("green to red is news") func turnsRed() {
        let result = changes([key: false], [run(2, "failure", hoursAgo: 1), run(1, "success", hoursAgo: 7)])
        #expect(result.events.map(\.run.id) == [2])
        #expect(result.next[key] == true)
    }

    @Test("staying red says nothing more") func staysRed() {
        #expect(changes([key: true], [run(3, "failure", hoursAgo: 1)]).events.isEmpty)
    }

    @Test("red to green is quiet and resets the baseline") func recovers() {
        let result = changes([key: true], [run(3, "success", hoursAgo: 1)])
        #expect(result.events.isEmpty)
        #expect(result.next[key] == false)
    }

    @Test("running, cancelled and skipped runs keep the last verdict") func undecided() {
        let result = changes([key: false], [run(4, nil, hoursAgo: 0.1, status: "in_progress"),
                                            run(3, "cancelled", hoursAgo: 1), run(2, "success", hoursAgo: 6)])
        #expect(result.events.isEmpty)
        #expect(result.next[key] == false)
    }

    @Test("timed out counts as failing") func timedOut() {
        #expect(changes([key: false], [run(2, "timed_out", hoursAgo: 1)]).events.count == 1)
    }

    @Test("a workflow quiet for two weeks is left alone") func stale() {
        let result = changes([key: false], [run(2, "failure", hoursAgo: 15 * 24)])
        #expect(result.events.isEmpty)
        #expect(result.next[key] == nil)
    }

    @Test("other repositories' verdicts pass through") func otherRepositories() {
        let other = WorkflowWatch.key("me/other", 9)
        let result = changes([other: true, key: false], [run(2, "success", hoursAgo: 1)])
        #expect(result.next[other] == true)
    }

    @Test("each workflow is judged on its own") func perWorkflow() {
        let second = WorkflowWatch.key("me/site", 2)
        let result = changes([key: false, second: false],
                             [run(2, workflow: 1, "failure", hoursAgo: 1), run(3, workflow: 2, "success", hoursAgo: 1)])
        #expect(result.events.map(\.run.workflowID) == [1])
    }

    @Test("watched: recent, not archived, newest first") func watchedRepositories() {
        let list = [repo("old", daysAgo: 40), repo("gone", daysAgo: 1, archived: true),
                    repo("a", daysAgo: 3), repo("b", daysAgo: 1)]
        #expect(WorkflowMonitor.watched(list, settings: Settings(), now: now).map(\.name) == ["b", "a"])
    }

    @Test("watched: the repository list blocks or allows") func repositoryList() {
        let list = [repo("a", daysAgo: 1), repo("b", daysAgo: 2)]
        var settings = Settings()
        settings.repoList = ["me/a"]
        #expect(WorkflowMonitor.watched(list, settings: settings, now: now).map(\.name) == ["b"])
        settings.repoListIsAllowList = true
        #expect(WorkflowMonitor.watched(list, settings: settings, now: now).map(\.name) == ["a"])
    }

    @Test("owned repositories: forks and undated entries are dropped") func parsesRepositories() {
        let json = """
        [{"full_name":"me/site","name":"site","default_branch":"trunk","pushed_at":"2026-11-03T06:00:00Z","archived":false,"fork":false},
         {"full_name":"me/fork","name":"fork","default_branch":"main","pushed_at":"2026-11-03T06:00:00Z","fork":true},
         {"full_name":"me/empty","name":"empty","fork":false}]
        """
        let repos = CIParser.ownedRepositories(Data(json.utf8))
        #expect(repos.map(\.fullName) == ["me/site"])
        #expect(repos.first?.defaultBranch == "trunk")
    }
}
