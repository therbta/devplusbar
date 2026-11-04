import AppKit
import SwiftUI

/// What the panel does when something in it is clicked; the app delegate supplies these.
struct PanelActions {
    var open: (Item) -> Void = { _ in }
    var openPage: (Item, String) -> Void = { _, _ in }
    var openAddress: (String) -> Void = { _ in }
    var markAllSeen: () -> Void = {}
    var markSectionSeen: (SectionKind) -> Void = { _ in }
    var markSeen: ([String]) -> Void = { _ in }
    /// Stops watching a repository ("owner/name").
    var hideRepository: (String) -> Void = { _ in }
    var openProfile: () -> Void = {}
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}
    var signIn: () -> Void = {}
    var toggleOrganization: (String) -> Void = { _ in }
    var clearOrganizations: () -> Void = {}
    var quit: () -> Void = {}
}

/// The panel's state: the same input the menu was built from, and the open tab.
@MainActor
final class PanelModel: ObservableObject {
    @Published var input: PanelInput?
    @Published var tab: SectionKind?
    /// The side the panel opens on. Deploys first; with no provider connected the panel shows
    /// GitHub instead (see `shownMode`), and picks Deploys up once one is connected.
    @Published var mode: PanelMode = .deploys
    /// The Deploys side's page, filter, open cards and keyboard cursor.
    let deploys = DeployPanelState()
    /// The Local side's cursor.
    let local = LocalPanelState()
    /// Bumped each time the panel opens, so the view can take keyboard focus.
    @Published var opened = 0
    var actions = PanelActions()

    /// The next side of the panel to the right (1) or left (-1), as the arrow keys move.
    func step(_ delta: Int) {
        guard let modes = input?.availableModes, let index = modes.firstIndex(of: shownMode) else { return }
        let next = index + delta
        if modes.indices.contains(next) { mode = modes[next] }
    }

    /// The side actually on screen: `mode`, or GitHub when that side is turned off.
    var shownMode: PanelMode {
        guard let modes = input?.availableModes, modes.contains(mode) else { return .work }
        return mode
    }
}

enum PanelMode: String, CaseIterable { case work = "GitHub", deploys = "Deploys", local = "Local", ai = "AI Usage" }

/// The panel under the menu bar item: who you are, then the work waiting for you, one kind at a
/// time. The brand orange means one thing only: something you have not seen yet.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var expanded: Set<String> = []
    /// The row the arrow keys are on: an item's URL or a group's key.
    @State private var cursor: String?
    @FocusState private var focused: Bool

    private var actions: PanelActions { model.actions }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input = model.input {
                if input.isSignedOut {
                    signedOut(input.auth, refused: input.authRefused)
                } else {
                    header(input)
                    if input.availableModes.count > 1 { modeSwitch(input) }
                    if model.mode == .deploys && input.deploysEnabled {
                        DeploysPanel(monitor: DeployMonitor.shared, state: model.deploys,
                                     open: actions.openAddress, openSettings: actions.openSettings)
                    } else if model.mode == .local && input.localEnabled {
                        LocalPanel(monitor: LocalMonitor.shared, deploys: DeployMonitor.shared,
                                   state: model.local, open: actions.openAddress)
                    } else if model.mode == .ai && input.aiEnabled {
                        AIPanel(monitor: AIMonitor.shared)
                    } else {
                        if !input.errors.isEmpty || !input.notices.isEmpty { errors(input) }
                        work(input)
                    }
                    footer(input)
                }
            } else {
                Text("Loading…").font(Ink.meta).foregroundStyle(Ink.secondary).padding(20)
            }
        }
        .frame(width: 380)
        .foregroundStyle(Ink.primary)
        .background(shortcuts)
        // The panel works from the keyboard: arrows move between rows and tabs, Return opens, ⌘↩ opens the checks or conflicts.
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            if model.mode == .deploys, model.input?.deploysEnabled == true {
                return DeployKeys.handle(press, model: model, open: actions.openAddress) ? .handled : .ignored
            }
            if model.mode == .local, model.input?.localEnabled == true {
                return LocalKeys.handle(press, model: model) ? .handled : .ignored
            }
            if model.mode == .ai, model.input?.aiEnabled == true {
                guard press.key == .leftArrow || press.key == .rightArrow else { return .ignored }
                model.step(press.key == .rightArrow ? 1 : -1)
                return .handled
            }
            guard [.upArrow, .downArrow, .leftArrow, .rightArrow, .return].contains(press.key) else { return .ignored }
            return handle(press.key, command: press.modifiers.contains(.command)) ? .handled : .ignored
        }
        .onChange(of: model.opened) {
            cursor = nil
            focused = true
        }
        .onAppear { focused = true }
    }

    // MARK: keyboard

    /// A row as the arrow keys see it: items, groups, and the items of open groups, in order.
    private enum Entry {
        case item(Item)
        case group(key: String, items: [Item])

        var id: String {
            switch self {
            case .item(let item): item.url
            case .group(let key, _): key
            }
        }
    }

    private func entries(_ section: MenuSection) -> [Entry] {
        let now = model.input?.now ?? Date()
        return Self.buckets(section.rows, now: now).flatMap(\.rows).flatMap { row -> [Entry] in
            switch row {
            case .item(let item):
                return [.item(item)]
            case .group(let repository, let items):
                let key = "\(section.kind.rawValue)/\(repository)"
                return [.group(key: key, items: items)] + (expanded.contains(key) ? items.map(Entry.item) : [])
            }
        }
    }

    /// A tab's rows split by status, strongest first; a repository group goes where its most
    /// urgent item would.
    static func buckets(_ rows: [Row], now: Date) -> [(status: ItemStatus, rows: [Row])] {
        let keyed = rows.map { row in (row.items.map { $0.status(now: now) }.min() ?? .open, row) }
        return ItemStatus.allCases.compactMap { status in
            let matching = keyed.filter { $0.0 == status }.map(\.1)
            return matching.isEmpty ? nil : (status, matching)
        }
    }

    /// ⌘↩ opens the page where the selected item's problem gets fixed, like clicking its badge.
    private func handle(_ key: KeyEquivalent, command: Bool = false) -> Bool {
        guard let input = model.input, !input.isSignedOut else { return false }
        let kinds = kinds(input)
        guard let tab = current(input, kinds) else { return false }
        switch key {
        case .leftArrow, .rightArrow:
            guard let index = kinds.firstIndex(of: tab) else { return false }
            let next = index + (key == .rightArrow ? 1 : -1)
            guard kinds.indices.contains(next) else { return true }
            model.tab = kinds[next]
            cursor = nil
        case .upArrow, .downArrow:
            guard let section = section(tab, input) else { return true }
            let ids = entries(section).map(\.id)
            guard !ids.isEmpty else { return true }
            let index = cursor.flatMap(ids.firstIndex(of:))
            let next = switch (index, key == .downArrow) {
            case (nil, true): 0
            case (nil, false): ids.count - 1
            case (let i?, true): min(i + 1, ids.count - 1)
            case (let i?, false): max(i - 1, 0)
            }
            cursor = ids[next]
        case .return:
            guard let section = section(tab, input),
                  let entry = entries(section).first(where: { $0.id == cursor }) else { return true }
            switch entry {
            case .item(let item):
                if command, let page = item.problemPage { actions.openPage(item, page) }
                else { actions.open(item) }
            case .group(let key, _):
                withAnimation(.easeOut(duration: 0.18)) {
                    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                }
            }
        default:
            return false
        }
        return true
    }

    /// The menu's old key equivalents, kept for people who used them.
    private var shortcuts: some View {
        ZStack {
            Button("", action: actions.refresh).keyboardShortcut("r")
            Button("", action: actions.openSettings).keyboardShortcut(",")
            Button("", action: actions.openProfile).keyboardShortcut("o")
            Button("", action: actions.quit).keyboardShortcut("q")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: mode

    /// GitHub | Deploys, with a dot when a deployment needs a look.
    private func modeSwitch(_ input: PanelInput) -> some View {
        HStack(spacing: 4) {
            ForEach(input.availableModes, id: \.self) { mode in
                let active = model.shownMode == mode
                Button { model.mode = mode } label: {
                    HStack(spacing: 5) {
                        Text(mode.rawValue).font(active ? Ink.tabActive : Ink.tab)
                        if mode == .deploys, let state = input.deployIndicator {
                            Circle().fill(DeployText.tint(state)).frame(width: 6, height: 6)
                        }
                        if mode == .local, input.localUnpushed > 0 {
                            Text("\(input.localUnpushed)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Ink.warning)
                                .help("\(input.localUnpushed) repositories have commits that are not on GitHub")
                        }
                    }
                    .foregroundStyle(active ? Ink.primary : Ink.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(active ? Ink.raised : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
                .contextMenu { modeMenu(mode) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    @ViewBuilder private func modeMenu(_ mode: PanelMode) -> some View {
        switch mode {
        case .work:
            Button("Refresh GitHub", action: actions.refresh)
            Button("Mark Everything Read", action: actions.markAllSeen)
        case .deploys:
            Button("Refresh Deployments") { DeployMonitor.shared.refresh() }
            Button("Mark All Deployments Seen") { DeployMonitor.shared.markAllSeen() }
        case .local:
            Button("Rescan Repositories and Servers") { Task { await LocalMonitor.shared.scanNow() } }
        case .ai:
            Button("Rescan AI Logs") { Task { await AIMonitor.shared.scanNow() } }
        }
        Divider()
        Button("Settings…", action: actions.openSettings)
    }

    // MARK: header

    private func header(_ input: PanelInput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: actions.openProfile) {
                    HStack(alignment: .top, spacing: 11) {
                        ViewerAvatar(viewer: input.viewer).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(input.viewer?.displayName ?? "GitHub").font(Ink.name).lineLimit(1)
                                    .layoutPriority(1)
                                if let login = input.viewer?.login {
                                    Text(verbatim: "@\(login)").font(Ink.meta).foregroundStyle(Ink.tertiary).lineLimit(1)
                                }
                            }
                            if let social = input.social { counters(social) }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open your GitHub profile")
                .contextMenu {
                    Button("Open Your Profile", action: actions.openProfile)
                    if let login = input.viewer?.login {
                        Button("Open Your Pull Requests") { actions.openAddress("https://github.com/pulls") }
                        Button("Open Your Notifications") { actions.openAddress("https://github.com/notifications") }
                        Divider()
                        Button("Copy Profile Link") { DeployCommands.copy("https://github.com/\(login)") }
                    }
                    Divider()
                    Button("Mark Everything Read", action: actions.markAllSeen)
                    Button("Refresh", action: actions.refresh)
                    Button("Settings…", action: actions.openSettings)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    IconButton(symbol: "arrow.clockwise", help: "Refresh", spinning: input.isRefreshing, action: actions.refresh)
                    IconButton(symbol: "ellipsis", help: "More") { moreMenu(input) }
                }
                .padding(.top, 3)
            }
            // The organization filter only narrows the GitHub side.
            if !input.knownOrganizations.isEmpty && model.shownMode == .work { organizations(input) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func counters(_ social: Social) -> some View {
        let stars = counter(Self.compact(social.stars) + (social.starsAreExact ? "" : "+"), "stars")
        let followers = counter(Self.compact(social.followers), "followers")
        let following = counter(Self.compact(social.following), "following")
        // Whole counters or none: a cut-off "123…" reads worse than a missing one.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { stars; followers; following }
            HStack(spacing: 8) { stars; followers }
            stars
        }
    }

    private func counter(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: value).foregroundStyle(Ink.secondary)
            Text(label).foregroundStyle(Ink.tertiary)
        }
        .font(Ink.meta)
        .fixedSize()
    }

    private func organizations(_ input: PanelInput) -> some View {
        let selected = input.selectedOrganizations
        // No organization picked means your own repositories; picking one switches to what is
        // assigned to you there (Query.build), so the labels say that.
        let label = selected.isEmpty ? "Your repositories"
            : selected.count == 1 ? "Assigned to you in \(selected[0])" : "Assigned to you in \(selected.count) organizations"
        return Button {
            ChoiceMenu.show(
                [.action("Your repositories", checked: selected.isEmpty, actions.clearOrganizations),
                 .separator, .header("Assigned to you in")]
                    + input.knownOrganizations.sorted().map { org in
                        .action(org, checked: selected.contains(org)) { actions.toggleOrganization(org) }
                    }
            )
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "building.2").font(.system(size: 10.5))
                Text(label).font(Ink.meta)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Ink.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func moreMenu(_ input: PanelInput) {
        let unseen = input.sections.reduce(0) { $0 + $1.unseenCount(input.isSeen) }
        var entries: [ChoiceMenu.Entry] = [
            .action("Open GitHub", actions.openProfile),
            .action("Settings…", actions.openSettings),
        ]
        if unseen > 0 { entries += [.separator, .action("Mark all as seen", actions.markAllSeen)] }
        entries += [.separator, .action("Quit Dev+ Bar", actions.quit)]
        ChoiceMenu.show(entries)
    }

    // MARK: errors

    private func errors(_ input: PanelInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(input.errors, id: \.menuText) { error in
                Label(error.menuText, systemImage: "exclamationmark.triangle.fill")
                    .font(Ink.meta)
                    .foregroundStyle(Ink.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only a failed refresh leaves older data on screen; say how old.
            if !input.errors.isEmpty, let last = input.lastRefresh {
                Text("Showing what was there \(Self.when(last, now: input.now)).")
                    .font(Ink.meta).foregroundStyle(Ink.tertiary)
            }
            ForEach(input.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(Ink.meta)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    /// "at 14:32" today, "on 12 Oct at 14:32" before.
    private static func when(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? "at \(clock.string(from: date))"
            : "on \(day.string(from: date)) at \(clock.string(from: date))"
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()

    /// 2,611 stays as it is; 12,345 becomes 12.3k, so the header never outgrows the panel.
    static func compact(_ value: Int) -> String {
        value < 10_000 ? Formatting.grouped(value) : String(format: "%.1fk", Double(value) / 1000)
    }

    // MARK: work

    private func kinds(_ input: PanelInput) -> [SectionKind] {
        SectionKind.displayOrder.filter { kind in
            input.showEmptySections
                ? input.visibleSections.contains(kind)
                : input.sections.contains { $0.kind == kind && !$0.isEmpty }
        }
    }

    /// The open tab: the one picked, else the first with something unseen, else the first.
    private func current(_ input: PanelInput, _ kinds: [SectionKind]) -> SectionKind? {
        if let tab = model.tab, kinds.contains(tab) { return tab }
        return kinds.first { kind in section(kind, input).map { $0.unseenCount(input.isSeen) > 0 } ?? false }
            ?? kinds.first
    }

    private func section(_ kind: SectionKind, _ input: PanelInput) -> MenuSection? {
        input.sections.first { $0.kind == kind }
    }

    @ViewBuilder private func work(_ input: PanelInput) -> some View {
        let kinds = kinds(input)
        if let tab = current(input, kinds) {
            tabs(input, kinds, current: tab)
            Rectangle().fill(Ink.hairline).frame(height: 1)
            list(input, section(tab, input))
        } else if input.errors.isEmpty {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            empty(input)
        }
    }

    private func tabs(_ input: PanelInput, _ kinds: [SectionKind], current: SectionKind) -> some View {
        ViewThatFits(in: .horizontal) {
            tabRow(input, kinds, current: current, short: false, counts: true)
            tabRow(input, kinds, current: current, short: true, counts: true)
            tabRow(input, kinds, current: current, short: true, counts: false)
        }
        .padding(.horizontal, 18)
    }

    private func tabRow(_ input: PanelInput, _ kinds: [SectionKind], current: SectionKind,
                        short: Bool, counts: Bool) -> some View {
        HStack(spacing: counts ? 18 : 14) {
            ForEach(kinds, id: \.self) { kind in
                let section = section(kind, input)
                let unseen = section?.unseenCount(input.isSeen) ?? 0
                let active = kind == current
                Button { model.tab = kind } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text(kind.tabTitle(short: short))
                                .font(active ? Ink.tabActive : Ink.tab)
                                .foregroundStyle(active ? Ink.primary : Ink.secondary)
                            // Green counts what is new; grey counts everything when nothing is.
                            if counts, let total = section?.items.count, total > 0 {
                                Text(verbatim: "\(unseen > 0 ? unseen : total)")
                                    .font(Ink.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(unseen > 0 ? Ink.accent : Ink.tertiary)
                            } else if !counts, unseen > 0 {
                                Circle().fill(Ink.accent).frame(width: 5, height: 5)
                            }
                        }
                        Capsule().fill(active ? Ink.primary : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title)
                .accessibilityValue("\(section?.items.count ?? 0) items, \(unseen) unseen")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func list(_ input: PanelInput, _ section: MenuSection?) -> some View {
        if let section, !section.isEmpty {
            ScrollViewReader { scroller in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let buckets = Self.buckets(section.rows, now: input.now)
                    ForEach(buckets, id: \.status) { bucket in
                        // One group needs no heading; the tab already names it.
                        if buckets.count > 1 {
                            BucketHeader(status: bucket.status, count: bucket.rows.reduce(0) { $0 + $1.items.count })
                        }
                        ForEach(bucket.rows, id: \.self) { row in
                            rowView(row, section: section, input: input)
                        }
                    }
                    if section.truncated {
                        Text("Showing the first 100. Narrow the filters in Settings to see the rest.")
                            .font(Ink.meta).foregroundStyle(Ink.tertiary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 372)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: cursor) {
                if let cursor { withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(cursor) } }
            }
            }
        } else {
            Text("Nothing here right now.")
                .font(Ink.body).foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
        }
    }

    @ViewBuilder private func rowView(_ row: Row, section: MenuSection, input: PanelInput) -> some View {
        switch row {
        case .item(let item):
            ItemRow(item: item, input: input, selected: cursor == item.url, open: actions.open, openPage: actions.openPage)
                .contextMenu { itemMenu(item, input) }
                .id(item.url)
        case .group(let repository, let items):
            let key = "\(section.kind.rawValue)/\(repository)"
            GroupRow(repository: repository, items: items, input: input,
                     expanded: expanded.contains(key), selected: cursor == key) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if expanded.contains(key) { expanded.remove(key) }
                    else { expanded.insert(key) }
                }
            }
            .contextMenu { groupMenu(repository, items, expanded: expanded.contains(key), toggle: key) }
            .id(key)
            if expanded.contains(key) {
                ForEach(items) { item in
                    ItemRow(item: item, input: input, selected: cursor == item.url, open: actions.open, openPage: actions.openPage)
                        .contextMenu { itemMenu(item, input) }
                        .padding(.leading, 20)
                        .id(item.url)
                }
            }
        }
    }

    // MARK: right-click menus

    @ViewBuilder private func itemMenu(_ item: Item, _ input: PanelInput) -> some View {
        Button(item.kind == .issue ? "Open Issue" : "Open Pull Request") { actions.open(item) }
        if let page = item.problemPage {
            Button(item.merge == .conflicts ? "Open Conflicts" : "Open Checks") { actions.openPage(item, page) }
        }
        if item.kind != .issue {
            Button("Open Files Changed") { actions.openPage(item, item.url + "/files") }
        }
        if let d = input.deploymentFor(item), let site = d.url {
            Button("Open Preview Deployment") { actions.openAddress(site.absoluteString) }
        }
        Button("Open Repository") { actions.openAddress("https://github.com/\(item.repository)") }
        Button("Open @\(item.authorLogin)'s Profile") { actions.openAddress("https://github.com/\(item.authorLogin)") }
        Divider()
        Button("Copy Link") { DeployCommands.copy(item.url) }
        Button("Copy as Markdown") { DeployCommands.copy("[\(item.repositoryName)#\(item.number): \(item.title)](\(item.url))") }
        Button("Copy Reference (\(item.repository)#\(item.number))") { DeployCommands.copy("\(item.repository)#\(item.number)") }
        if item.kind != .issue {
            Button("Copy Checkout Command") { DeployCommands.copy("gh pr checkout \(item.number) -R \(item.repository)") }
        }
        Divider()
        if !input.isSeen(item.url) { Button("Mark as Read") { actions.markSeen([item.url]) } }
        Button("Stop Watching \(item.repository)…") { actions.hideRepository(item.repository) }
    }

    @ViewBuilder private func groupMenu(_ repository: String, _ items: [Item], expanded: Bool, toggle key: String) -> some View {
        Button(expanded ? "Collapse" : "Expand") {
            withAnimation(.easeOut(duration: 0.18)) {
                if self.expanded.contains(key) { self.expanded.remove(key) } else { self.expanded.insert(key) }
            }
        }
        Divider()
        Button("Open Repository") { actions.openAddress("https://github.com/\(repository)") }
        Button("Open Pull Requests") { actions.openAddress("https://github.com/\(repository)/pulls") }
        Button("Open Issues") { actions.openAddress("https://github.com/\(repository)/issues") }
        Button("Open Actions") { actions.openAddress("https://github.com/\(repository)/actions") }
        Divider()
        Button("Copy Name") { DeployCommands.copy(repository) }
        Button("Copy All Links") { DeployCommands.copy(items.map(\.url).joined(separator: "\n")) }
        Divider()
        Button("Mark All \(items.count) as Read") { actions.markSeen(items.map(\.url)) }
        Button("Stop Watching \(repository)…") { actions.hideRepository(repository) }
    }

    private func empty(_ input: PanelInput) -> some View {
        let (title, detail): (String, String) = {
            if input.visibleSections.isEmpty {
                return ("All tabs are turned off", "Choose which tabs to show in Settings.")
            }
            if !input.selectedOrganizations.isEmpty {
                return ("Nothing assigned to you there",
                        "Pull requests and issues assigned to you in these organizations show up here.")
            }
            if input.repositoryFilterActive {
                return input.repositoryFilterIsAllowList
                    ? ("Nothing waiting in the watched repositories",
                       "Change which repositories Dev+ Bar watches in Settings.")
                    : ("You're all caught up",
                       "Some repositories are hidden; manage them in Settings.")
            }
            return ("You're all caught up",
                    "New pull requests and issues on your repositories, and issues assigned to you, will show up here.")
        }()
        return VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light)).foregroundStyle(Ink.tertiary)
                .padding(.bottom, 4)
            Text(title).font(Ink.body.weight(.medium))
            Text(detail).font(Ink.meta).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            if !input.selectedOrganizations.isEmpty {
                Button("Show all organizations", action: actions.clearOrganizations).buttonStyle(QuietButtonStyle())
                    .padding(.top, 8)
            } else if input.repositoryFilterActive || input.visibleSections.isEmpty {
                Button("Open Settings", action: actions.openSettings).buttonStyle(QuietButtonStyle())
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 34)
    }

    // MARK: footer

    private func footer(_ input: PanelInput) -> some View {
        let kinds = kinds(input)
        let tab = current(input, kinds)
        let unseen = tab.flatMap { section($0, input) }?.unseenCount(input.isSeen) ?? 0
        return VStack(spacing: 0) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            HStack {
                if let tab, unseen > 0 {
                    Button("Mark these as seen") {
                        // Pin the tab first: otherwise the next tab with unseen items takes its
                        // place and the same button would clear that one too.
                        model.tab = tab
                        actions.markSectionSeen(tab)
                    }
                        .buttonStyle(.plain)
                        .font(Ink.meta)
                        .foregroundStyle(Ink.secondary)
                }
                Spacer()
                Text(status(input)).font(Ink.meta).foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(height: 38)
        }
    }

    private func status(_ input: PanelInput) -> String {
        if let limit = input.rateLimit, input.rateLimitVisibility.shows(limit) {
            return "\(Formatting.grouped(limit.remaining)) API calls left"
        }
        if input.isRefreshing { return "Refreshing" }
        guard let last = input.lastRefresh else { return "" }
        return "Updated \(Self.clock.string(from: last))"
    }

    // MARK: signed out

    private func signedOut(_ auth: AuthState, refused: Bool) -> some View {
        let (title, detail, button): (String, String, String) = {
            switch auth {
            case .expired(.githubCLI):
                return (refused ? "GitHub refused the GitHub CLI's token" : "The GitHub CLI is signed out",
                        auth.expiryMessage(refused: refused), "Sign in with GitHub")
            case .expired:
                return ("Sign in again", auth.expiryMessage(refused: refused), "Sign in again")
            default:
                return ("Sign in to GitHub",
                        "Dev+ Bar shows the pull requests and issues people open on your repositories.", "Sign in")
            }
        }()
        return VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                .padding(.bottom, 6)
            Text(title).font(Ink.name)
            Text(detail)
                .font(Ink.meta).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: actions.signIn).buttonStyle(QuietButtonStyle(prominent: true))
                .padding(.top, 10)
            HStack(spacing: 14) {
                Button("Settings", action: actions.openSettings)
                Button("Quit", action: actions.quit)
            }
            .buttonStyle(.plain)
            .font(Ink.meta)
            .foregroundStyle(Ink.tertiary)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - rows

/// One pull request or issue: what it is, where, its state, and how long since anything happened.
/// Your own work shows its state where the avatar would be: your face on every row says nothing.
struct ItemRow: View {
    let item: Item
    let input: PanelInput
    var selected = false
    let open: (Item) -> Void
    var openPage: (Item, String) -> Void = { _, _ in }
    @State private var hover = false

    private var isMine: Bool { item.authorLogin == input.viewer?.login }

    var body: some View {
        let seen = input.isSeen(item.url)
        let status = item.status(now: input.now)
        Button { open(item) } label: {
            HStack(alignment: .top, spacing: 11) {
                leading(status)
                    .frame(width: 28, height: 28)
                    .opacity(seen ? 0.65 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(seen ? Ink.body : Ink.body.weight(.medium))
                            .foregroundStyle(seen ? Ink.secondary : Ink.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text(verbatim: Formatting.age(of: item.lastActivity, now: input.now))
                            .font(Ink.meta).monospacedDigit().foregroundStyle(Ink.tertiary)
                            .help("Last activity")
                    }
                    meta
                }
                Circle().fill(seen ? Color.clear : Ink.accent).frame(width: 6, height: 6).padding(.top, 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover || selected ? Ink.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.title)
        .accessibilityLabel([
            "\(item.repositoryName) number \(item.number)",
            item.kind == .issue ? "issue" : (item.isDraft ? "draft pull request" : "pull request"),
            item.title,
            isMine ? "yours" : "by \(item.authorLogin)",
            status.title,
            item.merge?.help ?? "",
            Formatting.spokenAge(of: item.lastActivity, now: input.now),
            seen ? "read" : "unread",
            item.problemPage == nil ? "" : "Command-Return opens \(item.merge == .conflicts ? "the conflicts" : "the checks")",
        ].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// Your own repositories by name; anyone else's as owner/name, so a PR to someone else's
    /// project says whose it is.
    private var repositoryLabel: String {
        let owner = item.repository.split(separator: "/").first.map(String.init)
        return input.showOwner || owner != input.viewer?.login ? item.repository : item.repositoryName
    }

    @ViewBuilder private func leading(_ status: ItemStatus) -> some View {
        if isMine {
            Circle().fill(status.tint.opacity(0.16))
                .overlay(Image(systemName: item.kind.symbol(draft: item.isDraft))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(status.tint))
        } else {
            AuthorAvatar(login: item.authorLogin, isBot: item.authorIsBot)
        }
    }

    /// repo #12 · author · checks · comments
    private var meta: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "book.closed").font(.system(size: 9.5, weight: .medium))
                Text(verbatim: repositoryLabel)
                    .fontWeight(.medium)
                    .foregroundStyle(Ink.primary.opacity(0.78))
                    .truncationMode(.middle)
                Text(verbatim: "#\(item.number)").fixedSize()
            }
            .foregroundStyle(Ink.secondary)
            .help(item.repository)
            .layoutPriority(1)
            if !isMine {
                Text(verbatim: item.authorLogin).foregroundStyle(Ink.tertiary).truncationMode(.tail)
            }
            // Each badge opens the GitHub page where its problem gets fixed.
            if let merge = item.merge {
                Badge(help: merge.help + " (click to open \(merge.pageName))") {
                    openPage(item, item.url + merge.path)
                } label: {
                    Text(merge.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(merge.tint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(merge.tint.opacity(0.14)))
                }
            }
            if let checks = item.checks {
                Badge(help: checks.help + " (click to open the checks)") {
                    openPage(item, item.url + "/checks")
                } label: {
                    Image(systemName: checks.symbol).foregroundStyle(checks.tint)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 2)
                }
            }
            if let deploy = input.deploymentFor(item) {
                Badge(help: "\(deploy.provider.title) \(deploy.target.title.lowercased()) deployment \(deploy.state.title.lowercased()) (click to open)") {
                    openPage(item, (deploy.url ?? deploy.dashboardURL)?.absoluteString ?? item.url)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: DeployText.providerSymbol(deploy.provider)).font(.system(size: 7))
                        Text(deploy.target.isProduction ? "prod" : "preview")
                        Image(systemName: DeployText.symbol(deploy.state)).font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DeployText.tint(deploy.state))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(DeployText.tint(deploy.state).opacity(0.14)))
                }
            }
            if item.comments > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left").font(.system(size: 9.5))
                    Text(verbatim: "\(item.comments)").monospacedDigit()
                }
                .foregroundStyle(Ink.tertiary)
                .fixedSize()
            }
        }
        .font(Ink.meta)
        .lineLimit(1)
    }
}

extension Item {
    /// The page to open from a notification about `event`.
    func problemPage(for event: PREvent) -> String? {
        switch event {
        case .became(.conflicts): url + "/conflicts"
        case .became(.failing): url + "/checks"
        default: nil
        }
    }

    /// Where the row's most pressing badge leads: conflicts first, then checks. Nil when the
    /// pull request page itself is the right place.
    var problemPage: String? {
        if merge == .conflicts { return url + "/conflicts" }
        if checks != nil { return url + "/checks" }
        return nil
    }
}

/// A clickable badge inside a row: brightens on hover, and its click goes to its own page
/// rather than the row's.
struct Badge<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .brightness(hover ? 0.15 : 0)
                .background(Capsule().fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The heading over one status group in a tab.
struct BucketHeader: View {
    let status: ItemStatus
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.tint).frame(width: 6, height: 6)
            Text(status.title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Ink.secondary)
            Text(verbatim: "\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Ink.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Several items from one repository folded into a row that opens in place.
struct GroupRow: View {
    let repository: String
    let items: [Item]
    let input: PanelInput
    let expanded: Bool
    var selected = false
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        let unseen = items.contains { !input.isSeen($0.url) }
        let name = input.showOwner ? repository : (repository.split(separator: "/").last.map(String.init) ?? repository)
        Button(action: toggle) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Ink.raised)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Ink.secondary))
                Text(verbatim: name).font(unseen ? Ink.body.weight(.medium) : Ink.body)
                    .foregroundStyle(unseen ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                Text(verbatim: "\(items.count)").font(Ink.meta).monospacedDigit()
                    .foregroundStyle(unseen ? Ink.accent : Ink.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover || selected ? Ink.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(name), \(items.count) items, \(expanded ? "expanded" : "collapsed")")
    }
}

// MARK: - pieces

enum Ink {
    /// A graphite panel under the orange of the app icon.
    static let panel = Color(red: 0.090, green: 0.098, blue: 0.118)
    static let raised = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.07)
    static let primary = Color(red: 0.925, green: 0.933, blue: 0.945)
    static let secondary = Color(red: 0.569, green: 0.596, blue: 0.631)
    /// 5.3:1 on the panel, 4.6:1 on a hovered row: WCAG AA for small text.
    static let tertiary = Color(red: 0.530, green: 0.550, blue: 0.590)
    /// Dev+ Bar orange, #FC4206: unseen work.
    static let accent = Color(red: 0.988, green: 0.259, blue: 0.024)
    static let green = Color(red: 0.200, green: 0.761, blue: 0.369)
    static let red = Color(red: 0.96, green: 0.36, blue: 0.36)
    static let purple = Color(red: 0.66, green: 0.52, blue: 0.98)
    static let warning = Color(red: 0.95, green: 0.66, blue: 0.27)

    static let name = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let meta = Font.system(size: 11.5)
    static let tab = Font.system(size: 12.5)
    static let tabActive = Font.system(size: 12.5, weight: .semibold)
}

struct IconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // Driven by the clock rather than a repeating animation, which keeps running
            // (or winds backwards) after `spinning` turns false.
            TimelineView(.animation(paused: !spinning)) { context in
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hover ? Ink.primary : Ink.secondary)
                    .rotationEffect(.degrees(spinning ? Self.angle(at: context.date) : 0))
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(hover ? Ink.raised : .clear))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }

    /// One turn every 0.9 seconds.
    private static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Ink.meta.weight(.medium))
            .foregroundStyle(prominent ? Color.white : Ink.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(prominent ? Ink.accent : Ink.raised))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ViewerAvatar: View {
    let viewer: Viewer?

    var body: some View {
        if let image = Avatar.cached(size: 68) {
            Image(nsImage: image).resizable()
        } else if let login = viewer?.login {
            AuthorAvatar(login: login, isBot: false)
        } else {
            InitialAvatar(name: "?")
        }
    }
}

/// The author's GitHub picture once loaded; a lettered circle until then, and for bots.
struct AuthorAvatar: View {
    let login: String
    let isBot: Bool
    @ObservedObject private var store = AuthorAvatars.shared

    var body: some View {
        Group {
            if !isBot, let image = store.image(login) {
                Image(nsImage: image).resizable().clipShape(Circle())
            } else {
                InitialAvatar(name: login, square: isBot)
            }
        }
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1).opacity(isBot ? 0 : 1))
    }
}

struct InitialAvatar: View {
    let name: String
    var square = false

    var body: some View {
        let hue = Double(abs(name.lowercased().hashValueStable) % 360) / 360
        let shape = square ? AnyShape(RoundedRectangle(cornerRadius: 7, style: .continuous)) : AnyShape(Circle())
        shape
            .fill(Color(hue: hue, saturation: 0.32, brightness: 0.42))
            .overlay(
                Text(verbatim: String(name.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
            )
    }
}

private extension String {
    /// Same number on every run, unlike `hashValue`, so a person keeps their colour.
    var hashValueStable: Int {
        unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
    }
}

extension SectionKind {
    func tabTitle(short: Bool) -> String {
        switch self {
        case .changesRequested: "Changes"
        case .reviewRequested: short ? "Review" : "To review"
        case .pullRequests: short ? "PRs" : "Pull requests"
        case .issues: "Issues"
        case .myPullRequests: short ? "Mine" : "My PRs"
        case .mentions: "Mentions"
        }
    }
}

extension ItemKind {
    func symbol(draft: Bool) -> String {
        switch self {
        case .issue: "smallcircle.filled.circle"
        case .pullRequest: draft ? "circle.dashed" : "arrow.triangle.pull"
        }
    }
}

extension ItemStatus {
    var tint: Color {
        switch self {
        case .changesRequested: Ink.warning
        case .conflicts, .failing: Ink.red
        case .approved: Ink.green
        case .open: Ink.purple
        case .draft, .stale: Ink.secondary
        }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .passing: "checkmark"
        case .failing: "xmark"
        case .pending: "circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .passing: Ink.green
        case .failing: Ink.red
        case .pending: Ink.warning
        }
    }
    var help: String {
        switch self {
        case .passing: "Checks passed"
        case .failing: "Checks failing"
        case .pending: "Checks running"
        }
    }
}

extension MergeBlock {
    var label: String {
        switch self {
        case .conflicts: "Conflicts"
        case .behind: "Behind"
        }
    }
    var tint: Color {
        switch self {
        case .conflicts: Ink.red
        case .behind: Ink.warning
        }
    }
    /// GitHub's web conflict editor. Behind has no page of its own: the "Update branch"
    /// button sits in the merge box at the foot of the pull request.
    var path: String {
        switch self {
        case .conflicts: "/conflicts"
        case .behind: ""
        }
    }
    var pageName: String {
        switch self {
        case .conflicts: "the conflict editor"
        case .behind: "the pull request"
        }
    }
    var help: String {
        switch self {
        case .conflicts: "Has merge conflicts with the base branch"
        case .behind: "Out of date with the base branch"
        }
    }
}
