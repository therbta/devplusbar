import SwiftUI

/// Words and colours for deployments, shared by cards, toasts and notifications.
enum DeployText {
    static func headline(_ t: DeployTransition) -> String {
        let d = t.deployment
        if d.isCrashed { return "⚠ \(d.project) crashed after release" }
        switch d.releaseKind {
        case .config?: return "⚙ \(d.project) settings changed"
        case .rollback(let v)?: return "↩ \(d.project) rolled back" + (v.map { " to v\($0)" } ?? "")
        default: break
        }
        switch t.to {
        case .ready: return "✓ \(d.project) is live" + (d.duration.map { " · \(duration($0))" } ?? "")
        case .failed: return "✗ \(d.project) failed to deploy"
        case .canceled: return "\(d.project) deployment canceled"
        case .building, .queued: return "↻ \(d.project) is deploying"
        }
    }

    static func detail(_ d: Deployment) -> String {
        if d.state == .failed, let line = d.failureSummary { return line }
        if let dynos = d.crashedDynos, !dynos.isEmpty { return "\(dynos.joined(separator: ", ")) crashed · check the logs" }
        if case .config(let action, let keys)? = d.releaseKind {
            return "\(action) \(keys.joined(separator: ", "))" + (d.creator.map { " · by \(person($0))" } ?? "")
        }
        var parts: [String] = []
        if let ref = d.commit?.ref { parts.append(ref) }
        if let sha = d.commit?.shortSHA { parts.append(sha) }
        if let message = d.commit?.firstLine { parts.append("“\(message)”") }
        if parts.isEmpty, let note = d.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// "rbtaskiran@gmail.com" -> "rbtaskiran"
    static func person(_ creator: String) -> String {
        creator.split(separator: "@").first.map(String.init) ?? creator
    }

    /// Words on the card's status line: a crash and a settings change are not just "Ready".
    static func status(_ d: Deployment) -> String {
        if let dynos = d.crashedDynos, !dynos.isEmpty { return "Live, but \(dynos[0]) crashed" }
        switch d.releaseKind {
        case .config?: return "Settings"
        case .rollback?: return "Rollback"
        default: return d.state.title
        }
    }

    static func tint(_ d: Deployment) -> Color {
        if d.isCrashed { return Ink.red }
        if d.releaseKind?.isConfig == true { return Ink.purple }
        return tint(d.state)
    }

    static func symbol(_ d: Deployment) -> String {
        if d.isCrashed { return "exclamationmark.triangle.fill" }
        switch d.releaseKind {
        case .config?: return "gearshape.fill"
        case .rollback?: return "arrow.uturn.backward"
        default: return symbol(d.state)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func tint(_ state: DeployState) -> Color {
        switch state {
        case .ready: Ink.green
        case .failed: Ink.red
        case .building, .queued: Ink.warning
        case .canceled: Ink.secondary
        }
    }

    static func symbol(_ state: DeployState) -> String {
        switch state {
        case .ready: "checkmark"
        case .failed: "xmark"
        case .building: "hammer"
        case .queued: "clock"
        case .canceled: "slash.circle"
        }
    }

    static func providerSymbol(_ p: DeployProvider) -> String {
        switch p {
        case .vercel: "triangle.fill"
        case .heroku: "hexagon.fill"
        }
    }
}
