import AppKit
import Defaults
import Network

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: StatusPanel!
    private let panelModel = PanelModel()
    private var statusItem: NSStatusItem { panel.statusItem }
    private let seenStore = SeenStore(url: SeenStore.defaultURL)
    private let notifier = Notifier()
    private let workflows = WorkflowMonitor.shared
    private var toast: BarToast!
    #if !MAS
    private let updateChecker = UpdateChecker()
    #endif
    private let welcome = WelcomeController()
    private let settingsWindow = SettingsController()
    private let session = AuthSession.shared
    /// The welcome window opens by itself once per launch while nobody is signed in.
    private var welcomedThisLaunch = false
    private var settingsObserver: Task<Void, Never>?
    private var displayObserver: Task<Void, Never>?

    private var sections: [MenuSection] = []
    private var viewer: Viewer?
    private var social: Social?
    private var rateLimit: RateLimit?
    private var errors: [AppError] = []
    /// Warnings shown with fresh data: dropped filters, GitHub's partial errors.
    private var notices: [String] = []
    /// No refreshes until then: GitHub's rate limit is spent.
    private var rateLimitedUntil: Date?
    private let pathMonitor = NWPathMonitor()
    private var online = true
    /// A refresh that waits for the network: after wake, or after one failed offline.
    private var refreshWhenOnline = false
    private var lastRefresh: Date?
    private var refreshGate = RefreshGate()
    private var timer: Timer?
    private var iconShowsBlocked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock'ta ikon gosterme. Asama 2'de .app paketine LSUIElement eklenecek;
        // bu satir swift run ile calistirirken ayni isi goruyor.
        NSApp.setActivationPolicy(.accessory)

        panel = StatusPanel(style: PanelPreview.style) { PanelView(model: panelModel) }
        panel.onOpen = { [weak self] in self?.toast.close(); self?.panelWillOpen() }
        toast = BarToast(statusItem: panel.statusItem, style: PanelPreview.style)
        toast.onOpen = { [weak self] url in self?.open(url, markSeen: true) }
        toast.onOpenSummary = { [weak self] in self?.panel.open() }
        toast.onOpenMode = { [weak self] mode in self?.open(mode) }
        panel.onClose = { [weak self] in self?.flushNotices() }
        panelModel.actions = PanelActions(
            open: { [weak self] item in self?.panel.close(); self?.open(item.url, markSeen: true) },
            // A view inside the item, such as its checks; the item itself counts as seen.
            openPage: { [weak self] item, address in
                self?.panel.close()
                self?.seenStore.markSeen([item.url], at: Date())
                try? self?.seenStore.save()
                self?.open(address, markSeen: false)
            },
            openAddress: { [weak self] address in self?.panel.close(); self?.open(address, markSeen: false) },
            markAllSeen: { [weak self] in self?.markAllSeen() },
            markSectionSeen: { [weak self] kind in self?.markSeen(kind) },
            markSeen: { [weak self] urls in
                self?.seenStore.markSeen(urls, at: Date())
                try? self?.seenStore.save()
                self?.rebuildMenu()
            },
            hideRepository: { [weak self] repository in self?.hideRepository(repository) },
            openProfile: { [weak self] in self?.panel.close(); self?.openProfile() },
            refresh: { [weak self] in self?.refresh() },
            openSettings: { [weak self] in self?.panel.close(); self?.openSettings() },
            signIn: { [weak self] in self?.panel.close(); self?.openWelcome() },
            toggleOrganization: { [weak self] org in self?.toggleOrganization(org) },
            clearOrganizations: { [weak self] in self?.clearOrganizations() },
            quit: { [weak self] in self?.quit() }
        )
        statusItem.button?.image = StatusIcon.image()
        statusItem.button?.imagePosition = .imageLeading
        // Sayac esit genislikli rakamlarla: sayi degistiginde menu cubugundaki
        // komsu ikonlar saga sola oynamasin.
        statusItem.button?.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular
        )

        // After signing in, show what is now there: the panel opens and fills as the first
        // refresh lands.
        welcome.onSignedIn = { [weak self] in
            self?.refresh()
            self?.panel.open()
        }
        settingsWindow.onSignOut = { [weak self] in self?.signOut() }
        settingsWindow.onSignIn = { [weak self] in self?.openWelcome() }
        notifier.onOpen = { [weak self] url in self?.open(url, markSeen: true) }
        notifier.onOpenSummary = { [weak self] in self?.panel.open() }
        notifier.onOpenMode = { [weak self] mode in self?.open(mode) }
        notifier.start()
        startDeployments()
        #if !MAS
        updateChecker.start()
        #endif
        Task.detached(priority: .background) { AuthorAvatars.prune() }
        rebuildMenu()

        scheduleTimer()

        // Ayar degisikligi aninda yansir (spec §8): Defaults yayinlarini
        // dinle, zamanlayiciyi yeni araliga kur, yenile.
        settingsObserver = Task { [weak self] in
            for await _ in Defaults.updates([.accounts, .organizations, .repoList,
                                             .repoListIsAllowList, .showBots, .showDrafts,
                                             .showPullRequests, .showIssues,
                                             .showReviewRequested, .showChangesRequested,
                                             .showMyPullRequests, .showMentions,
                                             .refreshMinutes, .repoGroupThreshold], initial: false) {
                guard let self else { return }
                self.scheduleTimer()
                self.refresh()
            }
        }

        // Yalnizca cizimi degistiren ayarlar. Yukaridaki listeye konsaydi her
        // isaret bir GitHub istegi harcardi; elde olan veri zaten yeterli.
        displayObserver = Task { [weak self] in
            for await _ in Defaults.updates([.showEmptySections, .rateLimitVisibility, .showAIUsage, .showLocal, .localRoots], initial: false) {
                guard let self else { return }
                if Defaults[.showAIUsage] { await AIMonitor.shared.scanNow() }
                if Defaults[.showLocal] { await LocalMonitor.shared.scanNow() }
                if self.panelModel.mode == .ai && !Defaults[.showAIUsage] { self.panelModel.mode = .work }
                if self.panelModel.mode == .local && !Defaults[.showLocal] { self.panelModel.mode = .work }
                self.rebuildMenu()
            }
        }

        // Uykudan uyaninca yenile; onsuz kapagi actiginda saatler oncesinin
        // verisini gorursun ve bayat oldugunu anlamanin yolu yoktur.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The overdue timer would fire too: restart it, and refresh once the network is
            // back, which it usually is not the moment the lid opens.
            Task { @MainActor in
                guard let self else { return }
                self.scheduleTimer()
                if self.online { self.refresh() } else { self.refreshWhenOnline = true }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isOnline) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        refresh()

        // Gizli bayrak: kutuyu ornek ogelerle goster. Kullanim: Dev+ Bar --demo-toast [adet]
        if let flag = CommandLine.arguments.firstIndex(of: "--demo-toast") {
            let count = CommandLine.arguments.indices.contains(flag + 1)
                ? Int(CommandLine.arguments[flag + 1]) ?? 1 : 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.toast.show(BarToast.demoItems(count))
            }
        }
    }

    // MARK: - Notices

    /// Notices that wait for the panel to close: the panel covers the pop-up.
    private var pendingNotices: [BarNotice] = []

    /// As a macOS notification and as the menu-bar pop-up, so it is seen with either turned off.
    private func deliver(_ notices: [BarNotice], summary: String? = nil) {
        guard !notices.isEmpty else { return }
        if Defaults[.notificationsEnabled] { notifier.notify(notices: notices, summary: summary) }
        pop(notices)
    }

    /// The pop-up alone. With the panel open, the ones that point at a panel side wait for it to
    /// close; the rest (a run, a thread) are skipped, as new items are.
    private func pop(_ notices: [BarNotice]) {
        guard Defaults[.showBarToast], !notices.isEmpty else { return }
        if panel.isOpen {
            pendingNotices += notices.filter { $0.url == nil }
        } else {
            toast.show(notices: notices)
        }
    }

    private func flushNotices() {
        guard !pendingNotices.isEmpty else { return }
        let waiting = pendingNotices
        pendingNotices = []
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !self.panel.isOpen else { self.pendingNotices = waiting + self.pendingNotices; return }
            self.toast.show(notices: waiting)
        }
    }

    private func open(_ mode: PanelMode) {
        panelModel.mode = mode
        panel.open()
    }

    // MARK: - Deployments

    private var deployObserver: Task<Void, Never>?
    private var deployHotKey: GlobalHotKey?

    /// Vercel and Heroku run beside GitHub, on their own pace, and report back here.
    private func startDeployments() {
        let deploys = DeployMonitor.shared
        deploys.onAlerts = { [weak self] alerts in
            guard let self else { return }
            if Defaults[.notificationsEnabled] { self.notifier.notify(deploys: alerts) }
            if Defaults[.deployToast], !self.panel.isOpen { self.toast.show(deploys: alerts) }
        }
        deploys.onChange = { [weak self] in self?.rebuildMenu() }
        deploys.githubToken = { [weak self] in await self?.session.token() }
        workflows.githubToken = { [weak self] in await self?.session.token() }
        workflows.onFailures = { [weak self] failures in
            guard let self else { return }
            if Defaults[.notificationsEnabled] { self.notifier.notify(workflows: failures) }
            self.pop(failures.map(BarNotice.workflow))
        }
        AIMonitor.shared.onCapNotice = { [weak self] notice in self?.deliver([notice]) }
        LocalMonitor.shared.onNudge = { [weak self] repos in
            self?.deliver(repos.map { UnpushedWatch.notice($0) },
                          summary: "\(repos.count) repositories have work only on this Mac")
        }
        toast.onOpenDeploys = { [weak self] in
            self?.panelModel.mode = .deploys
            self?.panel.open()
        }
        deploys.start()
        AIMonitor.shared.onChange = { [weak self] in self?.rebuildMenu() }
        AIMonitor.shared.start()
        LocalMonitor.shared.onChange = { [weak self] in self?.rebuildMenu() }
        LocalMonitor.shared.start()
        // ⌥⌘D from anywhere: the panel, on its Deploys side (or closed again if it is open there).
        deployHotKey = GlobalHotKey { [weak self] in
            guard let self, !DeployMonitor.shared.connected.isEmpty else { return }
            if self.panel.isOpen && self.panelModel.mode == .deploys { self.panel.close(); return }
            self.panelModel.mode = .deploys
            if !self.panel.isOpen { self.panel.open() }
        }
        deployObserver = Task { [weak self] in
            for await _ in Defaults.updates([.deployHiddenProjects, .deployShowPreviews, .deployPinnedProjects,
                                             .deployRelayURL, .herokuApps, .vercelTeamID], initial: false) {
                guard self != nil else { return }
                deploys.recompute()
                deploys.startRelay()
                deploys.refresh()
            }
        }
    }

    // MARK: - Yenileme

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.refreshInterval(),
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = Settings.refreshInterval() / 10
    }

    func refresh() {
        guard refreshGate.begin() else { return }
        DeployMonitor.shared.refresh()

        Task { @MainActor in
            // The panel learns the refresh ended only here: every rebuild above still saw
            // the gate running, and the refresh button kept spinning.
            defer { if refreshGate.finish() { refresh() } else { rebuildMenu() } }

            // While GitHub's rate limit is spent, asking again only lengthens the wait.
            if let until = rateLimitedUntil, until > Date() {
                rebuildMenu()
                return
            }

            // Kapi acildi; menu artik "Refreshing…" gosterebilir.
            rebuildMenu()

            // Results of a refresh that outlives a sign-out or an account switch are dropped.
            let generation = session.generation
            guard let token = await session.token(), session.generation == generation else {
                // Oturum yoklugu hata satiri degil, panelde eyleme cagri.
                clearAccountData()
                rebuildMenu()
                if !welcomedThisLaunch {
                    welcomedThisLaunch = true
                    welcome.show()
                }
                return
            }
            welcomedThisLaunch = true
            rebuildMenu()   // the session is known now; drop any "Sign in" the panel showed

            do {
                let settings = Settings.fromDefaults()
                let queries = Query.build(settings)

                var notes: [String] = []
                if queries.allowListEmpty { notes.append(AppError.allowListEmpty.menuText) }
                if queries.filtersDropped { notes.append(AppError.filtersDropped.menuText) }

                guard !queries.allowListEmpty else {
                    errors = []
                    notices = notes
                    sections = []
                    rebuildMenu()
                    return
                }

                let snapshot = try await GitHubClient(token: token).fetch(queries)
                guard session.generation == generation else { return }
                apply(snapshot, settings: settings, notes: notes)
                workflows.check(token: token, settings: settings)
            } catch AppError.unauthorized {
                // GitHub token'i reddetti: hata satiri degil, yeniden giris cagrisi.
                guard session.generation == generation else { return }
                session.markExpired(generation: generation)
                clearAccountData()
            } catch AppError.rateLimited(let resetAt) {
                rateLimitedUntil = resetAt
                errors = [.rateLimited(resetAt)]
            } catch let error as AppError {
                errors = [error]
                if case .network = error { refreshWhenOnline = true }
            } catch {
                errors = [.network(error.localizedDescription)]
                refreshWhenOnline = true
            }

            rebuildMenu()
        }
    }

    private func apply(_ snapshot: Snapshot, settings: Settings, notes: [String]) {
        let now = Date()
        // A different account than the one whose data is stored: start over, so its
        // organizations, repositories and seen marks do not leak into the new account.
        if let owner = Defaults[.signedInLogin], owner != snapshot.viewer.login {
            resetAccountScopedState()
        }
        session.loaded(login: snapshot.viewer.login)
        DeployMonitor.shared.githubLogin = snapshot.viewer.login

        let built = Filtering.sections(from: snapshot, settings: settings)
        let all = built.flatMap(\.items)

        // Ayarlar > Repositories icin aktivite listesi. Merged rather than replaced: a
        // repository hidden by the allow list must stay in the list to be ticked again.
        Defaults[.knownOrganizations] = snapshot.viewer.organizations
        var repos = Defaults[.knownRepos].mapValues { _ in 0 }
        for (repo, items) in Dictionary(grouping: all, by: \.repository) { repos[repo] = items.count }
        Defaults[.knownRepos] = repos

        // Gorulme ve bildirim kaydi. Everything GitHub returned counts as still around, even
        // what a filter hides; entries are forgotten by age.
        let returned = snapshot.prs + snapshot.issues + snapshot.review
            + snapshot.changesRequested + snapshot.myPullRequests
        seenStore.recordReturned(Set(returned.map(\.url)), at: now)
        seenStore.prune(now: now)
        var placement: [String: SectionKind] = [:]
        for section in built { for item in section.items { placement[item.url] = section.kind } }
        _ = seenStore.promote(placement)

        // Your own pull requests are not news to you: no notification, no badge.
        let incoming = built.filter { $0.kind != .myPullRequests }.flatMap(\.items)
        let firstRun = seenStore.markFirstRunDone()
        let backfill = seenStore.claimNotificationBackfill()
        let fresh = (firstRun || backfill) ? [] : seenStore.unnotified(among: incoming)
        seenStore.markNotified(all.map(\.url))
        try? seenStore.save()
        if Defaults[.notificationsEnabled] { notifier.notify(about: fresh) }

        // Your own pull requests: news only when their state changes.
        let watch = PullRequestWatch.changes(
            previous: PullRequestWatch.decode(Defaults[.pullRequestSignals]),
            open: snapshot.myPullRequests,
            merged: snapshot.merged
        )
        Defaults[.pullRequestSignals] = PullRequestWatch.encode(watch.next)
        if Defaults[.notificationsEnabled], Defaults[.notifyOwnPullRequests] {
            notifier.notify(changes: watch.events)
        }
        // Comments from people. Read from every search, before filtering: a bot's thread is
        // hidden by default, but a person answering in it is not bot activity.
        let comments = CommentWatch.changes(
            previous: Defaults[.commentCounts],
            items: returned + snapshot.mentions,
            viewer: snapshot.viewer.login
        )
        Defaults[.commentCounts] = comments.next
        if Defaults[.notificationsEnabled], Defaults[.notifyComments] {
            notifier.notify(comments: comments.events)
        }
        // Panel aciksa yeni ogeler zaten gozunun onunde.
        if Defaults[.showBarToast], !panel.isOpen {
            if !fresh.isEmpty { toast.show(fresh) }
            else if Defaults[.notifyComments], !comments.events.isEmpty { toast.show(notices: comments.events.map(BarNotice.comment)) }
        }

        viewer = snapshot.viewer
        social = snapshot.social
        rateLimit = snapshot.rateLimit
        rateLimitedUntil = snapshot.rateLimit.remaining == 0 ? snapshot.rateLimit.resetAt : nil
        sections = built
        errors = []
        notices = notes + snapshot.warnings
        lastRefresh = now

        // Avatar bir kez inip diske yaziliyor; it no longer holds up the results.
        let address = snapshot.viewer.avatarURL
        Task { [weak self] in
            if await Avatar.refresh(from: address) { self?.rebuildMenu() }
        }
    }

    /// The network came back (or went): a refresh that was waiting for it runs now.
    private func networkChanged(_ isOnline: Bool) {
        let cameBack = isOnline && !online
        online = isOnline
        guard cameBack, refreshWhenOnline else { return }
        refreshWhenOnline = false
        refresh()
    }

    /// What belongs to one GitHub account and must not carry over to another.
    private func resetAccountScopedState() {
        Defaults[.organizations] = []
        Defaults[.knownOrganizations] = []
        Defaults[.knownRepos] = [:]
        seenStore.reset()
        Defaults[.pullRequestSignals] = [:]
        Defaults[.commentCounts] = [:]
        workflows.reset()
        Avatar.forget()
    }

    private func rebuildMenu() {
        // Your own pull requests are never "new": they do not count, and show no green dot.
        let mine = Set(sections.filter { $0.kind == .myPullRequests }.flatMap(\.items).map(\.url))
        let unseen = sections.filter { $0.kind != .myPullRequests }.flatMap(\.items)
            .filter { !seenStore.isSeen($0.url) }.count
        statusItem.button?.title = session.state.isSignedIn && unseen > 0 ? " \(unseen)" : ""
        // A dot on the icon while one of your pull requests is stuck on you.
        let deploys = DeployMonitor.shared
        let blocked = (session.state.isSignedIn && sections.flatMap(\.items).contains { item in
            item.authorLogin == viewer?.login
                && [.changesRequested, .conflicts, .failing].contains(item.status(now: Date()))
        }) || deploys.hasRecentFailure
        if blocked != iconShowsBlocked {
            iconShowsBlocked = blocked
            statusItem.button?.image = StatusIcon.image(alert: blocked)
            statusItem.button?.setAccessibilityLabel(blocked ? "Dev+ Bar, a pull request of yours needs attention" : "Dev+ Bar")
        }

        let settings = Settings.fromDefaults()
        panelModel.input = PanelInput(
            viewer: viewer,
            social: social,
            sections: sections,
            rateLimit: rateLimit,
            errors: errors,
            notices: notices,
            lastRefresh: lastRefresh,
            auth: session.state,
            authRefused: session.refused,
            isRefreshing: refreshGate.isRunning,
            showOwner: settings.accounts.count > 1 || !settings.organizations.isEmpty,
            knownOrganizations: Defaults[.knownOrganizations],
            selectedOrganizations: settings.organizations,
            repositoryFilterActive: !settings.repoList.isEmpty,
            repositoryFilterIsAllowList: settings.repoListIsAllowList,
            visibleSections: settings.visibleSections,
            showEmptySections: settings.showEmptySections,
            rateLimitVisibility: settings.rateLimitVisibility,
            isSeen: { [seenStore] url in mine.contains(url) || seenStore.isSeen(url) },
            now: Date(),
            deploysEnabled: !deploys.connected.isEmpty,
            aiEnabled: Defaults[.showAIUsage] && AIMonitor.shared.hasData,
            localEnabled: Defaults[.showLocal] && LocalMonitor.shared.hasData,
            localUnpushed: Defaults[.showLocal] ? LocalMonitor.shared.unpushedCount : 0,
            deployIndicator: deploys.hasRecentFailure ? .failed : (deploys.hasActive ? .building : nil),
            deploymentFor: { [byPullRequest = Self.deploymentsByPullRequest(deploys.deployments)] item in
                byPullRequest[item.url]
            }
        )
        panel.contentChanged()
    }

    /// The newest deployment of each pull request, by its GitHub URL.
    static func deploymentsByPullRequest(_ list: [Deployment]) -> [String: Deployment] {
        var result: [String: Deployment] = [:]
        for d in list { if let url = d.pullRequestURL, result[url] == nil { result[url] = d } }
        return result
    }

    // MARK: - Menu eylemleri

    /// Menuden ve bildirimden ortak kullanilan acma yolu.
    private func open(_ address: String, markSeen: Bool) {
        guard let url = URL(string: address) else { return }
        if markSeen {
            seenStore.markSeen([address], at: Date())
            try? seenStore.save()
        }
        NSWorkspace.shared.open(url)
        rebuildMenu()
    }

    func markSeen(_ kind: SectionKind) {
        guard let section = sections.first(where: { $0.kind == kind }) else { return }

        seenStore.markSeen(section.items.map(\.url), at: Date())
        try? seenStore.save()
        rebuildMenu()
    }

    /// Adds the repository to the block list, or takes it off the allow list; asks first.
    func hideRepository(_ repository: String) {
        // An empty allow list means "watch everything": removing its last entry would do the opposite.
        if Defaults[.repoListIsAllowList], Defaults[.repoList].count <= 1 {
            let info = NSAlert()
            info.messageText = "\(repository) is the only watched repository"
            info.informativeText = "Change the list in Settings › Repositories."
            NSApp.activate(ignoringOtherApps: true)
            info.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop watching \(repository)?"
        alert.informativeText = "Its pull requests and issues leave the panel. Settings › Repositories brings it back."
        alert.addButton(withTitle: "Stop Watching")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if Defaults[.repoListIsAllowList] {
            Defaults[.repoList].removeAll { $0.caseInsensitiveCompare(repository) == .orderedSame }
        } else if !Defaults[.repoList].contains(where: { $0.caseInsensitiveCompare(repository) == .orderedSame }) {
            Defaults[.repoList].append(repository)
        }
    }

    func markAllSeen() {
        seenStore.markSeen(sections.flatMap(\.items).map(\.url), at: Date())
        try? seenStore.save()
        rebuildMenu()
    }

    func openProfile() {
        guard let viewer, let url = URL(string: viewer.profileURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleOrganization(_ org: String) {
        var selected = Defaults[.organizations]
        if selected.contains(org) {
            selected.removeAll { $0 == org }
        } else {
            selected.append(org)
        }
        Defaults[.organizations] = selected
        // Yenileme ag turunu bekliyor; menuyu simdi kurmazsak tik bir sonraki
        // acilista donuyor ve tiklama islenmemis gibi gorunuyor.
        rebuildMenu()
    }

    func clearOrganizations() {
        Defaults[.organizations] = []
        // toggleOrganization ile ayni sebep: yenileme ag turunu bekliyor.
        rebuildMenu()
    }

    func openWelcome() { welcome.show() }

    func openSettings() { settingsWindow.show() }

    /// Sign Out means signed out: the token goes, and a signed-in `gh` is not picked up again
    /// until the user chooses it.
    private func signOut() {
        session.signOut()
        resetAccountScopedState()
        Defaults[.signedInLogin] = nil
        clearAccountData()
        rebuildMenu()
    }

    /// What belonged to the account that is no longer signed in.
    private func clearAccountData() {
        sections = []
        errors = []
        notices = []
        rateLimitedUntil = nil
        viewer = nil
        social = nil
        rateLimit = nil
        lastRefresh = nil
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: - Panel

    /// Paneli art arda acip kapatmak gereksiz istek uretmesin diye 30 saniyelik
    /// alt sinir var.
    private func panelWillOpen() {
        panelModel.input?.now = Date()
        panelModel.opened += 1
        // lastRefresh nil = henuz hic basarili yenileme olmadi (ilk deneme
        // basarisiz olmus olabilir); menuyu acmak yeniden denemek icin en
        // dogru an. distantPast, 30 saniyelik esigi otomatik gecirir.
        let last = lastRefresh ?? .distantPast
        if Date().timeIntervalSince(last) > 30 { refresh() }
    }
}
