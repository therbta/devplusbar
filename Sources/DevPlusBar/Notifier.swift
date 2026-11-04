import AppKit
import UserNotifications

/// macOS bildirimleri.
///
/// UNUserNotificationCenter yalnizca imzali bir uygulama paketi icinde calisir;
/// `swift run` ile calistirildiginda sessizce devre disi kalir. Bu yuzden her
/// cagri `isAvailable` ile korunuyor — uygulamanin gelistirme modunda cokmesi
/// yerine bildirimsiz calismasi tercih edildi.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    /// Bildirime tiklandiginda cagrilir; URL'i acmak ve gorulmus isaretlemek
    /// AppDelegate'in isi.
    var onOpen: ((String) -> Void)?

    /// Ozet bildirimine ("12 new items") tiklandiginda cagrilir; tek bir URL
    /// olmadigi icin dogru davranis menuyu acmak.
    var onOpenSummary: (() -> Void)?

    /// A notice without a URL opens the panel on its side.
    var onOpenMode: ((PanelMode) -> Void)?

    /// Paket kimligi yoksa (swift run) bildirim altyapisi hic kurulmaz.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Delegate'i baglar ama izin ISTEMEZ.
    ///
    /// Izin istemek ilk gercek bildirimin gonderilecegi ana ertelendi. Onceki
    /// surum acilista soruyordu: kullanici Dev+ Bar'i ilk kez calistirdiginda,
    /// daha giris bile yapmadan, ne icin oldugunu bilmedigi bir izin penceresi
    /// goruyordu. Baglamsiz sorulan izin hem daha cok reddediliyor hem de App
    /// Review'in 5.1.1 kalemine takilabiliyor.
    func start() {
        guard isAvailable else {
            NSLog("Dev+ Bar: paket disinda calisiliyor, bildirimler kapali")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.deployCategory, actions: [
                UNNotificationAction(identifier: "visit", title: "Visit site"),
                UNNotificationAction(identifier: "logs", title: "View logs"),
            ], intentIdentifiers: []),
        ])
    }

    static let deployCategory = "deploy"

    /// Asks for permission the first time there is something to show, then delivers.
    ///
    /// The permission is looked up each time rather than remembered: a user who first said
    /// no and later allows Dev+ Bar in System Settings gets notifications from then on, without
    /// relaunching.
    func notify(about items: [Item]) {
        guard isAvailable, !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional:
                deliver(items)
            case .notDetermined:
                // Izin penceresi tam da gosterilecek bir bildirim varken cikar: kullanici
                // "Dev+ Bar bildirim gondermek istiyor" yazisini gordugunde arkasinda gercek
                // bir olay oldugunu bilir. Izni yeni veren bu turun bildirimlerini de gorur.
                if (try? await center.requestAuthorization(options: [.alert, .sound])) == true {
                    deliver(items)
                }
            default:
                break
            }
        }
    }

    /// Changes to your own pull requests: approved, checks failed, merged and so on.
    func notify(changes: [(item: Item, event: PREvent)]) {
        guard isAvailable, !changes.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional:
                break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default:
                return
            }
            for (item, event) in changes {
                post(id: "change-\(event.title)-\(item.url)",
                     title: "\(event.title) · \(item.repositoryName) #\(item.number)",
                     body: item.title,
                     url: item.problemPage(for: event) ?? item.url)
            }
        }
    }

    /// New comments from people on threads Dev+ Bar shows.
    func notify(comments items: [Item]) {
        guard isAvailable, !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            if items.count > 5 {
                post(id: "comment-summary-\(Date().timeIntervalSince1970)",
                     title: "\(items.count) new comments",
                     body: "People commented on \(items.count) of your threads.",
                     url: nil, isSummary: true)
                return
            }
            for item in items {
                post(id: "comment-\(item.url)-\(item.comments)",
                     title: "New comment · \(item.repositoryName) #\(item.number)",
                     body: "\(item.title)\n@\(item.lastCommenter ?? "someone")",
                     url: item.url)
            }
        }
    }

    /// Workflows on your repositories' default branch that just started failing.
    func notify(workflows failures: [WorkflowFailure]) {
        guard isAvailable, !failures.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            if failures.count > 3 {
                let repos = Set(failures.map(\.repository)).count
                post(id: "workflow-summary-\(Date().timeIntervalSince1970)",
                     title: "\(failures.count) workflows started failing",
                     body: repos == 1 ? "In \(failures[0].repository)." : "Across \(repos) repositories.",
                     url: nil, isSummary: true)
                return
            }
            for failure in failures {
                let run = failure.run
                post(id: "workflow-\(run.id)",
                     title: "Workflow failed · \(failure.repositoryName)",
                     body: "\(run.workflow)\n\(run.event) on \(failure.branch)",
                     url: run.url?.absoluteString ?? "https://github.com/\(failure.repository)/actions")
            }
        }
    }

    /// Limits, unpushed work and the rest of `BarNotice`; more than `summaryAfter` become one.
    func notify(notices: [BarNotice], summary: String? = nil, summaryAfter: Int = 3) {
        guard isAvailable, !notices.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            if notices.count > summaryAfter {
                post(id: "notice-summary-\(Date().timeIntervalSince1970)", title: summary ?? "\(notices.count) updates",
                     body: notices.prefix(3).map(\.heading).joined(separator: "\n"), url: nil,
                     mode: notices[0].mode, isSummary: notices[0].mode == nil)
                return
            }
            for n in notices {
                post(id: n.id, title: n.heading, body: ([n.title] + [n.detail].compactMap { $0 }).joined(separator: "\n"),
                     url: n.url, mode: n.url == nil ? n.mode : nil)
            }
        }
    }

    /// Deployment changes. Dev+ Bar plays its own sound for these, so the banner is silent.
    func notify(deploys alerts: [DeployAlert]) {
        let wanted = alerts.filter(\.notify)
        guard isAvailable, !wanted.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: break
            case .notDetermined:
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            default: return
            }
            if wanted.count > 3 {
                let failed = wanted.filter { $0.transition.to == .failed }.count
                post(id: "deploy-summary-\(Date().timeIntervalSince1970)",
                     title: "\(wanted.count) deployments changed",
                     body: failed > 0 ? "\(failed) failed." : "All finished.",
                     url: nil, isSummary: true, silent: true)
                return
            }
            for alert in wanted {
                let d = alert.transition.deployment
                let content = UNMutableNotificationContent()
                content.title = DeployText.headline(alert.transition)
                content.subtitle = "\(d.provider.title) · \(d.target.title)"
                content.body = DeployText.detail(d)
                content.threadIdentifier = "deploy-\(d.provider.rawValue)-\(d.project)"
                content.categoryIdentifier = Self.deployCategory
                if alert.timeSensitive { content.interruptionLevel = .timeSensitive }
                var info: [String: Any] = [:]
                if let address = d.dashboardURL?.absoluteString ?? d.url?.absoluteString { info["url"] = address; info["logs"] = address }
                if let site = d.url?.absoluteString { info["site"] = site }
                content.userInfo = info
                try? await center.add(UNNotificationRequest(identifier: "\(d.id)-\(alert.transition.to.rawValue)",
                                                            content: content, trigger: nil))
            }
        }
    }

    private func deliver(_ items: [Item]) {
        // Cok sayida yeni oge geldiginde tek tek bildirim yagdirmak yerine
        // tek bir ozet gonderilir.
        if items.count > 5 {
            post(
                id: "summary-\(items.count)-\(items[0].id)",
                title: "\(items.count) new items",
                body: "Your repositories have \(items.count) new pull requests and issues.",
                url: nil,
                isSummary: true
            )
            return
        }

        for item in items {
            let kind = item.kind == .pullRequest ? "pull request" : "issue"
            post(
                id: item.url,
                title: "New \(kind) · \(item.repositoryName) #\(item.number)",
                body: "\(item.title)\n@\(item.authorLogin)",
                url: item.url
            )
        }
    }

    // MARK: - Private

    private func post(id: String, title: String, body: String, url: String?, mode: PanelMode? = nil,
                      isSummary: Bool = false, silent: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        if let url { content.userInfo = ["url": url] }
        if let mode { content.userInfo = ["mode": mode.rawValue] }
        if isSummary { content.userInfo = ["summary": true] }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        ) { error in
            if let error { NSLog("Dev+ Bar: bildirim gonderilemedi: \(error.localizedDescription)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Uygulama on planda olmasa da bildirim gosterilsin. Dev+ Bar bir menu cubugu
    /// uygulamasi; "on plan" kavrami onun icin pratikte hic olusmuyor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if info["summary"] as? Bool == true {
            // Eski surumde ozet bildirimine tiklamak sessizce hicbir sey
            // yapmiyordu — URL olmadigi icin guard'dan donuyordu.
            await MainActor.run { self.onOpenSummary?() }
            return
        }
        if let raw = info["mode"] as? String, let mode = PanelMode(rawValue: raw) {
            await MainActor.run { self.onOpenMode?(mode) }
            return
        }
        let key = switch response.actionIdentifier {
        case "visit": "site"
        case "logs": "logs"
        default: "url"
        }
        guard let url = info[key] as? String ?? info["url"] as? String else { return }
        await MainActor.run { self.onOpen?(url) }
    }
}
