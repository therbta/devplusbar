import Foundation

/// One thing worth interrupting for that is not a GitHub item or a deployment: a usage limit
/// coming up, work left unpushed, a workflow that broke, a comment. It goes out both ways, as a
/// macOS notification and as the menu-bar pop-up, so it is seen even when Notification Center
/// is turned off for Dev+ Bar.
struct BarNotice: Identifiable, Sendable, Hashable {
    enum Tone: Sendable, Hashable { case warning, failure, info }

    /// Also the notification's identifier: the same notice posted twice replaces itself.
    let id: String
    let tone: Tone
    /// SF Symbol.
    let symbol: String
    /// The small coloured line on top: "Claude Code · this week".
    let heading: String
    let title: String
    var detail: String? = nil
    /// Opened on click. Without one, `mode` says which side of the panel to open.
    var url: String? = nil
    var mode: PanelMode? = nil
    /// Stays up until clicked or hovered away, for the ones that cost something if missed.
    var sticky = false
}

extension BarNotice {
    static func workflow(_ failure: WorkflowFailure) -> BarNotice {
        BarNotice(id: "workflow-\(failure.run.id)", tone: .failure, symbol: "xmark.octagon.fill",
                  heading: "Workflow failed · \(failure.repositoryName)", title: failure.run.workflow,
                  detail: "\(failure.run.event) on \(failure.branch)",
                  url: failure.run.url?.absoluteString ?? "https://github.com/\(failure.repository)/actions")
    }

    static func comment(_ item: Item) -> BarNotice {
        BarNotice(id: "comment-\(item.url)-\(item.comments)", tone: .info, symbol: "text.bubble.fill",
                  heading: "New comment · \(item.repositoryName) #\(item.number)", title: item.title,
                  detail: "@\(item.lastCommenter ?? "someone")", url: item.url)
    }
}
