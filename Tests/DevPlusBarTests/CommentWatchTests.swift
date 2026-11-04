import Foundation
import Testing
@testable import DevPlusBar

private func thread(_ n: Int, comments: Int, by commenter: String? = "alice", bot: Bool = false,
                    author: String = "github-actions", authorIsBot: Bool = true) -> Item {
    Item(kind: .issue, repository: "me/site", number: n, title: "Thread \(n)",
         url: "https://github.com/me/site/issues/\(n)", createdAt: Date(), isDraft: false,
         authorLogin: author, authorIsBot: authorIsBot, comments: comments,
         lastCommenter: commenter, lastCommenterIsBot: bot)
}

@Suite("CommentWatch")
struct CommentWatchTests {
    private let url = thread(4, comments: 0).url

    @Test("a thread seen for the first time is not news") func firstSighting() {
        let result = CommentWatch.changes(previous: [:], items: [thread(4, comments: 75)], viewer: "me")
        #expect(result.events.isEmpty)
        #expect(result.next[url] == 75)
    }

    @Test("a person answering in a bot's thread is news") func personInBotThread() {
        let result = CommentWatch.changes(previous: [url: 75], items: [thread(4, comments: 76)], viewer: "me")
        #expect(result.events.map(\.number) == [4])
    }

    @Test("a bot comment is not news") func botComment() {
        let result = CommentWatch.changes(previous: [url: 75],
                                          items: [thread(4, comments: 76, by: "github-actions", bot: true)], viewer: "me")
        #expect(result.events.isEmpty)
        #expect(result.next[url] == 76)
    }

    @Test("your own comment is not news, whatever the case") func ownComment() {
        let result = CommentWatch.changes(previous: [url: 75], items: [thread(4, comments: 76, by: "Me")], viewer: "me")
        #expect(result.events.isEmpty)
    }

    @Test("an unchanged or shrinking count is quiet") func noNewComments() {
        #expect(CommentWatch.changes(previous: [url: 75], items: [thread(4, comments: 75)], viewer: "me").events.isEmpty)
        let deleted = CommentWatch.changes(previous: [url: 75], items: [thread(4, comments: 74)], viewer: "me")
        #expect(deleted.events.isEmpty)
        #expect(deleted.next[url] == 74)
    }

    @Test("the same thread from two searches notifies once") func duplicates() {
        let result = CommentWatch.changes(previous: [url: 1], items: [thread(4, comments: 2), thread(4, comments: 2)],
                                          viewer: "me")
        #expect(result.events.count == 1)
    }

    @Test("closed threads drop out of the stored counts") func pruning() {
        let result = CommentWatch.changes(previous: [url: 1, "https://github.com/me/site/issues/9": 3],
                                          items: [thread(4, comments: 1)], viewer: "me")
        #expect(result.next.keys.sorted() == [url])
    }

    @Test("the parser reads the newest comment's author") func parsesLastCommenter() throws {
        let json = """
        {"data":{
          "viewer":{"login":"me","avatarUrl":"https://a"},
          "prs":{"issueCount":0,"nodes":[]},
          "issues":{"issueCount":2,"nodes":[
            {"number":4,"title":"t","url":"https://github.com/me/site/issues/4","createdAt":"2026-08-28T22:20:46Z",
             "author":{"login":"github-actions","__typename":"Bot"},"repository":{"nameWithOwner":"me/site"},
             "comments":{"totalCount":75,"nodes":[{"author":{"login":"github-actions","__typename":"Bot"}}]}},
            {"number":5,"title":"t","url":"https://github.com/me/site/issues/5","createdAt":"2026-08-28T22:20:46Z",
             "author":{"login":"bob","__typename":"User"},"repository":{"nameWithOwner":"me/site"},
             "comments":{"totalCount":2,"nodes":[{"author":{"login":"alice","__typename":"User"}}]}}]},
          "assignedIssues":{"issueCount":0,"nodes":[]},
          "review":{"issueCount":0,"nodes":[]},
          "changesRequested":{"issueCount":0,"nodes":[]},
          "myPullRequests":{"issueCount":0,"nodes":[]},
          "rateLimit":{"limit":5000,"remaining":4999,"resetAt":"2026-11-03T07:00:00Z","cost":1}}}
        """
        let issues = try ResponseParser.parse(Data(json.utf8)).issues
        #expect(issues.map(\.comments) == [75, 2])
        #expect(issues.map(\.lastCommenter) == ["github-actions", "alice"])
        #expect(issues.map(\.lastCommenterIsBot) == [true, false])
    }
}
