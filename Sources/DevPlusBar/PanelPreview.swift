import AppKit
import SwiftUI

/// `Dev+ Bar --render-panel out.png`: draws the panel with sample data and exits, to check the
/// design without signing in or opening the menu bar.
@MainActor
enum PanelPreview {
    static let style = ArrowPanelStyle(fill: Ink.panel, border: Color.white.opacity(0.09), cornerRadius: 18,
                                       arrowHalfWidth: 17, arrowHeight: 9)

    static func render(to path: String) {
        let tab = ProcessInfo.processInfo.environment["PANEL_TAB"].flatMap(SectionKind.init(rawValue:)) ?? .pullRequests
        let view = NSHostingView(rootView: sample(tab: tab))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        // Let the avatar fetches land before drawing.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The panel in its arrow frame, filled with sample pull requests and issues. The authors
    /// are made up and drawn as initials, so no real person's picture ends up in a screenshot.
    static func sample(tab: SectionKind) -> some View {
        AuthorAvatars.offline = true
        let now = Date()
        func item(_ kind: ItemKind, _ repo: String, _ number: Int, _ title: String, hours: Double,
                  by author: String, bot: Bool = false, draft: Bool = false,
                  review: ReviewDecision? = nil, checks: CheckState? = nil, comments: Int = 0,
                  merge: MergeBlock? = nil) -> Item {
            Item(kind: kind, repository: repo.contains("/") ? repo : "therbta/\(repo)", number: number, title: title,
                 url: "https://github.com/\(repo.contains("/") ? repo : "therbta/" + repo)/\(kind == .issue ? "issues" : "pull")/\(number)",
                 createdAt: now.addingTimeInterval(-hours * 3600), isDraft: draft,
                 authorLogin: author, authorIsBot: bot, updatedAt: now.addingTimeInterval(-hours * 3600),
                 reviewDecision: review, checks: checks, comments: comments, merge: merge)
        }
        let prs: [Row] = [
            .item(item(.pullRequest, "herdrchat", 55, "Let the last row scroll clear of the composer", hours: 2, by: "lena-k")),
            .item(item(.pullRequest, "dev-plus-bar", 12, "Add keyboard navigation to the menu", hours: 5, by: "tomasz")),
            .item(item(.pullRequest, "teslamate-mcp", 9, "Bump actions/checkout from 4 to 5", hours: 20, by: "dependabot", bot: true)),
            .item(item(.pullRequest, "instagram", 3, "fix: cache-control headers on the media proxy", hours: 30, by: "ayse-dev", draft: true)),
            .group(repository: "therbta/paul-graham-turkce", items: (1...6).map {
                item(.pullRequest, "paul-graham-turkce", 40 + $0, "Çeviri: essay \($0)", hours: Double(50 + $0), by: "lena-k")
            }),
        ]
        let seen: Set<String> = ["https://github.com/therbta/instagram/pull/3",
                                 "https://github.com/therbta/teslamate-mcp/pull/9"]
        let sections = [
            MenuSection(kind: .reviewRequested, rows: [
                .item(item(.pullRequest, "atkctl", 4, "Support the VXE R1 receiver", hours: 4, by: "tomasz")),
            ], truncated: false),
            MenuSection(kind: .pullRequests, rows: prs, truncated: false),
            MenuSection(kind: .myPullRequests, rows: [
                .item(item(.pullRequest, "devplusbar", 1, "Dev+ Bar rebrand and slug migration", hours: 1, by: "therbta", checks: .passing, comments: 2, merge: .conflicts)),
                .item(item(.pullRequest, "thebt.dev", 1, "Add /room: a 3D Vermont cabin experiment", hours: 400, by: "therbta", draft: true)),
                .item(item(.pullRequest, "atkctl", 7, "Retry the receiver handshake", hours: 26, by: "therbta", review: .approved, checks: .passing, merge: .behind)),
                .item(item(.pullRequest, "herdrchat", 61, "Move auth to the edge worker", hours: 8, by: "therbta", review: .changesRequested, checks: .failing, comments: 5)),
                .item(item(.pullRequest, "react-native-elements/react-native-elements", 4013, "feat: add testID props to SpeedDial.Action", hours: 7000, by: "therbta")),
            ], truncated: false),
            MenuSection(kind: .issues, rows: [
                .item(item(.issue, "teslamate-mcp", 8, "Optional sponsored field in the trip summary", hours: 72, by: "ayse-dev")),
            ], truncated: false),
        ]
        let model = PanelModel()
        model.tab = tab
        model.input = PanelInput(
            viewer: Viewer(login: "therbta", name: "Mert Cobanov", avatarURL: ""),
            social: Social(stars: 2021, followers: 2611, following: 74, starsAreExact: true),
            sections: sections, rateLimit: nil, errors: [], lastRefresh: now, auth: .signedIn(.oauth),
            showOwner: false, visibleSections: Set(SectionKind.allCases),
            isSeen: { seen.contains($0) }, now: now)

        return ArrowPanelContainer(position: { let p = ArrowPosition(); p.x = 300; return p }(),
                                   style: style, content: AnyView(PanelView(model: model)))
    }
}
