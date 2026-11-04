import Foundation

enum ItemKind: String, Sendable, Hashable {
    case pullRequest
    case issue
}

struct Item: Sendable, Hashable, Identifiable {
    let kind: ItemKind
    let repository: String      // "owner/name"
    let number: Int
    let title: String
    let url: String
    let createdAt: Date
    let isDraft: Bool
    let authorLogin: String
    let authorIsBot: Bool
    /// Last activity; nil in old fixtures, then `createdAt` stands in.
    var updatedAt: Date? = nil
    /// Pull requests only.
    var reviewDecision: ReviewDecision? = nil
    var checks: CheckState? = nil
    var comments: Int = 0
    /// Who wrote the newest comment; nil without comments, or in old fixtures.
    var lastCommenter: String? = nil
    var lastCommenterIsBot = false
    var merge: MergeBlock? = nil
    /// GitHub had not finished working out whether it merges cleanly.
    var mergeUnknown = false

    var id: String { url }
    var lastActivity: Date { updatedAt ?? createdAt }

    /// Which group the item falls in inside its tab, strongest signal first.
    func status(now: Date) -> ItemStatus {
        if now.timeIntervalSince(lastActivity) > ItemStatus.staleAfter { return .stale }
        guard kind == .pullRequest else { return .open }
        if isDraft { return .draft }
        if merge == .conflicts { return .conflicts }
        if checks == .failing { return .failing }
        switch reviewDecision {
        case .changesRequested: return .changesRequested
        case .approved: return .approved
        default: return .open
        }
    }

    /// "owner/name" -> "name"
    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }
}

enum ReviewDecision: String, Sendable, Hashable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

/// What stops a pull request from merging, besides reviews and checks.
enum MergeBlock: Sendable, Hashable {
    case conflicts
    /// The base branch moved on and the repository requires branches to be up to date.
    case behind

    /// `mergeable` is UNKNOWN while GitHub is still computing; that says nothing, so nil.
    init?(mergeable: String?, state: String?) {
        if mergeable == "CONFLICTING" || state == "DIRTY" { self = .conflicts }
        else if state == "BEHIND" { self = .behind }
        else { return nil }
    }
}

/// The last commit's combined check result.
enum CheckState: Sendable, Hashable {
    case passing, failing, pending

    init?(rollup: String) {
        switch rollup {
        case "SUCCESS": self = .passing
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }
}

/// The groups a tab's list is split into, in the order they are shown.
enum ItemStatus: Int, Sendable, Hashable, CaseIterable, Comparable {
    case changesRequested, conflicts, failing, approved, open, draft, stale

    /// No activity for this long and an item stops competing for attention.
    static let staleAfter: TimeInterval = 30 * 86_400

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .changesRequested: "Changes requested"
        case .conflicts: "Merge conflicts"
        case .failing: "Checks failing"
        case .approved: "Approved"
        case .open: "Open"
        case .draft: "Drafts"
        case .stale: "Quiet for 30+ days"
        }
    }
}

struct Viewer: Sendable, Hashable {
    let login: String
    let name: String?
    let avatarURL: String
    var organizations: [String] = []

    var displayName: String { name ?? login }
    var profileURL: String { "https://github.com/\(login)" }
}

/// Profil sayaclari: menude adin hemen altinda gosterilen "Social" bolumu.
struct Social: Sendable, Hashable {
    /// Kendi public repolarina gelen yildizlarin toplami. Fork'lar haric:
    /// fork'un yildizi orijinal repoya ait, sana degil.
    let stars: Int
    let followers: Int
    let following: Int

    /// Yildiz toplami tek sayfada (ilk 100 repo) hesaplaniyor. Daha fazla
    /// repo varsa sayi bir ALT SINIR olur; menu bunu "+" ile belli eder.
    /// Repolar yildiza gore azalan siralandigi icin sayilmayan kuyruk
    /// pratikte birkac yildiz tutar.
    let starsAreExact: Bool

    static let empty = Social(stars: 0, followers: 0, following: 0, starsAreExact: true)
}

struct RateLimit: Sendable, Hashable {
    let limit: Int
    let remaining: Int
    let resetAt: Date

    var fraction: Double {
        limit > 0 ? Double(remaining) / Double(limit) : 1
    }
}

enum SectionKind: String, Sendable, Hashable, CaseIterable {
    case pullRequests
    case issues
    case reviewRequested
    case changesRequested
    case myPullRequests
    case mentions

    /// Menudeki sira ve ayni PR birden fazla aramada ciktiginda hangi bolumun
    /// kazanacagi. Tek liste: ikisi ayri tutuldugunda menu, kodun en guclu
    /// saydigi sinyali dorduncu sirada gosteriyordu.
    ///
    /// `allCases` sirasi degistirilmiyor: ham degerler `representedObject`
    /// icinde tasiniyor ve `AppDelegate.markSectionSeen` ile eslesiyor.
    static let displayOrder: [SectionKind] = [
        .changesRequested, .reviewRequested, .mentions, .pullRequests, .issues, .myPullRequests,
    ]

    var title: String {
        switch self {
        case .pullRequests:    "Pull Requests"
        case .issues:          "Issues"
        case .reviewRequested: "Review Requested"
        case .changesRequested: "Changes Requested"
        case .myPullRequests:  "My Pull Requests"
        case .mentions:        "Mentions"
        }
    }
}

/// Menude bir satir: ya tek bir oge, ya ayni repodan toplanmis bir grup.
enum Row: Sendable, Hashable {
    case item(Item)
    case group(repository: String, items: [Item])

    var items: [Item] {
        switch self {
        case .item(let i):        [i]
        case .group(_, let list): list
        }
    }
}

struct MenuSection: Sendable, Hashable {
    let kind: SectionKind
    let rows: [Row]
    let truncated: Bool

    var items: [Item] { rows.flatMap(\.items) }
    var isEmpty: Bool { rows.isEmpty }

    func unseenCount(_ isSeen: (String) -> Bool) -> Int {
        items.filter { !isSeen($0.url) }.count
    }
}

struct Snapshot: Sendable {
    let viewer: Viewer
    let social: Social
    let prs: [Item]
    let issues: [Item]
    let review: [Item]
    let changesRequested: [Item]
    let myPullRequests: [Item]
    let rateLimit: RateLimit
    let truncated: Set<SectionKind>
    /// Errors GitHub sent along with otherwise usable data.
    var warnings: [String] = []
    /// Open threads that @-mention you, opened by someone else.
    var mentions: [Item] = []
    /// Your most recently merged pull requests, to tell "merged" from "closed".
    var merged: [Item] = []
}
