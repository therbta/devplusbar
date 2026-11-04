import Foundation
import Testing
@testable import DevPlusBar

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func week(startedHoursAgo hours: Double) -> DateInterval {
    DateInterval(start: now.addingTimeInterval(-hours * 3600), duration: ClaudeLimits.week)
}

@Suite("Claude weekly limit warnings")
struct ClaudeCapWatchTests {
    @Test("93% with a pace that runs out before the reset: one warning, every mark given")
    func ninetyThreePercent() throws {
        let w = week(startedHoursAgo: 100)
        let result = ClaudeCapWatch.check(given: [], used: 93, cap: 100, week: w, stopped: false, now: now)
        let notice = try #require(result.notice)
        #expect(notice.title == "93% of this week's limit used")
        #expect(notice.detail?.hasPrefix("At this pace you run out") == true)
        #expect(notice.mode == .ai)
        #expect(notice.sticky)
        let prefix = "\(Int(w.start.timeIntervalSince1970))#"
        #expect(Set(result.given) == [prefix + "75", prefix + "90", prefix + "early"])
    }

    @Test("a warning already given is not given again")
    func onceAWeek() {
        let w = week(startedHoursAgo: 100)
        let first = ClaudeCapWatch.check(given: [], used: 93, cap: 100, week: w, stopped: false, now: now)
        let again = ClaudeCapWatch.check(given: first.given, used: 95, cap: 100, week: w, stopped: false, now: now)
        #expect(again.notice == nil)
        #expect(again.given == first.given)
    }

    @Test("crossing 75% late in the week, with the pace lasting")
    func seventyFiveLasting() throws {
        let w = week(startedHoursAgo: 6.9 * 24)
        let result = ClaudeCapWatch.check(given: [], used: 80, cap: 100, week: w, stopped: false, now: now)
        let notice = try #require(result.notice)
        #expect(notice.title == "80% of this week's limit used")
        #expect(notice.detail?.hasPrefix("Your pace lasts") == true)
        #expect(!notice.sticky)
        #expect(result.given.count == 1)
    }

    @Test("a fast start warns about the pace before any mark")
    func earlyPace() throws {
        let result = ClaudeCapWatch.check(given: [], used: 60, cap: 100, week: week(startedHoursAgo: 48),
                                          stopped: false, now: now)
        let notice = try #require(result.notice)
        #expect(notice.title.hasPrefix("On pace to run out"))
        #expect(notice.detail?.hasPrefix("60% of this week's limit used") == true)
    }

    @Test("then 75% is still news, the pace warning is not")
    func markAfterPace() throws {
        let w = week(startedHoursAgo: 48)
        let first = ClaudeCapWatch.check(given: [], used: 60, cap: 100, week: w, stopped: false, now: now)
        let later = ClaudeCapWatch.check(given: first.given, used: 76, cap: 100, week: w, stopped: false, now: now)
        #expect(later.notice?.title == "76% of this week's limit used")
    }

    @Test("no cap, no week, or already stopped: nothing")
    func nothingToSay() {
        let w = week(startedHoursAgo: 100)
        #expect(ClaudeCapWatch.check(given: [], used: 93, cap: nil, week: w, stopped: false, now: now).notice == nil)
        #expect(ClaudeCapWatch.check(given: ["x"], used: 93, cap: 100, week: nil, stopped: false, now: now).given == ["x"])
        #expect(ClaudeCapWatch.check(given: [], used: 100, cap: 100, week: w, stopped: true, now: now).notice == nil)
    }

    @Test("how early reads in hours under two days, days above")
    func earlyWording() {
        let w = week(startedHoursAgo: 100)
        #expect(ClaudeCapWatch.early(w.end.addingTimeInterval(-4 * 3600), w) == "about 4 hours before the reset")
        #expect(ClaudeCapWatch.early(w.end.addingTimeInterval(-3 * 86_400), w) == "3 days before the reset")
        #expect(ClaudeCapWatch.early(w.end.addingTimeInterval(-600), w) == "just before the reset")
    }

    @Test("last week's warnings are forgotten")
    func newWeek() {
        let result = ClaudeCapWatch.check(given: ["1#75", "1#90"], used: 10, cap: 100, week: week(startedHoursAgo: 100),
                                          stopped: false, now: now)
        #expect(result.notice == nil)
        #expect(result.given.isEmpty)
    }
}

private func run(_ id: Int, workflow: Int = 1, _ conclusion: String, hoursAgo: Double, event: String = "schedule") -> CIRun {
    CIRun(id: id, workflow: "Verify live", workflowID: workflow, event: event, status: "completed",
          conclusion: conclusion, sha: "abc", createdAt: now.addingTimeInterval(-hoursAgo * 3600),
          url: URL(string: "https://github.com/me/site/actions/runs/\(id)"))
}

@Suite("Workflows that never passed")
struct NeverPassedTests {
    private func failures(_ n: Int, workflow: Int = 1) -> [CIRun] {
        (0..<n).map { run(100 * workflow + $0, workflow: workflow, "failure", hoursAgo: Double($0) * 6 + 1) }
    }

    @Test("five failures and nothing green")
    func neverPassed() throws {
        let found = WorkflowWatch.neverPassed(repository: "me/site", runs: failures(5), now: now)
        let w = try #require(found.first)
        #expect(found.count == 1)
        #expect(w.failures == 5)
        #expect(w.latest.id == 100)
        #expect(w.since == now.addingTimeInterval(-25 * 3600))
        #expect(w.id == "me/site#1")
    }

    @Test("four failures can still be a workflow being set up")
    func tooFew() {
        #expect(WorkflowWatch.neverPassed(repository: "me/site", runs: failures(4), now: now).isEmpty)
    }

    @Test("one success anywhere in the fetched runs rules it out")
    func oneGreen() {
        let runs = failures(6) + [run(999, "success", hoursAgo: 200)]
        #expect(WorkflowWatch.neverPassed(repository: "me/site", runs: runs, now: now).isEmpty)
    }

    @Test("quiet for two weeks is left alone")
    func stale() {
        let runs = (0..<6).map { run($0, "failure", hoursAgo: 15 * 24 + Double($0)) }
        #expect(WorkflowWatch.neverPassed(repository: "me/site", runs: runs, now: now).isEmpty)
    }

    @Test("worst first, across workflows")
    func ordering() {
        let found = WorkflowWatch.neverPassed(repository: "me/site", runs: failures(5) + failures(8, workflow: 2), now: now)
        #expect(found.map(\.workflowID) == [2, 1])
    }

    @Test("a disabled workflow's old runs stop counting; a run after re-enabling counts")
    func disabled() {
        let disabledAt = now.addingTimeInterval(-3600).timeIntervalSince1970
        let runs = failures(6) + [run(7, workflow: 2, "failure", hoursAgo: 2)]
        let left = WorkflowWatch.droppingDisabled(runs, repository: "me/site", disabled: ["me/site#1": disabledAt])
        #expect(left.map(\.id) == [7])
        let later = WorkflowWatch.droppingDisabled([run(8, "failure", hoursAgo: 0.5)], repository: "me/site",
                                                   disabled: ["me/site#1": disabledAt])
        #expect(later.map(\.id) == [8])
    }

    @Test("the CI streak says never passed only when every fetched run failed, five or more")
    func streakLabel() {
        #expect(CIStreak(failures: 7, since: now, atLeast: true).neverPassed)
        #expect(!CIStreak(failures: 7, since: now, atLeast: false).neverPassed)
        #expect(!CIStreak(failures: 3, since: now, atLeast: true).neverPassed)
    }
}

private func repo(_ name: String, ahead: Int = 2, newestHoursAgo: Double, oldestHoursAgo: Double) -> RepoState {
    var r = RepoState(path: "/x/\(name)")
    r.branch = "main"
    r.upstream = "origin/main"
    r.hasRemote = true
    r.ahead = ahead
    r.unpushed = ["Fix the thing"]
    r.unpushedNewest = now.addingTimeInterval(-newestHoursAgo * 3600)
    r.unpushedOldest = now.addingTimeInterval(-oldestHoursAgo * 3600)
    r.statusRead = true
    return r
}

@Suite("Unpushed work")
struct UnpushedTests {
    @Test("git log dates: newest, oldest, first subjects")
    func parsesLog() {
        let parsed = GitStatusParser.unpushedLog("1800000000\tNewest\n1799990000\tMiddle\twith tab\n1799900000\tOldest\n", keep: 2)
        #expect(parsed.subjects == ["Newest", "Middle\twith tab"])
        #expect(parsed.newest == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(parsed.oldest == Date(timeIntervalSince1970: 1_799_900_000))
        #expect(GitStatusParser.unpushedLog("").newest == nil)
    }

    @Test("parked after a week with nothing new, however old the first commit")
    func parked() {
        #expect(repo("old", newestHoursAgo: 8 * 24, oldestHoursAgo: 120 * 24).isParked(now: now))
        #expect(!repo("busy", newestHoursAgo: 1, oldestHoursAgo: 120 * 24).isParked(now: now))
    }

    @Test("recent first by how long it has waited; parked apart, newest first")
    func grouping() {
        let repos = [repo("today", newestHoursAgo: 0.2, oldestHoursAgo: 0.2),
                     repo("yesterday", newestHoursAgo: 20, oldestHoursAgo: 32),
                     repo("cleanbreak", ahead: 6, newestHoursAgo: 120 * 24, oldestHoursAgo: 121 * 24),
                     repo("tablet", ahead: 5, newestHoursAgo: 40 * 24, oldestHoursAgo: 42 * 24)]
        #expect(LocalMonitor.recent(repos, now: now).map(\.name) == ["yesterday", "today"])
        #expect(LocalMonitor.parked(repos, now: now).map(\.name) == ["tablet", "cleanbreak"])
    }

    @Test("age reads short")
    func age() {
        #expect(repo("a", newestHoursAgo: 1, oldestHoursAgo: 22).unpushedAge(now: now) == "22h")
        #expect(repo("a", newestHoursAgo: 1, oldestHoursAgo: 72).unpushedAge(now: now) == "3d")
        #expect(repo("a", newestHoursAgo: 1, oldestHoursAgo: 121 * 24).unpushedAge(now: now) == "4mo")
    }

    @Test("a day unpushed nudges once; under a day or parked, never")
    func nudge() {
        let repos = [repo("yesterday", newestHoursAgo: 20, oldestHoursAgo: 32),
                     repo("today", newestHoursAgo: 1, oldestHoursAgo: 5),
                     repo("cleanbreak", newestHoursAgo: 120 * 24, oldestHoursAgo: 121 * 24)]
        let first = UnpushedWatch.check(nudged: [:], repos: repos, now: now)
        #expect(first.due.map(\.name) == ["yesterday"])
        #expect(first.next.keys.sorted() == ["/x/yesterday"])
        // More commits on top of the same waiting work: still the same nudge.
        var more = repos
        more[0].ahead = 4
        #expect(UnpushedWatch.check(nudged: first.next, repos: more, now: now).due.isEmpty)
    }

    @Test("pushing clears the nudge, and new work that waits a day nudges again")
    func pushClears() {
        let nudged = ["/x/app": now.addingTimeInterval(-40 * 3600).timeIntervalSince1970]
        var pushed = repo("app", newestHoursAgo: 1, oldestHoursAgo: 1)
        pushed.ahead = 0
        pushed.unpushedOldest = nil
        #expect(UnpushedWatch.check(nudged: nudged, repos: [pushed], now: now).next.isEmpty)
        let again = UnpushedWatch.check(nudged: [:], repos: [repo("app", newestHoursAgo: 2, oldestHoursAgo: 26)], now: now)
        #expect(again.due.map(\.name) == ["app"])
    }

    @Test("a repository git did not answer for keeps its nudge record")
    func unreadable() {
        let nudged = ["/x/app": 1.0, "/x/gone": 2.0]
        var timedOut = RepoState(path: "/x/app")
        timedOut.statusRead = false
        let result = UnpushedWatch.check(nudged: nudged, repos: [timedOut], now: now)
        #expect(result.next == nudged)
        #expect(result.due.isEmpty)
    }

    @Test("the notice names the repository and how long")
    func notice() {
        let n = UnpushedWatch.notice(repo("vea-2", ahead: 3, newestHoursAgo: 20, oldestHoursAgo: 32), now: now)
        #expect(n.heading == "Not pushed · vea-2")
        #expect(n.title == "3 commits only on this Mac for 32h")
        #expect(n.mode == .local)
    }
}

@Suite("Claude limit wording")
struct ClaudeCapWordingTests {
    @Test("the run-out time rounds to the hour and keeps the minutes")
    func roundedTime() {
        let at = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 17, minute: 10))!
        let text = ClaudeCapWatch.when(at)
        #expect(text.hasPrefix("Friday around "))
        #expect(text.contains(":00"))
        #expect(!text.hasSuffix("around 17"))
    }
}
