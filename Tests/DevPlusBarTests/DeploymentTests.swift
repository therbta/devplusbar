import Testing
import Foundation
@testable import DevPlusBar

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func deploy(_ id: String, _ state: DeployState, project: String = "web", target: DeployTarget = .production,
                    created: TimeInterval, duration: TimeInterval? = 60, sha: String? = nil,
                    creator: String? = nil, provider: DeployProvider = .vercel) -> Deployment {
    let createdAt = Date(timeIntervalSince1970: created)
    return Deployment(id: "\(provider.rawValue):\(id)", provider: provider, project: project, target: target,
                      state: state, url: nil, dashboardURL: nil,
                      commit: sha.map { DeployCommit(sha: $0) }, creator: creator, createdAt: createdAt,
                      readyAt: state.isFinished ? duration.map { createdAt.addingTimeInterval($0) } : nil,
                      failureSummary: nil, nativeID: id)
}

@Suite("Vercel parser")
struct VercelParserTests {
    @Test func parsesDeployments() throws {
        let list = try VercelParser.deployments(fixture("vercel-deployments"), teamSlug: nil)
        #expect(list.count == 4)   // the one without an id is dropped
        let ready = try #require(list.first { $0.nativeID == "dpl_ready" })
        #expect(ready.state == .ready)
        #expect(ready.target == .production)
        #expect(ready.duration == 102)
        #expect(ready.url?.absoluteString == "https://web-app-abc.vercel.app")
        #expect(ready.commit?.repository == "acme/web")
        #expect(ready.commit?.firstLine == "Fix checkout tax (#42)")
        #expect(ready.pullRequestURL == "https://github.com/acme/web/pull/42")
        #expect(ready.creator == "alice")

        let building = try #require(list.first { $0.nativeID == "dpl_building" })
        #expect(building.state == .building)
        #expect(building.target == .preview)
        #expect(building.readyAt == nil)
        #expect(building.commit?.resolvedPullRequest == 57)

        #expect(list.first { $0.nativeID == "dpl_err" }?.state == .failed)
        #expect(list.first { $0.nativeID == "dpl_cancel" }?.state == .canceled)
    }

    @Test func picksFailureLine() {
        let line = FailureLine.pick([
            "Installing dependencies…",
            "\u{1B}[31mError: Cannot find module 'left-pad'\u{1B}[0m",
            "Command \"npm run build\" exited with 1",
        ])
        #expect(line == "Error: Cannot find module 'left-pad'")
    }

    @Test func mergeSubjectPullRequest() {
        #expect(DeployCommit(sha: "x", message: "Merge pull request #9 from a/b").resolvedPullRequest == 9)
        #expect(DeployCommit(sha: "x", message: "No number here").resolvedPullRequest == nil)
    }
}

@Suite("Heroku parser")
struct HerokuParserTests {
    @Test func mergesBuildsAndReleases() throws {
        let list = try HerokuParser.merge(app: "api", builds: fixture("heroku-builds"), releases: fixture("heroku-releases"))
        #expect(list.count == 4)  // 3 builds + the config release r3; r2 belongs to b1
        #expect(list.first?.nativeID == "build:b3")   // newest first
        #expect(list.first?.state == .building)

        let b1 = try #require(list.first { $0.nativeID == "build:b1" })
        #expect(b1.state == .ready)
        #expect(b1.version == 42)
        #expect(b1.duration == 140)   // build start to release finished
        #expect(b1.commit?.sha == "abc123")

        #expect(list.first { $0.nativeID == "build:b2" }?.state == .failed)

        let config = try #require(list.first { $0.nativeID == "release:r3" })
        #expect(config.note == "v43 · Set FEATURE_X config vars")
        #expect(config.version == 43)
    }
}

@Suite("Deploy tracker")
struct DeployTrackerTests {
    @Test func firstPollIsSilent() {
        var tracker = DeployTracker()
        let changes = tracker.ingest([deploy("a", .building, created: 0)], from: .vercel)
        #expect(changes.isEmpty)
    }

    @Test func emitsEachTransitionOnce() {
        var tracker = DeployTracker()
        _ = tracker.ingest([], from: .vercel)
        let started = tracker.ingest([deploy("a", .queued, created: 0)], from: .vercel)
        #expect(started.map(\.to) == [.queued])
        #expect(started.first?.from == nil)
        #expect(tracker.ingest([deploy("a", .building, created: 0)], from: .vercel).map(\.to) == [.building])
        #expect(tracker.ingest([deploy("a", .building, created: 0)], from: .vercel).isEmpty)
        #expect(tracker.ingest([deploy("a", .ready, created: 0)], from: .vercel).map(\.to) == [.ready])
        #expect(tracker.ingest([deploy("a", .ready, created: 0)], from: .vercel).isEmpty)
    }

    @Test func ignoresStaleResponses() {
        var tracker = DeployTracker()
        _ = tracker.ingest([deploy("a", .ready, created: 0)], from: .vercel)
        #expect(tracker.ingest([deploy("a", .building, created: 0)], from: .vercel).isEmpty)
        #expect(tracker.known["vercel:a"] == .ready)
    }

    @Test func providersSeedSeparately() {
        var tracker = DeployTracker()
        _ = tracker.ingest([], from: .vercel)
        let heroku = tracker.ingest([deploy("h", .ready, created: 0, provider: .heroku)], from: .heroku)
        #expect(heroku.isEmpty)
    }
}

@Suite("Deploy alert rules")
struct DeployAlertRulesTests {
    let rules = DeployAlertRules()

    @Test func productionFailureIsLoud() {
        let change = DeployTransition(deployment: deploy("a", .failed, created: 0), from: .building, to: .failed)
        let alert = rules.alerts(for: [change], myLogins: [], medians: [:]).first
        #expect(alert?.notify == true)
        #expect(alert?.tone == .failure)
        #expect(alert?.timeSensitive == true)
    }

    @Test func previewReadyOnlyToasts() {
        let change = DeployTransition(deployment: deploy("a", .ready, target: .preview, created: 0), from: .building, to: .ready)
        let alert = rules.alerts(for: [change], myLogins: [], medians: [:]).first
        #expect(alert?.notify == false)
        #expect(alert?.toast == true)
        #expect(alert?.tone == nil)
    }

    @Test func myPreviewNotifies() {
        let change = DeployTransition(deployment: deploy("a", .ready, target: .preview, created: 0, creator: "Alice"),
                                      from: .building, to: .ready)
        let alert = rules.alerts(for: [change], myLogins: ["alice"], medians: [:]).first
        #expect(alert?.notify == true)
        #expect(alert?.tone == .success)
    }

    @Test func slowBuildNotifies() {
        let change = DeployTransition(deployment: deploy("a", .ready, target: .preview, created: 0, duration: 300),
                                      from: .building, to: .ready)
        #expect(rules.alerts(for: [change], myLogins: [], medians: ["web": 100]).first?.notify == true)
    }

    @Test func startAnnouncedOnlyWhenFirstSeen() {
        let first = DeployTransition(deployment: deploy("a", .queued, created: 0), from: nil, to: .queued)
        let next = DeployTransition(deployment: deploy("a", .building, created: 0), from: .queued, to: .building)
        #expect(rules.alerts(for: [first, next], myLogins: [], medians: [:]).count == 1)
    }
}

@Suite("Deploy stats")
struct DeployStatsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func percentiles() {
        #expect(DeployStats.percentile([10, 20, 30, 40], 0.5) == 25)
        #expect(DeployStats.percentile([5], 0.95) == 5)
    }

    @Test func summarises() {
        let t = now.timeIntervalSince1970
        let history = [
            deploy("1", .ready, created: t - 3600, duration: 100, sha: "s1"),
            deploy("p1", .ready, target: .preview, created: t - 7200, duration: 50, sha: "s1"),
            deploy("2", .failed, created: t - 10_000, duration: 30),
            deploy("3", .ready, created: t - 20_000, duration: 200),
            deploy("old", .failed, created: t - 9 * 86_400),
        ]
        let stats = DeployStats(history, range: .week, now: now)
        #expect(stats.total == 4)
        #expect(stats.successRate == 0.75)
        #expect(stats.greenStreak == 1)
        #expect(stats.medianDuration == 100)
        // Failure finished at t-9970, next ready production deploy finished at t-3500.
        #expect(stats.mttr == 6470)
        // Preview of s1 created at t-7200, production ready at t-3500.
        #expect(stats.leadTime == 3700)
        #expect(stats.buckets.reduce(0) { $0 + $1.total } == 4)
        #expect(stats.heatmap.reduce(0) { $0 + $1.count } == 4)
    }

    @Test func emptyHistory() {
        let stats = DeployStats([], range: .day, now: now)
        #expect(stats.total == 0)
        #expect(stats.successRate == nil)
        #expect(stats.mttr == nil)
    }
}

@Suite("Deploy history")
struct DeployHistoryTests {
    @Test func roundTripsAndPrunes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        var history = DeployHistory(url: url)
        var failed = deploy("f", .failed, created: now.timeIntervalSince1970 - 60)
        history.merge([failed, deploy("old", .ready, created: now.timeIntervalSince1970 - 100 * 86_400)])
        history.setFailureSummary("Error: boom", for: failed.id)
        failed.state = .failed
        history.merge([failed])   // a re-poll without a summary keeps the old one
        history.prune(now: now)
        try history.save()

        let loaded = DeployHistory(url: url)
        #expect(loaded.all.count == 1)
        #expect(loaded.all.first?.failureSummary == "Error: boom")
    }
}

/// Shapes taken from live accounts on 2026-11-02 (names and messages replaced).
@Suite("Live response shapes")
struct LiveShapeTests {
    @Test func vercelListWithoutReadyTimes() throws {
        let list = try VercelParser.deployments(fixture("vercel-deployments-live"), teamSlug: nil)
        #expect(list.count == 2)
        let prod = try #require(list.first)
        #expect(prod.nativeID == "dpl_FybxdUY6FxsnXRM2YLpU3HrxJuQ3")   // "id", not "uid"
        #expect(prod.state == .ready)
        #expect(prod.readyAt == nil)   // the list gives no finish time
        #expect(prod.commit?.repository == "octocat/site")   // githubOrg / githubRepo
        #expect(prod.creator == "octocat")
        #expect(list[1].target == .preview)   // target null
    }

    @Test func vercelDetailFillsBuildTime() throws {
        let object = try JSONSerialization.jsonObject(with: fixture("vercel-deployment-detail-live")) as! [String: Any]
        let detail = try #require(VercelParser.deployment(object))
        #expect(detail.duration.map { Int($0) } == 152)   // createdAt → ready
        #expect(detail.projectID == "prj_1K4zTEi2j050AsBasSUHVIQNLEAV")   // from project.id
    }

    @Test func herokuConfigReleaseSharesTheSlug() throws {
        let list = try HerokuParser.merge(app: "app", builds: fixture("heroku-builds-shared-slug"),
                                          releases: fixture("heroku-releases-live"))
        let build = try #require(list.first { $0.nativeID == "build:bbbb0001" })
        // v793 (config) reuses v792's slug; the build belongs to v792.
        #expect(build.version == 792)
        #expect(list.contains { $0.version == 793 && $0.nativeID.hasPrefix("release:") })
        #expect(!list.contains { $0.version == 792 && $0.nativeID.hasPrefix("release:") })
        let older = try #require(list.first { $0.version == 791 })
        #expect(older.commit?.sha == "4004bfca")   // "Deploy 4004bfca"
        #expect(list.first { $0.version == 793 }?.commit == nil)
    }

    @Test func historyKeepsLookedUpFinishTime() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var history = DeployHistory(url: url)
        let timed = deploy("x", .ready, created: 0, duration: 90)
        var untimed = timed
        untimed.readyAt = nil
        history.merge([timed])
        history.merge([untimed])
        #expect(history.byID["vercel:x"]?.duration == 90)
    }
}

@Suite("Live Heroku builds")
struct LiveHerokuBuildTests {
    @Test func linksBuildsToReleasesAndCleansTheChangelog() throws {
        let list = try HerokuParser.merge(app: "app", builds: fixture("heroku-builds-live"),
                                          releases: fixture("heroku-releases-live2"))
        #expect(list.count == 3)   // two builds, plus the config release v2079
        let latest = try #require(list.first { $0.version == 2080 })
        #expect(latest.nativeID == "build:4c7db48b-23e8-4107-a558-466120b47327")
        #expect(latest.state == .ready)
        #expect(latest.commit?.shortSHA == "fee0653")
        #expect(latest.commit?.firstLine == "docs(diary): ship candidate")
        #expect(latest.duration.map { Int($0) } == 360)   // build 23:05:33 → release done 23:11:33
        #expect(list.first { $0.version == 2079 }?.nativeID.hasPrefix("release:") == true)
        #expect(list.first { $0.version == 2078 }?.nativeID.hasPrefix("build:") == true)
    }

    @Test func plainDescriptionPassesThrough() {
        #expect(HerokuParser.subject("Add billing") == "Add billing")
    }
}

@Suite("Release kinds, crashes, pending commits")
struct DeployExtrasTests {
    @Test func readsReleaseDescriptions() {
        #expect(ReleaseKind(description: "Set ALLOW_TZ_MISMATCH config vars") == .config(action: "Set", keys: ["ALLOW_TZ_MISMATCH"]))
        #expect(ReleaseKind(description: "Set A, B config vars") == .config(action: "Set", keys: ["A", "B"]))
        #expect(ReleaseKind(description: "Remove OLD_KEY config vars") == .config(action: "Removed", keys: ["OLD_KEY"]))
        #expect(ReleaseKind(description: "Rollback to v2077") == .rollback(version: 2077))
        #expect(ReleaseKind(description: "Deploy dfef9365") == .deploy)
        #expect(ReleaseKind(description: "Attach DATABASE") == .other("Attach DATABASE"))
    }

    @Test func liveConfigReleaseIsRecognised() throws {
        let list = try HerokuParser.merge(app: "app", builds: fixture("heroku-builds-live"),
                                          releases: fixture("heroku-releases-live2"))
        let config = try #require(list.first { $0.version == 2079 })
        #expect(config.releaseKind == .config(action: "Set", keys: ["ALLOW_TZ_MISMATCH"]))
        #expect(DeployText.detail(config) == "Set ALLOW_TZ_MISMATCH · by dev")
        #expect(DeployText.status(config) == "Settings")
        #expect(list.first { $0.version == 2080 }?.releaseKind == nil)   // a build, not a release
    }

    @Test func findsCrashedDynos() {
        let data = Data(#"[{"name":"web.1","state":"up"},{"name":"worker.1","state":"crashed"},{"name":"web.2","state":"crashed"}]"#.utf8)
        #expect(HerokuParser.crashedDynos(data) == ["web.2", "worker.1"])
    }

    @Test func crashChangesTheCard() {
        var d = deploy("r", .ready, created: 0)
        d.crashedDynos = ["web.1"]
        #expect(DeployText.status(d) == "Live, but web.1 crashed")
        #expect(DeployText.headline(DeployTransition(deployment: d, from: .ready, to: .ready)) == "⚠ web crashed after release")
    }

    @Test func parsesCompare() throws {
        let data = Data(#"{"ahead_by":2,"html_url":"https://github.com/o/r/compare/a...main","commits":[{"commit":{"message":"older\n\nbody"}},{"commit":{"message":"newer"}}]}"#.utf8)
        let pending = try PendingCommitsClient.parse(data, repository: "o/r", branch: "main")
        #expect(pending.count == 2)
        #expect(pending.subjects == ["newer", "older"])
        #expect(pending.compareURL?.absoluteString == "https://github.com/o/r/compare/a...main")
    }
}

@Suite("Logs and prompts")
struct DeployLogPromptTests {
    @Test func vercelLogLinesInTimeOrder() {
        let data = Data(#"[{"created":3,"text":"\u001b[31mError: boom\u001b[0m"},{"created":1,"text":"Cloning"},{"created":2,"payload":{"text":"npm ci\nadded 10 packages"}}]"#.utf8)
        #expect(VercelParser.logLines(data, limit: 3) == ["npm ci", "added 10 packages", "Error: boom"])
        #expect(VercelParser.logLines(data, limit: 1) == ["Error: boom"])
    }

    @Test func promptForAFailedBuild() {
        var d = deploy("f", .failed, created: 0, sha: "abc1234def")
        d.commit?.ref = "main"
        d.commit?.message = "Fix tax\n\nbody"
        d.failureSummary = "Error: Cannot find module 'x'"
        let text = DeployPrompt.text(d, repository: "acme/web", log: ["npm run build", "Error: Cannot find module 'x'"])
        #expect(text.contains("failed to deploy"))
        #expect(text.contains("Repository: acme/web"))
        #expect(text.contains("Commit: abc1234def — Fix tax"))
        #expect(text.contains("```\nnpm run build\nError: Cannot find module 'x'\n```"))
        #expect(text.contains("reproduce the failure"))
    }

    @Test func promptForACrash() {
        var d = deploy("c", .ready, created: 0, provider: .heroku)
        d.crashedDynos = ["web.1"]
        let text = DeployPrompt.text(d, repository: nil, log: [])
        #expect(text.contains("crashed right after its release went live"))
        #expect(text.contains("Crashed dynos: web.1"))
        #expect(text.contains("heroku logs --tail -a web"))
        #expect(!text.contains("```"))
    }
}

@Test func vercelLogTiesKeepOrder() {
    // Live shape, 2026-11-02: two events in the same millisecond, newest first.
    let data = Data(#"[{"created":5,"type":"stdout","text":"Build cache uploaded: 6.637s"},{"created":4,"type":"stdout","text":"Uploading build cache [340.26 MB]"},{"created":4,"type":"stdout","text":"Created build cache: 8s"},{"created":3,"type":"stdout","text":"Creating build cache..."}]"#.utf8)
    #expect(VercelParser.logLines(data, limit: 4) == ["Creating build cache...", "Created build cache: 8s",
                                                      "Uploading build cache [340.26 MB]", "Build cache uploaded: 6.637s"])
}

@Suite("Vercel failure line")
struct VercelFailureLineTests {
    /// Shape of a real failed build's events on 2026-11-02, newest first as fetched: the cause is
    /// a guard's own line, followed by Vercel's generic spawn trailer.
    @Test func skipsTheSpawnTrailerAndReadsInTimeOrder() {
        let data = Data("""
        [{"created":5,"text":"Error: [BUILD_UTILS_SPAWN_1] Command \\"next build && npm run guards\\" exited with 1"},
         {"created":4,"text":"  • src/page.tsx:115 was checked 54 days ago. Re-check it."},
         {"created":3,"text":"✗ Claims guard FAILED"},
         {"created":2,"text":"> node scripts/check-claims.mjs"},
         {"created":1,"text":"Error: old warning that was retried"}]
        """.utf8)
        #expect(VercelParser.failureLine(data) == "✗ Claims guard FAILED")
    }

    @Test func vagueSummariesAreRecognised() {
        #expect(DeployMonitor.isVague(nil))
        #expect(DeployMonitor.isVague("Command \"next build\" exited with 1"))
        #expect(DeployMonitor.isVague("Error: [BUILD_UTILS_SPAWN_1] Command \"x\" exited with 1"))
        #expect(!DeployMonitor.isVague("✗ Claims guard FAILED"))
    }
}
