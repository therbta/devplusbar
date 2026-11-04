import Testing
import Foundation
@testable import DevPlusBar

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

@Suite("CI on the production branch")
struct CITests {
    /// Recorded from a real repository on 2026-11-02 (names scrubbed): scheduled runs, a
    /// cancelled-every-time deploy cron, Dependabot jobs and two red workflows.
    @Test func judgesEachWorkflowByItsLatestDecisiveRun() throws {
        let runs = CIParser.runs(try fixture("github-actions-runs-live"))
        #expect(runs.count == 30)
        let now = ISO8601DateFormatter().date(from: "2026-11-02T21:00:00Z")!
        let status = CIParser.status(runs, repository: "acme/app", branch: "main", now: now)
        #expect(status.failing.map(\.workflow) == ["Lifecycle", "Secrets"])
        // Deploy's cancelled crons say nothing; its last push succeeded.
        #expect(status.passing == 4)
        #expect(status.running.isEmpty)
        #expect(status.summary == "2 workflows failing on main")
        // Dependabot's failed update job is not the branch's CI.
        #expect(!status.failing.contains { $0.event == "dynamic" })
    }

    @Test func aFixedWorkflowStopsFailingAndOldOnesFadeOut() {
        func run(_ id: Int, _ workflow: Int, _ conclusion: String?, ago: TimeInterval, status: String = "completed") -> CIRun {
            CIRun(id: id, workflow: "W\(workflow)", workflowID: workflow, event: "push", status: status,
                  conclusion: conclusion, sha: "abc", createdAt: Date(timeIntervalSinceNow: -ago), url: nil)
        }
        let status = CIParser.status([
            run(1, 1, "failure", ago: 7200), run(2, 1, "success", ago: 600),      // fixed
            run(3, 2, "failure", ago: 20 * 86_400),                                // stale
            run(4, 3, nil, ago: 60, status: "in_progress"), run(5, 3, "failure", ago: 3600),
        ], repository: "a/b", branch: "main")
        #expect(status.failing.map(\.id) == [5])
        #expect(status.running.map(\.id) == [4])
        #expect(status.passing == 1)
    }

    /// The same recording: Secrets failed on both days in it, Lifecycle only today.
    @Test func streaksTellAStuckWorkflowFromAFreshBreak() throws {
        let runs = CIParser.runs(try fixture("github-actions-runs-live"))
        let now = ISO8601DateFormatter().date(from: "2026-11-02T21:00:00Z")!
        let status = CIParser.status(runs, repository: "acme/app", branch: "main", now: now)
        let secrets = try #require(status.failing.first { $0.workflow == "Secrets" })
        let lifecycle = try #require(status.failing.first { $0.workflow == "Lifecycle" })
        let stuck = try #require(status.streaks[secrets.id])
        #expect(stuck.failures == 2)
        #expect(stuck.atLeast)          // no success for it in the window
        #expect(stuck.isStuck(now: now))
        #expect(stuck.text(now: now) == "red for at least 1 day · 2+ runs")
        let fresh = try #require(status.streaks[lifecycle.id])
        #expect(!fresh.isStuck(now: now))
        #expect(status.ordered(now: now).map(\.workflow) == ["Lifecycle", "Secrets"])
    }

    @Test func streakStopsAtTheLastSuccess() {
        func run(_ id: Int, _ conclusion: String, ago: TimeInterval) -> CIRun {
            CIRun(id: id, workflow: "W", workflowID: 1, event: "push", status: "completed",
                  conclusion: conclusion, sha: "abc", createdAt: Date(timeIntervalSinceNow: -ago), url: nil)
        }
        let status = CIParser.status([run(1, "failure", ago: 600), run(2, "cancelled", ago: 1200),
                                      run(3, "failure", ago: 7200), run(4, "success", ago: 9000)],
                                     repository: "a/b", branch: "main")
        let streak = status.streaks[1]
        #expect(streak?.failures == 2)  // the cancelled run neither breaks nor extends it
        #expect(streak?.atLeast == false)
        #expect(streak?.text() == "red for 2 hours · 2 runs")
        #expect(!status.hasFreshBreak)
    }

    @Test func tailIsTheFailedStepWithoutHeaderOrTrailer() {
        let log = """
        2026-11-02T13:27:22.5766525Z ##[group]Run node scripts/migrate.js apply
        2026-11-02T13:27:22.5767332Z \u{1B}[36;1mnode scripts/migrate.js apply\u{1B}[0m
        2026-11-02T13:27:22.5795550Z env:
        2026-11-02T13:27:22.5797096Z   PGPASSWORD: postgres
        2026-11-02T13:27:22.5798467Z ##[endgroup]
        2026-11-02T13:27:23.8421455Z   \u{1B}[32m✓\u{1B}[0m 001-users.sql
        2026-11-02T13:27:23.9152747Z   \u{1B}[31m✗ 002-one-in-force.sql\u{1B}[0m
        2026-11-02T13:27:23.9153804Z     one-in-force: 26 rows would not end with exactly one active row
        2026-11-02T13:27:23.9268804Z ##[error]Process completed with exit code 1.
        2026-11-02T13:27:23.9416228Z Post job cleanup.
        2026-11-02T13:27:24.0455533Z [command]/usr/bin/git version
        """
        let tail = CIParser.tail(log)
        #expect(tail == ["✓ 001-users.sql", "✗ 002-one-in-force.sql",
                         "one-in-force: 26 rows would not end with exactly one active row"])
        #expect(!tail.contains { $0.contains("PGPASSWORD") })
    }

    @Test func tailKeepsRealErrorLines() {
        let log = """
        2026-11-02T10:00:00.0000000Z ##[group]Run npm test
        2026-11-02T10:00:00.1000000Z ##[endgroup]
        2026-11-02T10:00:01.0000000Z FAIL src/a.test.ts
        2026-11-02T10:00:02.0000000Z ##[error]TypeError: x is undefined
        2026-11-02T10:00:02.1000000Z ##[error]Process completed with exit code 1.
        """
        #expect(CIParser.tail(log) == ["FAIL src/a.test.ts", "TypeError: x is undefined"])
    }

    @Test func failedJobPicksTheFailedStep() throws {
        let data = Data("""
        {"jobs":[{"id":1,"name":"notify","conclusion":"success","steps":[]},
                 {"id":2,"name":"lifecycle","conclusion":"failure","html_url":"https://github.com/a/b/actions/runs/9/job/2",
                  "steps":[{"name":"Checkout","conclusion":"success"},{"name":"Apply migrations","conclusion":"failure"},
                           {"name":"Run","conclusion":"skipped"}]}]}
        """.utf8)
        let job = try #require(CIParser.failedJob(data))
        #expect(job.id == 2)
        #expect(job.step == "Apply migrations")
    }

    @Test func promptIsSelfContained() {
        let run = CIRun(id: 9, workflow: "Lifecycle", workflowID: 1, event: "schedule", status: "completed",
                        conclusion: "failure", sha: String(repeating: "a", count: 40), createdAt: Date(), url: nil)
        let status = CIStatus(repository: "acme/app", branch: "main", failing: [run], running: [], passing: 0)
        let text = CIPrompt.text(run, status: status,
                                 log: CIFailureLog(job: "lifecycle", step: "Apply migrations", lines: ["boom"], url: nil))
        #expect(text.contains("acme/app"))
        #expect(text.contains("Failed step: Apply migrations"))
        #expect(text.contains("```\nboom\n```"))
    }
}

@Suite("Local work")
struct LocalWorkTests {
    @Test func parsesPorcelainV2() {
        var repo = RepoState(path: "/x/app")
        GitStatusParser.parse("""
        # branch.oid ba6809ac
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +18 -2
        1 .M N... 100644 100644 100644 aaa bbb src/a.ts
        2 R. N... 100644 100644 100644 aaa bbb R100 b.ts\tc.ts
        u UU N... 100644 100644 100644 100644 a b c d.ts
        ? new.txt
        ! ignored.log
        """, into: &repo)
        #expect(repo.branch == "main")
        #expect(repo.upstream == "origin/main")
        #expect(repo.ahead == 18)
        #expect(repo.behind == 2)
        #expect(repo.changed == 4)
        #expect(repo.needsAttention)
    }

    @Test func unpublishedBranchNeedsAttention() {
        var repo = RepoState(path: "/x/app", hasRemote: true)
        GitStatusParser.parse("# branch.oid abc\n# branch.head feature/x\n", into: &repo)
        #expect(repo.isUnpublished)
        var clean = RepoState(path: "/x/app", hasRemote: true)
        GitStatusParser.parse("# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n", into: &clean)
        #expect(!clean.needsAttention)
    }

    @Test func readsGitHubOrigin() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = https://github.com/cobanov/ghbar.git
        [remote "origin"]
        \turl = git@github.com:therbta/devplusbar.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        let origin = GitStatusParser.origin(fromConfig: config)
        #expect(origin.hasRemote)
        #expect(origin.github == "therbta/devplusbar")
        #expect(GitStatusParser.github(fromURL: "https://user:tok@github.com/acme/web") == "acme/web")
        #expect(GitStatusParser.github(fromURL: "https://gitlab.com/acme/web.git") == nil)
    }

    /// Shapes recorded from `lsof` and `ps` on 2026-11-02: eight php workers on one port,
    /// a node server with a child, Postgres, and apps that are not dev servers.
    @Test func groupsListenersIntoServers() {
        let lsof = """
        p81136
        cnode
        f22
        n*:4000
        p63796
        cphp
        f5
        n127.0.0.1:2000
        p63797
        cphp
        f5
        n127.0.0.1:2000
        p2529
        cpostgres
        f7
        n127.0.0.1:5432
        f8
        n[::1]:5432
        p671
        cControlCe
        f9
        n*:5000
        """
        let ps = """
        81136 81031 16704 node /Users/me/app/node_modules/.bin/vite --port 4000
        81200 81136 100000 /Users/me/.nvm/node esbuild-worker
        63796     1   464 php -S 127.0.0.1:2000
        63797     1   464 php -S 127.0.0.1:2000
         2529     1  3392 /opt/homebrew/opt/postgresql@16/bin/postgres -D /opt/homebrew/var/postgresql@16
          671     1  9000 /System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter
        """
        let cwd = "p81136\nfcwd\nn/Users/me/app/admin\np63796\nfcwd\nn/Users/me/site\np63797\nfcwd\nn/Users/me/site\n"
        let servers = ProcessParser.servers(listeners: ProcessParser.listeners(lsof), table: ProcessParser.table(ps),
                                            folders: ProcessParser.folders(cwd))
        #expect(servers.map(\.ports) == [[2000], [4000], [5432]])
        let php = servers[0]
        #expect(php.pids == [63796, 63797])
        #expect(php.memoryKB == 928)
        let vite = servers[1]
        #expect(vite.title == "node · vite")
        #expect(vite.memoryKB == 116_704)   // with its child
        #expect(vite.cwd == "/Users/me/app/admin")
        #expect(servers[2].kind == .database)
        #expect(ProcessParser.memory(vite.memoryKB) == "113 MB")
    }

    @Test func namesWhatANodeProcessRuns() {
        #expect(ProcessParser.detail(args: "node /a/node_modules/next/dist/bin/next dev", command: "node") == "next")
        #expect(ProcessParser.detail(args: "/n/node /n/lib/node_modules/@swmansion/argent/dist/tool-server.cjs start", command: "node") == "argent")
        #expect(ProcessParser.detail(args: "node --inspect server.js", command: "node") == "server.js")
        #expect(ProcessParser.detail(args: "php -S 127.0.0.1:2000", command: "php") == nil)
    }

    @Test func discoversRepositoriesWithoutDescendingIntoThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devplusbar-discover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["a/.git", "group/b/.git", "a/nested/.git", "group/node_modules/c/.git", "x/y/z/w/.git"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = LocalScanner.discover(roots: [root.path]).map { String($0.dropFirst(root.path.count + 1)) }
        #expect(found == ["a", "group/b"])
    }
}
