import Foundation
import Defaults

/// A workflow on one of your repositories' default branch that just went red.
struct WorkflowFailure: Sendable, Hashable {
    let repository: String
    let branch: String
    let run: CIRun

    var repositoryName: String { repository.split(separator: "/").last.map(String.init) ?? repository }
}

/// A workflow that failed every decisive run GitHub still returns, enough of them to say it
/// is not a fresh break: a schedule left running against something that no longer exists.
struct NeverPassedWorkflow: Sendable, Hashable, Identifiable {
    var id: String { WorkflowWatch.key(repository, workflowID) }
    let repository: String
    let workflowID: Int
    let workflow: String
    let event: String
    let failures: Int
    /// The oldest failure fetched; the streak may go back further.
    let since: Date
    let latest: CIRun

    var repositoryName: String { repository.split(separator: "/").last.map(String.init) ?? repository }
}

/// Compares each workflow's latest decisive run with how it stood last time and says which ones
/// started failing.
///
/// Only the turn from green to red is news. A workflow seen for the first time sets the baseline
/// quietly, and one that stays red says nothing more: a scheduled job failing every few hours
/// would otherwise notify every few hours.
enum WorkflowWatch {

    /// Key: "owner/repo#workflowID". Value: true while the workflow is failing.
    typealias State = [String: Bool]

    static func key(_ repository: String, _ workflowID: Int) -> String { "\(repository)#\(workflowID)" }

    static func changes(
        previous: State,
        repository: String,
        branch: String,
        runs: [CIRun],
        now: Date = Date()
    ) -> (events: [WorkflowFailure], next: State) {
        var events: [WorkflowFailure] = []
        // Workflows of other repositories pass through untouched.
        var next = previous.filter { !$0.key.hasPrefix(repository + "#") }

        let byWorkflow = Dictionary(grouping: runs.filter { !CIParser.ignoredEvents.contains($0.event) },
                                    by: \.workflowID)
        for (workflowID, list) in byWorkflow {
            // Same judgement as the Deploys pane: the newest run that decided something, and
            // nothing left quiet for two weeks.
            let decided = list.filter { !$0.isRunning && CIParser.decisive.contains($0.conclusion ?? "") }
                .sorted { $0.createdAt > $1.createdAt }
            guard let last = decided.first, now.timeIntervalSince(last.createdAt) < CIParser.staleAfter else { continue }
            let failing = last.conclusion != "success"
            let k = key(repository, workflowID)
            if failing, previous[k] == false {
                events.append(WorkflowFailure(repository: repository, branch: branch, run: last))
            }
            next[k] = failing
        }
        return (events.sorted { $0.run.createdAt > $1.run.createdAt }, next)
    }

    /// Fewer failures than this, all red, can still be a new workflow being set up.
    static let neverPassedAfter = 5

    /// Workflows whose every decisive run fetched failed, at least `neverPassedAfter` of them,
    /// and that still run: one quiet for two weeks is left alone, as everywhere else.
    static func neverPassed(repository: String, runs: [CIRun], now: Date = Date()) -> [NeverPassedWorkflow] {
        let byWorkflow = Dictionary(grouping: runs.filter { !CIParser.ignoredEvents.contains($0.event) }, by: \.workflowID)
        return byWorkflow.compactMap { workflowID, list -> NeverPassedWorkflow? in
            let decided = list.filter { !$0.isRunning && CIParser.decisive.contains($0.conclusion ?? "") }
                .sorted { $0.createdAt > $1.createdAt }
            guard let last = decided.first, decided.count >= neverPassedAfter,
                  !decided.contains(where: { $0.conclusion == "success" }),
                  now.timeIntervalSince(last.createdAt) < CIParser.staleAfter else { return nil }
            return NeverPassedWorkflow(repository: repository, workflowID: workflowID, workflow: last.workflow,
                                       event: last.event, failures: decided.count,
                                       since: decided.last?.createdAt ?? last.createdAt, latest: last)
        }
        .sorted { $0.failures > $1.failures }
    }

    /// Runs of workflows disabled from Dev+ Bar, from before they were disabled: GitHub keeps
    /// returning those, and they would keep the workflow red. A run after that means it was
    /// turned on again, and from then on it counts.
    static func droppingDisabled(_ runs: [CIRun], repository: String, disabled: [String: Double]) -> [CIRun] {
        guard !disabled.isEmpty else { return runs }
        return runs.filter { run in
            guard let at = disabled[key(repository, run.workflowID)] else { return true }
            return run.createdAt.timeIntervalSince1970 > at
        }
    }
}

/// Watches GitHub Actions on the default branch of the repositories you own and reports the
/// workflows that start failing. Runs from the regular refresh, at most every five minutes.
@MainActor
final class WorkflowMonitor: ObservableObject {
    static let shared = WorkflowMonitor()

    var onFailures: (([WorkflowFailure]) -> Void)?
    /// Workflows that have failed every run fetched, worst first.
    @Published private(set) var neverPassed: [NeverPassedWorkflow] = []
    /// The GitHub token, for disabling a workflow.
    var githubToken: (() async -> String?)?

    nonisolated static let interval: TimeInterval = 5 * 60
    nonisolated static let repositoryListInterval: TimeInterval = 60 * 60
    /// Repositories pushed to within this window are watched; older ones rarely run anything
    /// but a schedule, and those that do are usually long forgotten.
    nonisolated static let activeWithin: TimeInterval = 30 * 86_400
    nonisolated static let maxRepositories = 30

    private var checkedAt: Date?
    private var repositories: [CIClient.OwnedRepository] = []
    private var repositoriesAt: Date?
    private var etags: [String: String] = [:]
    private var runs: [String: [CIRun]] = [:]
    private var running = false

    func check(token: String, settings: Settings) {
        guard Defaults[.notifyWorkflowFailures], !running else { return }
        if let at = checkedAt, Date().timeIntervalSince(at) < Self.interval { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            let client = CIClient(token: token)
            if repositoriesAt.map({ Date().timeIntervalSince($0) > Self.repositoryListInterval }) ?? true,
               let list = try? await client.ownedRepositories() {
                repositories = list
                repositoriesAt = Date()
            }
            let watched = Self.watched(repositories, settings: settings)
            var state = Defaults[.workflowVerdicts].filter { entry in
                watched.contains { entry.key.hasPrefix($0.fullName + "#") }
            }
            var failures: [WorkflowFailure] = []
            var dead: [NeverPassedWorkflow] = []
            let disabled = Defaults[.disabledWorkflows]
            for repo in watched {
                let tagKey = "\(repo.fullName)@\(repo.defaultBranch)"
                // 100, the most one request returns: on a busy branch a daily schedule otherwise
                // has too few runs in the page to tell "never passed" from "new".
                guard let answer = try? await client.runs(repository: repo.fullName, branch: repo.defaultBranch,
                                                          etag: etags[tagKey], perPage: 100) else { continue }
                if let tag = answer.etag { etags[tagKey] = tag }
                // A 304 is judged again from what was fetched before.
                guard let fetched = answer.runs ?? runs[tagKey] else { continue }
                runs[tagKey] = fetched
                let list = WorkflowWatch.droppingDisabled(fetched, repository: repo.fullName, disabled: disabled)
                dead += WorkflowWatch.neverPassed(repository: repo.fullName, runs: list)
                let result = WorkflowWatch.changes(previous: state, repository: repo.fullName,
                                                   branch: repo.defaultBranch, runs: list)
                state = result.next
                failures += result.events
            }
            Defaults[.workflowVerdicts] = state
            let sortedDead = dead.sorted { $0.failures > $1.failures }
            if sortedDead != neverPassed { neverPassed = sortedDead }
            checkedAt = Date()
            if !failures.isEmpty { onFailures?(failures) }
        }
    }

    /// For screenshots.
    func loadDemo(neverPassed list: [NeverPassedWorkflow]) { neverPassed = list }

    /// Forgets everything; used when the account changes.
    func reset() {
        checkedAt = nil
        repositories = []
        repositoriesAt = nil
        etags = [:]
        runs = [:]
        neverPassed = []
        Defaults[.workflowVerdicts] = [:]
    }

    /// Turns the workflow off on GitHub, then stops counting its old runs here and in Deploys.
    func disable(_ workflow: NeverPassedWorkflow) async throws {
        guard let source = githubToken, let token = await source() else {
            throw DeployError.unsupported("Sign in to GitHub first.")
        }
        try await CIClient(token: token).disableWorkflow(repository: workflow.repository, id: workflow.workflowID)
        Defaults[.disabledWorkflows][workflow.id] = Date().timeIntervalSince1970
        Defaults[.workflowVerdicts][workflow.id] = nil
        neverPassed.removeAll { $0.id == workflow.id }
        DeployMonitor.shared.rejudgeCI()
    }

    /// Recently pushed, not archived, and inside the repository list's allow or block list.
    nonisolated static func watched(_ repositories: [CIClient.OwnedRepository], settings: Settings,
                        now: Date = Date()) -> [CIClient.OwnedRepository] {
        let listed = Set(settings.repoList.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        func isListed(_ repo: CIClient.OwnedRepository) -> Bool {
            listed.contains(repo.fullName.lowercased()) || listed.contains(repo.name.lowercased())
        }
        return repositories
            .filter { !$0.archived && now.timeIntervalSince($0.pushedAt) < activeWithin }
            .filter { settings.repoListIsAllowList ? isListed($0) : !isListed($0) }
            .sorted { $0.pushedAt > $1.pushedAt }
            .prefix(maxRepositories)
            .map { $0 }
    }
}
