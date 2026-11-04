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
        guard let png = view.pngData() else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: path))
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
            Item(kind: kind, repository: repo.contains("/") ? repo : "acme/\(repo)", number: number, title: title,
                 url: "https://github.com/\(repo.contains("/") ? repo : "acme/" + repo)/\(kind == .issue ? "issues" : "pull")/\(number)",
                 createdAt: now.addingTimeInterval(-hours * 3600), isDraft: draft,
                 authorLogin: author, authorIsBot: bot, updatedAt: now.addingTimeInterval(-hours * 3600),
                 reviewDecision: review, checks: checks, comments: comments, merge: merge)
        }
        let prs: [Row] = [
            .item(item(.pullRequest, "storefront", 214, "Keep the cart open after a failed payment", hours: 2, by: "lena-k",
                       checks: .passing, comments: 3)),
            .item(item(.pullRequest, "orders-api", 88, "Retry refund webhooks with backoff", hours: 5, by: "tomasz",
                       checks: .pending)),
            .item(item(.pullRequest, "mobile", 131, "Bump expo from 52 to 53", hours: 20, by: "dependabot", bot: true)),
            .item(item(.pullRequest, "docs", 57, "Explain partial refunds", hours: 30, by: "ayse-dev", draft: true)),
            .group(repository: "acme/design-system", items: (1...6).map {
                item(.pullRequest, "design-system", 300 + $0, "Tokens: spacing scale \($0)", hours: Double(50 + $0), by: "lena-k")
            }),
        ]
        let seen: Set<String> = ["https://github.com/acme/docs/pull/57",
                                 "https://github.com/acme/mobile/pull/131"]
        let sections = [
            MenuSection(kind: .reviewRequested, rows: [
                .item(item(.pullRequest, "orders-api", 90, "Move tax rules into one table", hours: 4, by: "tomasz")),
            ], truncated: false),
            MenuSection(kind: .pullRequests, rows: prs, truncated: false),
            MenuSection(kind: .myPullRequests, rows: [
                .item(item(.pullRequest, "storefront", 209, "Lazy-load product images", hours: 1, by: "samrivera", checks: .passing, comments: 2, merge: .conflicts)),
                .item(item(.pullRequest, "orders-api", 85, "Idempotency keys for refunds", hours: 26, by: "samrivera", review: .approved, checks: .passing, merge: .behind)),
                .item(item(.pullRequest, "mobile", 127, "Offline cart", hours: 8, by: "samrivera", review: .changesRequested, checks: .failing, comments: 5)),
                .item(item(.pullRequest, "docs", 50, "Draft: API changelog page", hours: 400, by: "samrivera", draft: true)),
            ], truncated: false),
            MenuSection(kind: .issues, rows: [
                .item(item(.issue, "storefront", 220, "Apple Pay button missing on Safari 18", hours: 72, by: "ayse-dev")),
            ], truncated: false),
        ]
        let model = PanelModel()
        model.tab = tab
        model.input = PanelInput(
            viewer: Viewer(login: "samrivera", name: "Sam Rivera", avatarURL: ""),
            social: Social(stars: 412, followers: 186, following: 53, starsAreExact: true),
            sections: sections, rateLimit: nil, errors: [], lastRefresh: now, auth: .signedIn(.oauth),
            showOwner: false, visibleSections: Set(SectionKind.allCases),
            isSeen: { seen.contains($0) }, now: now)

        return ArrowPanelContainer(position: { let p = ArrowPosition(); p.x = 300; return p }(),
                                   style: style, content: AnyView(PanelView(model: model)))
    }
}

extension NSView {
    /// A PNG of the view at `scale` pixels per point, so sample renders stay sharp on Retina.
    func pngData(scale: CGFloat = 2) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
