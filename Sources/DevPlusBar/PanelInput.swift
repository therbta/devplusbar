import AppKit
import Foundation

/// Everything the panel draws, gathered by the app delegate after each refresh.
struct PanelInput {
    var viewer: Viewer?
    var social: Social?
    var sections: [MenuSection]
    var rateLimit: RateLimit?
    /// Why the last refresh failed; the panel then shows older data, if any.
    var errors: [AppError]
    /// Warnings that came with fresh data.
    var notices: [String] = []
    var lastRefresh: Date?
    var auth: AuthState
    /// With an expired `auth`: GitHub refused the token, rather than it being gone.
    var authRefused = false
    var isSignedOut: Bool { !auth.isSignedIn }
    var isRefreshing: Bool = false
    var showOwner: Bool
    var knownOrganizations: [String] = []
    var selectedOrganizations: [String] = []
    /// Whether the repository allow or block list narrows the results, so an empty panel can
    /// say why it is empty.
    var repositoryFilterActive: Bool = false
    var repositoryFilterIsAllowList: Bool = false
    var visibleSections: Set<SectionKind>
    /// Keep a tab for each chosen section even when it has nothing in it.
    var showEmptySections: Bool = false
    var rateLimitVisibility: RateLimitVisibility = .whenLow
    var isSeen: (String) -> Bool
    var now: Date
    /// Vercel or Heroku is connected: the panel gets a Deploys side.
    var deploysEnabled = false
    /// Claude Code or Codex logs exist on this Mac: the panel gets an AI side.
    var aiEnabled = false
    /// Git repositories were found on this Mac: the panel gets a Local side.
    var localEnabled = false
    /// Repositories with commits not on GitHub, for the count on the Local switch.
    var localUnpushed = 0
    var availableModes: [PanelMode] {
        [.work] + (deploysEnabled ? [.deploys] : []) + (localEnabled ? [.local] : []) + (aiEnabled ? [.ai] : [])
    }
    /// Building (orange) or a failure you have not seen (red); nil when all is quiet.
    var deployIndicator: DeployState? = nil
    /// The latest deployment built from a pull request, for the chip on its row.
    var deploymentFor: (Item) -> Deployment? = { _ in nil }
}

/// The menu bar icon: a template, so macOS colours it and inverts it while the panel is open.
/// With `alert` a red dot sits on its corner; colour cannot live in a template, so that version
/// draws the symbol in the menu bar's text colour itself, looked up each time it is drawn.
enum StatusIcon {
    static func image(alert: Bool = false) -> NSImage? {
        guard let symbol = symbol() else { return nil }
        guard alert else { return symbol }
        let size = symbol.size
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: rect)
            let d = max(4.5, size.height * 0.32)
            let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            NSColor(srgbRed: 0.96, green: 0.26, blue: 0.21, alpha: 1).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func symbol() -> NSImage? {
        // trianglehead arrives with SF Symbols 6 (macOS 15); the older names cover Sonoma.
        for name in ["arrow.trianglehead.pull", "arrow.triangle.pull", "arrow.triangle.branch"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dev+ Bar") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }
}
