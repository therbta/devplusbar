import SwiftUI
import Defaults
import UserNotifications

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {

    var onSignOut: (() -> Void)?
    var onSignIn: (() -> Void)?
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = SettingsView(onSignOut: { [weak self] in self?.onSignOut?() },
                                onSignIn: { [weak self] in self?.onSignIn?() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Dev+ Bar Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closed by any means, including the red button: let the window and its views go.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    var onSignOut: () -> Void
    var onSignIn: () -> Void
    @State private var selectedTab = Tab.accounts

    private enum Tab: String, CaseIterable {
        case accounts = "Accounts"
        case repositories = "Repositories"
        case deployments = "Deployments"
        case general = "General"

        var symbol: String {
            switch self {
            case .accounts: "person.crop.circle"
            case .repositories: "folder"
            case .deployments: "shippingbox"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.symbol)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundColor(.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selectedTab == tab ? Color.primary.opacity(0.1) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .accounts:
                AccountsPane(onSignOut: onSignOut, onSignIn: onSignIn)
            case .repositories:
                RepositoriesPane()
            case .deployments:
                DeploymentsPane()
            case .general:
                GeneralPane()
            }
        }
        .frame(width: 500, height: 520)
    }
}

// MARK: - Accounts

struct AccountsPane: View {
    var onSignOut: () -> Void
    var onSignIn: () -> Void
    @ObservedObject private var session = AuthSession.shared
    @State private var confirmingSignOut = false
    @Default(.accounts) private var accounts
    @Default(.organizations) private var organizations
    @Default(.knownOrganizations) private var knownOrganizations
    @State private var newAccount = ""

    private var organizationRows: [String] {
        Array(Set(knownOrganizations).union(organizations)).sorted()
    }

    var body: some View {
        Form {
            sessionSection
            // Watching other accounts and organizations needs a signed-in account to ask with.
            if session.state.isSignedIn {
                watchedSections
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out of GitHub?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive, action: onSignOut)
        } message: {
            Text(session.state.source == .githubCLI
                 ? "Dev+ Bar stops using the GitHub CLI's account. gh itself stays signed in."
                 : "Dev+ Bar forgets its GitHub token. Your seen and unseen marks are cleared.")
        }
    }

    @ViewBuilder
    private var watchedSections: some View {
            Section("Watched accounts") {
                ForEach(accounts, id: \.self) { account in
                    HStack {
                        Text(account)
                        Spacer()
                        if account != "@me" {
                            Button {
                                accounts.removeAll { $0 == account }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    TextField("username", text: $newAccount)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newAccount.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("@me is you. Personal repositories stay on this list.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("Organizations") {
                if organizationRows.isEmpty {
                    Text("Organizations you belong to appear here after a refresh.")
                        .foregroundStyle(.secondary)
                }
                ForEach(organizationRows, id: \.self) { org in
                    Toggle(isOn: organizationBinding(org)) {
                        Text(org)
                    }
                }
                Text("Checked organizations show assigned pull requests, issues, and review requests.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
    }

    private func organizationBinding(_ org: String) -> Binding<Bool> {
        Binding(
            get: { organizations.contains(org) },
            set: { on in
                if on {
                    if !organizations.contains(org) { organizations.append(org) }
                } else {
                    organizations.removeAll { $0 == org }
                }
            }
        )
    }

    /// Who Dev+ Bar is signed in as and how, or what to do when it is not.
    @ViewBuilder
    private var sessionSection: some View {
        Section("GitHub account") {
            switch session.state {
            case .signedIn(let source):
                HStack(spacing: 12) {
                    accountPicture
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.login.map { "@\($0)" } ?? "Signed in").font(.headline)
                        Text(source == .oauth ? "Signed in with GitHub" : "Using the GitHub CLI's account")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out…") { confirmingSignOut = true }
                }
                if source == .oauth {
                    LabeledContent("Repository access") {
                        HStack {
                            Text(session.privateAccess ? "Public and private" : "Public only")
                                .foregroundStyle(.secondary)
                            Button("Change…", action: onSignIn)
                        }
                    }
                } else {
                    LabeledContent("Repository access", value: "Whatever gh can see")
                }

            case .expired:
                Label(session.state.expiryMessage(refused: session.refused),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Sign In Again…", action: onSignIn)
                    .buttonStyle(.borderedProminent)

            case .signedOut:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not signed in").font(.headline)
                    Text("Sign in to see the pull requests and issues people open on your repositories.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign In…", action: onSignIn)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var accountPicture: some View {
        Group {
            if let image = Avatar.cached(size: 72) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private func add() {
        let name = newAccount.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, !accounts.contains(name) else { return }
        accounts.append(name)
        newAccount = ""
    }
}

// MARK: - Repositories

struct RepositoriesPane: View {
    @Default(.repoList) private var repoList
    @Default(.repoListIsAllowList) private var isAllowList
    @Default(.knownRepos) private var knownRepos
    @State private var newRepo = ""

    /// Gorulen repolar + listede olup artik oge uretmeyenler.
    private var rows: [String] {
        Array(Set(knownRepos.keys).union(repoList)).sorted { a, b in
            let (ca, cb) = (knownRepos[a] ?? 0, knownRepos[b] ?? 0)
            return ca != cb ? ca > cb : a < b
        }
    }

    var body: some View {
        Form {
            Section {
                // Maccy'nin ignoreAllAppsExceptListed kalibi (spec §8): TEK
                // liste, anlami tersine ceviren kutucuk. Kapaliyken isaretsiz
                // repolar dislanir; acikken yalniz isaretliler izlenir.
                Toggle("Watch only the listed repositories", isOn: $isAllowList)
                Text(isAllowList
                     ? "Only checked repositories are watched."
                     : "Unchecked repositories are hidden.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Section("Repositories") {
                if rows.isEmpty {
                    Text("Repositories appear here as Dev+ Bar sees activity in them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.self) { repo in
                    Toggle(isOn: watchedBinding(repo)) {
                        HStack {
                            Text(repo)
                            Spacer()
                            if let count = knownRepos[repo], count > 0 {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    TextField("owner/name", text: $newRepo)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(!newRepo.contains("/"))
                }
            }
        }
        .formStyle(.grouped)
    }

    /// listede = (allow modunda) izleniyor / (deny modunda) gizli.
    private func watchedBinding(_ repo: String) -> Binding<Bool> {
        Binding(
            get: { isAllowList ? repoList.contains(repo) : !repoList.contains(repo) },
            set: { watched in
                let shouldBeListed = isAllowList ? watched : !watched
                if shouldBeListed {
                    if !repoList.contains(repo) { repoList.append(repo) }
                } else {
                    repoList.removeAll { $0 == repo }
                }
            }
        )
    }

    private func add() {
        let name = newRepo.trimmingCharacters(in: .whitespaces)
        guard name.contains("/"), !repoList.contains(name) else { return }
        repoList.append(name)
        newRepo = ""
    }
}

// MARK: - General

struct GeneralPane: View {
    @Default(.refreshMinutes) private var refreshMinutes
    @Default(.notificationsEnabled) private var notificationsEnabled
    @Default(.showBarToast) private var showBarToast
    @Default(.notifyWorkflowFailures) private var notifyWorkflowFailures
    @Default(.notifyComments) private var notifyComments
    @Default(.notifyClaudeCap) private var notifyClaudeCap
    @Default(.notifyUnpushed) private var notifyUnpushed
    /// What macOS allows, not what Dev+ Bar wants: with notifications off in System Settings
    /// every banner is dropped without a word, so the pane says so.
    @State private var systemDenied = false
    @Default(.showBots) private var showBots
    @Default(.showDrafts) private var showDrafts
    @Default(.showPullRequests) private var showPullRequests
    @Default(.showIssues) private var showIssues
    @Default(.showReviewRequested) private var showReviewRequested
    @Default(.showChangesRequested) private var showChangesRequested
    @Default(.showMyPullRequests) private var showMyPullRequests
    @Default(.showMentions) private var showMentions
    @Default(.showEmptySections) private var showEmptySections
    @Default(.rateLimitVisibility) private var rateLimitVisibility
    @Default(.repoGroupThreshold) private var groupThreshold
    @Default(.checkForUpdates) private var checkForUpdates
    @Default(.showAIUsage) private var showAIUsage
    @Default(.showLocal) private var showLocal
    @Default(.localRoots) private var localRoots

    var body: some View {
        Form {
            Section("Tabs in the panel") {
                Toggle(SectionKind.reviewRequested.tabTitle(short: false), isOn: $showReviewRequested)
                Toggle("\(SectionKind.changesRequested.tabTitle(short: false)) requested on your pull requests",
                       isOn: $showChangesRequested)
                Toggle(SectionKind.pullRequests.tabTitle(short: false), isOn: $showPullRequests)
                Toggle(SectionKind.issues.tabTitle(short: false), isOn: $showIssues)
                Toggle(SectionKind.myPullRequests.tabTitle(short: false), isOn: $showMyPullRequests)
                Toggle(SectionKind.mentions.tabTitle(short: false), isOn: $showMentions)
                Toggle("Keep empty tabs visible", isOn: $showEmptySections)
                Toggle("AI usage (Claude Code, Codex logs on this Mac)", isOn: $showAIUsage)
                Toggle("Local work (unpushed repositories, dev servers on this Mac)", isOn: $showLocal)
                if showLocal {
                    TextField("Folders", text: $localRoots,
                              prompt: Text(LocalScanner.defaultRoots().map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")))
                        .help("Comma-separated. Repositories up to three folders deep are found. Empty = the usual places.")
                }
            }
            Section("Panel footer") {
                Picker("Show API calls left", selection: $rateLimitVisibility) {
                    Text("Never").tag(RateLimitVisibility.never.rawValue)
                    Text("When low").tag(RateLimitVisibility.whenLow.rawValue)
                    Text("Always").tag(RateLimitVisibility.always.rawValue)
                }
            }

            Picker("Refresh every", selection: $refreshMinutes) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
            }
            Toggle("Show notifications", isOn: $notificationsEnabled)
            if notificationsEnabled && systemDenied {
                HStack {
                    Label("macOS has notifications turned off for Dev+ Bar, so none are shown. The menu bar pop-up still works.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open System Settings") { NotificationPermission.openSystemSettings() }
                }
            }
            Toggle("Notify when a workflow on your repositories' default branch starts failing",
                   isOn: $notifyWorkflowFailures)
            Toggle("Notify when someone comments on a thread here (not you, not a bot)", isOn: $notifyComments)
            Toggle("Warn at 75% and 90% of the weekly Claude Code limit, and when your pace runs out before the reset",
                   isOn: $notifyClaudeCap)
            Toggle("Nudge when recent commits have sat a day without being pushed", isOn: $notifyUnpushed)
            Toggle("Drop a pop-up from the menu bar icon", isOn: $showBarToast)
            Toggle("Show bot activity", isOn: $showBots)
            Toggle("Show draft pull requests", isOn: $showDrafts)
            Picker("Group repositories with more than", selection: $groupThreshold) {
                Text("3 items").tag(3)
                Text("5 items").tag(5)
                Text("10 items").tag(10)
                Text("Never group").tag(0)
            }
            if LaunchAtLogin.isAvailable {
                Toggle("Launch at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.set($0) }
                ))
            }
            #if !MAS
            Toggle("Tell me when a new version is out", isOn: $checkForUpdates)
            #endif
        }
        .formStyle(.grouped)
        .task { systemDenied = await NotificationPermission.isDenied() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { systemDenied = await NotificationPermission.isDenied() }
        }
    }
}

enum NotificationPermission {
    static func isDenied() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
