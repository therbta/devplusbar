import Foundation

/// Compares each open thread's comment count with last time and says which ones a person
/// answered in.
///
/// News only when the count went up and the newest comment is from someone who is neither you
/// nor a bot: a workflow posting its failures to an issue, or a budget guard ticking, is
/// machine output that Dev+ Bar reports elsewhere or not at all. A thread seen for the first
/// time sets its count quietly.
enum CommentWatch {

    static func changes(
        previous: [String: Int],
        items: [Item],
        viewer: String
    ) -> (events: [Item], next: [String: Int]) {
        var events: [Item] = []
        var next: [String: Int] = [:]
        for item in items where next[item.url] == nil {
            next[item.url] = item.comments
            guard let old = previous[item.url], item.comments > old,
                  let commenter = item.lastCommenter, !item.lastCommenterIsBot,
                  commenter.caseInsensitiveCompare(viewer) != .orderedSame else { continue }
            events.append(item)
        }
        return (events, next)
    }
}
