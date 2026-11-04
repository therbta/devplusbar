import AppKit
import Charts
import SwiftUI
import Defaults

/// What the Deploys side shows, kept on the panel model so the keyboard can drive it.
@MainActor
final class DeployPanelState: ObservableObject {
    enum Page: String, CaseIterable { case activity = "Activity", insights = "Insights" }
    @Published var page = Page.activity
    @Published var filter: DeployProvider?
    @Published var expanded: Set<String> = []
    /// The card the arrow keys are on.
    @Published var cursor: String?
    /// Brief "Copied" feedback, by deployment id.
    @Published var flash: [String: String] = [:]

    func shown(_ monitor: DeployMonitor) -> [Deployment] {
        monitor.deployments.filter { filter == nil || $0.provider == filter }
    }

    func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func say(_ text: String, on id: String) {
        flash[id] = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if self.flash[id] == text { self.flash[id] = nil }
        }
    }
}

/// The "Deploys" side of the panel: activity cards, or charts.
struct DeploysPanel: View {
    @ObservedObject var monitor: DeployMonitor
    @ObservedObject var state: DeployPanelState
    var open: (String) -> Void
    var openSettings: () -> Void
    /// Observed so pinning from a menu redraws the strip.
    @Default(.deployPinnedProjects) private var pinnedProjects
    @ObservedObject private var workflows = WorkflowMonitor.shared

    private var shown: [Deployment] { state.shown(monitor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One row: what production runs now, then charts and the provider filter as icons.
            // Mark seen and the rest are in the right-click menus.
            HStack(spacing: 4) {
                productionStrip(shown)
                Spacer(minLength: 0)
                IconButton(symbol: state.page == .insights ? "chart.bar.fill" : "chart.bar",
                           help: state.page == .insights ? "Back to activity (⇥)" : "Charts (⇥)") {
                    state.page = state.page == .insights ? .activity : .insights
                }
                if monitor.connected.count > 1 {
                    Menu {
                        Picker("Show", selection: $state.filter) {
                            Text("All providers").tag(DeployProvider?.none)
                            ForEach(DeployProvider.allCases, id: \.self) { Text($0.title).tag(DeployProvider?.some($0)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: state.filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(state.filter == nil ? Ink.secondary : Ink.primary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(state.filter.map { "Showing \($0.title) only" } ?? "Filter by provider")
                }
            }
            .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 6)

            ForEach(monitor.errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { _, message in
                Text(message).font(Ink.meta).foregroundStyle(Ink.warning)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
            Rectangle().fill(Ink.hairline).frame(height: 1)

            if monitor.connected.isEmpty {
                connectPrompt
            } else if state.page == .activity {
                activity
            } else {
                DeployInsights(history: monitor.history.filter { state.filter == nil || $0.provider == state.filter })
            }
        }
    }

    private var connectPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 26)).foregroundStyle(Ink.secondary)
            Text("Connect Vercel or Heroku to follow your deployments here.")
                .font(Ink.body).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
            Button("Open Settings", action: openSettings)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 24)
    }

    // MARK: activity

    @ViewBuilder private var activity: some View {
        let list = shown
        NeverPassedStrip(workflows: workflows, expanded: state.expanded.contains(NeverPassedStrip.id),
                         toggle: { state.toggle(NeverPassedStrip.id) }, open: open)
        if list.isEmpty {
            Text(monitor.isRefreshing ? "Loading deployments…" : "No deployments yet.")
                .font(Ink.body).foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 36)
        } else {
            ciFailures
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(list) { d in
                            if let day = Self.dayHeader(for: d, in: list) {
                                Text(day.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Ink.tertiary)
                                    .padding(.horizontal, 10).padding(.top, d.id == list.first?.id ? 0 : 8).padding(.bottom, 1)
                            }
                            DeployCard(deployment: d, seen: monitor.seen.contains(d.id),
                                       expanded: state.expanded.contains(d.id),
                                       selected: state.cursor == d.id,
                                       flash: state.flash[d.id],
                                       toggle: { state.cursor = d.id; state.toggle(d.id) },
                                       open: { address in monitor.markSeen([d.id]); open(address) },
                                       copyPrompt: { DeployCommands.copyPrompt(d, state: state, monitor: monitor) },
                                       monitor: monitor)
                            .id(d.id)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 372)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.cursor) {
                    if let cursor = state.cursor { withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(cursor) } }
                }
            }
        }
    }

    /// A red workflow on a production branch, one row each; opening one shows its failed step.
    @ViewBuilder private var ciFailures: some View {
        let rows = monitor.ci.values.sorted { $0.repository < $1.repository }
            .flatMap { status in status.ordered().map { (status, $0) } }
            .sorted { a, b in
                // Fresh breaks before workflows left red, across projects too.
                let sa = a.0.streaks[a.1.id]?.isStuck() ?? false, sb = b.0.streaks[b.1.id]?.isStuck() ?? false
                return sa != sb ? !sa : a.1.createdAt > b.1.createdAt
            }
        let fresh = rows.filter { !($0.0.streaks[$0.1.id]?.isStuck() ?? false) }
        // Workflows left red for days are not news: they show only on their project's pill.
        if !fresh.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fresh.prefix(3), id: \.1.id) { status, run in
                    CIFailureRow(run: run, status: status, monitor: monitor,
                                 expanded: state.expanded.contains("ci:\(run.id)"),
                                 flash: state.flash["ci:\(run.id)"],
                                 toggle: { state.toggle("ci:\(run.id)") },
                                 copy: {
                                     state.say("Copying…", on: "ci:\(run.id)")
                                     Task { @MainActor in
                                         await monitor.copyCIPrompt(run, status: status)
                                         state.say("Copied for Claude", on: "ci:\(run.id)")
                                     }
                                 },
                                 open: open)
                }
            }
            .padding(.horizontal, 8).padding(.top, 8)
        }
    }

    /// "Today", "Yesterday", "Mon Oct 30" above the first card of each day.
    static func dayHeader(for d: Deployment, in list: [Deployment], now: Date = Date()) -> String? {
        let calendar = Calendar.current
        guard let index = list.firstIndex(where: { $0.id == d.id }) else { return nil }
        if index > 0, calendar.isDate(list[index - 1].createdAt, inSameDayAs: d.createdAt) { return nil }
        if calendar.isDateInToday(d.createdAt) { return "Today" }
        if calendar.isDateInYesterday(d.createdAt) { return "Yesterday" }
        return d.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// The shortcuts, quietly, so they can be learned without a manual.
    private var keyHints: some View {
        Text("↩ open · ⌘↩ logs · ⌘⇧C copy for Claude · ⇥ charts · right-click: more")
            .font(.system(size: 10)).foregroundStyle(Ink.tertiary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.bottom, 6)
    }

    static func ciHelp(_ checks: CIStatus) -> String {
        guard checks.isFailing else { return "\n" + checks.summary }
        return "\nRed on \(checks.branch) (right-click to open):" + checks.ordered().map { run in
            "\n• \(run.workflow)" + (checks.streaks[run.id].map { " — \($0.text())" } ?? "")
        }.joined()
    }

    static func stripHelp(_ d: Deployment, _ waiting: PendingCommits?) -> String {
        var text = "\(d.project): production \(DeployText.status(d).lowercased())"
        if let waiting {
            text += "\n\(waiting.count) commit\(waiting.count == 1 ? "" : "s") on \(waiting.branch) not deployed yet (click to compare):"
            text += waiting.subjects.map { "\n• \($0)" }.joined()
            if waiting.count > waiting.subjects.count { text += "\n…" }
        }
        return text
    }

    /// The current production state of each project: pinned ones, else the four most recent.
    @ViewBuilder private func productionStrip(_ list: [Deployment]) -> some View {
        let pinned = pinnedProjects
        var latest: [String: Deployment] = [:]
        let _ = list.filter { $0.target.isProduction && $0.releaseKind?.isConfig != true }.forEach { d in
            let key = "\(d.provider.rawValue):\(d.project)"
            if latest[key] == nil { latest[key] = d }
        }
        let keys = pinned.isEmpty
            ? latest.values.sorted { $0.createdAt > $1.createdAt }.prefix(4).map { "\($0.provider.rawValue):\($0.project)" }
            : pinned.filter { latest[$0] != nil }
        if !keys.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        if let d = latest[key] {
                            let waiting = monitor.pending[key].flatMap { $0.count > 0 ? $0 : nil }
                            let checks = monitor.ci[key]
                            Button {
                                open((waiting?.compareURL ?? d.url ?? d.dashboardURL)?.absoluteString ?? "")
                            } label: {
                                HStack(spacing: 5) {
                                    if d.isCrashed {
                                        Circle().fill(Ink.red).frame(width: 7, height: 7)
                                    } else {
                                        StateDot(state: d.state, size: 7)
                                    }
                                    Text(d.project).font(Ink.meta).foregroundStyle(Ink.primary)
                                    if let waiting {
                                        Text("\(waiting.count) waiting")
                                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                            .foregroundStyle(Ink.warning)
                                    }
                                    if let checks, checks.isFailing {
                                        Text("CI ✗")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(checks.hasFreshBreak ? Ink.red : Ink.warning)
                                    }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(waiting == nil ? Ink.raised : Ink.warning.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .help(Self.stripHelp(d, waiting) + (checks.map(Self.ciHelp) ?? ""))
                            .contextMenu {
                                if let site = d.url { Button("Open Site") { open(site.absoluteString) } }
                                if let logs = d.dashboardURL { Button("Open in \(d.provider.title)") { open(logs.absoluteString) } }
                                if let compare = waiting?.compareURL { Button("Compare \(waiting?.count ?? 0) Waiting Commits") { open(compare.absoluteString) } }
                                if let checks, checks.isFailing {
                                    Section("Red on \(checks.branch)") {
                                        ForEach(checks.ordered()) { run in
                                            Button("\(run.workflow) — \(checks.streaks[run.id].map { $0.neverPassed ? "never passed" : "red \($0.short())" } ?? "failed")") {
                                                open(run.url?.absoluteString ?? "")
                                            }
                                        }
                                    }
                                }
                                if let checks {
                                    Button("Open Actions on \(checks.branch)") {
                                        open("https://github.com/\(checks.repository)/actions?query=branch%3A\(checks.branch)")
                                    }
                                    Button("Open Repository") { open("https://github.com/\(checks.repository)") }
                                }
                                Divider()
                                if let site = d.url { Button("Copy URL") { DeployCommands.copy(site.absoluteString) } }
                                if let waiting, !waiting.subjects.isEmpty {
                                    Button("Copy Waiting Commits") { DeployCommands.copy(waiting.subjects.map { "- \($0)" }.joined(separator: "\n")) }
                                }
                                Divider()
                                DeployProjectMenu(key: key, project: d.project)
                            }
                        }
                    }
                }
            }
            .help("Production of each project: green is live, red failed, orange building")
        }
    }
}

/// Workflows on your repositories that have failed every run GitHub still returns, folded into
/// one line; opened, each with a Disable button. A rerun cannot fix one that never passed.
struct NeverPassedStrip: View {
    static let id = "never-passed"
    @ObservedObject var workflows: WorkflowMonitor
    let expanded: Bool
    let toggle: () -> Void
    let open: (String) -> Void

    var body: some View {
        let list = workflows.neverPassed
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                            .font(.system(size: 12)).foregroundStyle(Ink.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(list.count) workflow\(list.count == 1 ? "" : "s") never passed").font(Ink.body)
                            Text("\(list.reduce(0) { $0 + $1.failures })+ failed runs, not one green")
                                .font(Ink.meta).foregroundStyle(Ink.secondary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Every run GitHub still returns for these failed. Disabling one stops it on GitHub until you enable it again.")
                if expanded {
                    ForEach(list) { w in row(w) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.warning.opacity(0.06)))
            .padding(.horizontal, 8).padding(.top, 8)
        }
    }

    private func row(_ w: NeverPassedWorkflow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(w.repositoryName) · \(w.workflow)").font(Ink.meta).foregroundStyle(Ink.primary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(w.failures)+ failed · since \(w.since.formatted(.dateTime.month(.abbreviated).day())) · \(w.event)")
                    .font(.system(size: 10)).foregroundStyle(Ink.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Disable…") { Self.confirmDisable(w, workflows) }
                .buttonStyle(.link).font(Ink.meta)
        }
        .padding(.leading, 20)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open Latest Run") { open(w.latest.url?.absoluteString ?? "https://github.com/\(w.repository)/actions") }
            Button("Open Actions") { open("https://github.com/\(w.repository)/actions") }
            Divider()
            Button("Disable Workflow…") { Self.confirmDisable(w, workflows) }
        }
    }

    static func confirmDisable(_ w: NeverPassedWorkflow, _ workflows: WorkflowMonitor) {
        DeployCommands.confirm(
            "Disable “\(w.workflow)” in \(w.repository)?",
            "All \(w.failures) runs GitHub still returns failed, the first on "
                + "\(w.since.formatted(date: .abbreviated, time: .omitted)). GitHub stops running it, on schedule and "
                + "on push, until you enable it again from the repository's Actions tab.") {
            try await workflows.disable(w)
        }
    }
}

/// One failing workflow: what failed and when; opened, the failed step's last lines.
struct CIFailureRow: View {
    let run: CIRun
    let status: CIStatus
    @ObservedObject var monitor: DeployMonitor
    let expanded: Bool
    let flash: String?
    let toggle: () -> Void
    let copy: () -> Void
    let open: (String) -> Void

    var body: some View {
        let streak = status.streaks[run.id]
        let stuck = streak?.isStuck() ?? false
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: stuck ? "exclamationmark.octagon" : "xmark.octagon.fill")
                        .font(.system(size: 12)).foregroundStyle(stuck ? Ink.warning : Ink.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.workflow).font(Ink.body).lineLimit(1).truncationMode(.middle)
                        Text(([status.repository.split(separator: "/").last.map(String.init) ?? status.repository, status.branch]
                              + [stuck ? streak.map { "\($0.failures)\($0.atLeast ? "+" : "") failed runs" } : "failed \(run.createdAt.formatted(.relative(presentation: .named)))"].compactMap { $0 })
                            .joined(separator: " · "))
                            .font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let flash {
                        Text(flash).font(Ink.meta).foregroundStyle(Ink.green)
                    } else if stuck, let streak {
                        Text("red \(streak.short())").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Ink.warning).fixedSize()
                    } else {
                        Text("NEW").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Ink.red)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Ink.red.opacity(0.18))).fixedSize()
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("GitHub Actions on \(status.branch): \(status.summary)"
                  + (streak.map { "\n\(run.workflow): \($0.text())" } ?? ""))
            if expanded {
                let log = monitor.ciLogs[run.id]
                if let log {
                    if let step = log.step {
                        Text("Step: \(step)").font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(2)
                    }
                    if !log.lines.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(log.lines.suffix(12).joined(separator: "\n"))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Ink.primary)
                                .textSelection(.enabled).fixedSize()
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    }
                } else {
                    Text("Loading the failed step…").font(Ink.meta).foregroundStyle(Ink.tertiary)
                }
                HStack(spacing: 12) {
                    Button("Open run") { open((log?.url ?? run.url)?.absoluteString ?? "") }
                    Button("Copy for Claude", action: copy)
                }
                .buttonStyle(.link).font(Ink.meta)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill((stuck ? Ink.warning : Ink.red).opacity(stuck ? 0.06 : 0.08)))
        .task(id: expanded) { if expanded { await monitor.loadCILog(run, status: status) } }
        .contextMenu {
            Button(expanded ? "Hide Failed Step" : "Show Failed Step", action: toggle)
            Button("Open Run") { open((monitor.ciLogs[run.id]?.url ?? run.url)?.absoluteString ?? "") }
            Button("Open Workflow Runs on \(status.branch)") {
                open("https://github.com/\(status.repository)/actions?query=branch%3A\(status.branch)")
            }
            Button("Open Commit") { open("https://github.com/\(status.repository)/commit/\(run.sha)") }
            Divider()
            Button("Copy for Claude", action: copy)
            if let url = run.url { Button("Copy Run Link") { DeployCommands.copy(url.absoluteString) } }
            Button("Copy Commit SHA") { DeployCommands.copy(run.sha) }
            Button("Copy Rerun Command") { DeployCommands.copy("gh run rerun \(run.id) --failed -R \(status.repository)") }
        }
    }
}

/// Pin, unpin and hide a project, shared by its cards and its production pill.
struct DeployProjectMenu: View {
    let key: String
    let project: String

    var body: some View {
        let pinned = Defaults[.deployPinnedProjects].contains(key)
        Button(pinned ? "Unpin \(project)" : "Pin \(project) to the Strip") {
            if pinned { Defaults[.deployPinnedProjects].removeAll { $0 == key } }
            else { Defaults[.deployPinnedProjects].append(key) }
        }
        Button("Hide \(project)") {
            if !Defaults[.deployHiddenProjects].contains(key) { Defaults[.deployHiddenProjects].append(key) }
            DeployMonitor.shared.recompute()
        }
    }
}

/// A coloured dot that pulses while building.
struct StateDot: View {
    let state: DeployState
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle().fill(DeployText.tint(state))
            .frame(width: size, height: size)
            .opacity(state.isActive && pulse ? 0.35 : 1)
            .onAppear {
                guard state.isActive else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
            }
    }
}

/// One deployment.
struct DeployCard: View {
    let deployment: Deployment
    let seen: Bool
    let expanded: Bool
    var selected = false
    var flash: String? = nil
    let toggle: () -> Void
    let open: (String) -> Void
    var copyPrompt: () -> Void = {}
    let monitor: DeployMonitor
    @State private var hover = false

    private var d: Deployment { deployment }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 11) {
                leading.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.project).font(seen ? Ink.body : Ink.body.weight(.medium))
                            .foregroundStyle(seen ? Ink.secondary : Ink.primary).lineLimit(1)
                        // Production is the usual case; only the exceptions get a label.
                        if d.releaseKind?.isConfig == true || !d.target.isProduction {
                            let badge = d.releaseKind?.isConfig == true ? "Config" : d.target.title
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Ink.secondary.opacity(0.15)))
                        }
                        Spacer(minLength: 0)
                        timing
                    }
                    HStack(spacing: 6) {
                        Image(systemName: DeployText.providerSymbol(d.provider)).font(.system(size: 8))
                            .help(d.provider.title)
                        Text(DeployText.status(d)).foregroundStyle(DeployText.tint(d)).fontWeight(.medium)
                        if let detail = Optional(DeployText.detail(d)), !detail.isEmpty, d.state != .failed, !d.isCrashed {
                            Text(detail).lineLimit(1)
                        }
                    }
                    .font(Ink.meta).foregroundStyle(Ink.tertiary)
                    if d.isCrashed {
                        Text("\((d.crashedDynos ?? []).joined(separator: ", ")) crashed after this release went live")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.red).lineLimit(2)
                    }
                    if d.state == .failed, let line = d.failureSummary {
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.red)
                            .lineLimit(expanded ? 6 : 1).textSelection(.enabled)
                    }
                }
                Circle().fill(seen || d.state.isActive ? Color.clear : (d.isCrashed ? Ink.red : Ink.accent))
                    .frame(width: 6, height: 6).padding(.top, 6)
            }
            if expanded { DeployLogTail(deployment: d, monitor: monitor).padding(.leading, 39) }
            // Never on hover or selection: a row that appears under the pointer makes the card
            // taller, pushes the next card under the pointer, and the two flicker back and forth.
            // Everything else lives in the right-click menu.
            if showsActionRow { actions.padding(.leading, 39) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover || selected ? Ink.raised : .clear))
        .overlay(alignment: .topTrailing) {
            if let flash {
                Text(flash).font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Ink.green.opacity(0.15)))
                    .padding(6).transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.project), \(d.target.title), \(d.provider.title), \(d.state.title)")
    }

    @ViewBuilder private var leading: some View {
        ZStack {
            Circle().fill(DeployText.tint(d).opacity(0.16))
            if d.state.isActive {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: DeployText.symbol(d))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DeployText.tint(d))
            }
        }
    }

    @ViewBuilder private var timing: some View {
        if d.state.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DeployText.duration(context.date.timeIntervalSince(d.createdAt)))
                    .font(Ink.meta).monospacedDigit().foregroundStyle(Ink.warning)
            }
        } else {
            HStack(spacing: 6) {
                if let duration = d.duration, !d.nativeID.hasPrefix("release:") {
                    Text(DeployText.duration(duration)).foregroundStyle(Ink.secondary)
                }
                Text(Formatting.age(of: d.createdAt, now: Date())).foregroundStyle(Ink.tertiary)
            }
            .font(Ink.meta).monospacedDigit()
        }
    }

    private var showsActionRow: Bool { expanded || d.state == .failed || d.isCrashed }

    private var actions: some View {
        HStack(spacing: 12) {
            if let pr = d.pullRequestURL, let n = d.commit?.resolvedPullRequest {
                link("PR #\(n)", pr)
            }
            if let site = d.url { link("Visit", site.absoluteString) }
            if let logs = d.dashboardURL { link(d.state == .failed ? "Logs" : "Open", logs.absoluteString) }
            if d.state == .failed || d.isCrashed {
                Button(action: copyPrompt) {
                    Label("Copy for Claude", systemImage: "sparkles").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).font(Ink.meta.weight(.medium)).foregroundStyle(Ink.accent)
                .help("Copies a prompt with the repo, commit, error and log tail (⌘⇧C)")
            }
        }
    }

    private func link(_ title: String, _ address: String) -> some View {
        Button(title) { open(address) }
            .buttonStyle(.plain).font(Ink.meta.weight(.medium)).foregroundStyle(Ink.primary)
    }

    @ViewBuilder private var menu: some View {
        Button(expanded ? "Hide Build Log" : "Show Build Log", action: toggle)
        if let site = d.url { Button("Open Site") { open(site.absoluteString) } }
        if let logs = d.dashboardURL { Button("Open in \(d.provider.title)") { open(logs.absoluteString) } }
        if let pr = d.pullRequestURL { Button("Open Pull Request") { open(pr) } }
        let repo = d.commit?.repository ?? Defaults[.deployRepoMap]["\(d.provider.rawValue):\(d.project)"]
        if let repo, let sha = d.commit?.sha { Button("Open Commit on GitHub") { open("https://github.com/\(repo)/commit/\(sha)") } }
        Divider()
        if let site = d.url { Button("Copy URL") { copy(site.absoluteString) } }
        if let sha = d.commit?.sha { Button("Copy Commit SHA") { copy(sha) } }
        if let message = d.commit?.firstLine { Button("Copy Commit Message") { copy(message) } }
        if d.provider == .heroku { Button("Copy Logs Command") { copy("heroku logs --tail -a \(d.project)") } }
        Button("Copy for Claude") { copyPrompt() }
        Divider()
        if !seen { Button("Mark as Seen") { monitor.markSeen([d.id]) } }
        DeployProjectMenu(key: "\(d.provider.rawValue):\(d.project)", project: d.project)
        if Defaults[.deployAllowActions] {
            Divider()
            if d.provider == .vercel, d.state.isFinished {
                Button("Redeploy… (⌘⇧R)") { DeployCommands.redeploy(d, monitor: monitor) }
            }
            if d.state == .ready, d.target.isProduction, d.provider == .vercel || d.version != nil {
                Button("Roll back to this…") { DeployCommands.confirm("Roll production back to this deployment?",
                    "\(d.project) will serve this \(d.provider == .heroku ? "release (v\(d.version ?? 0))" : "deployment") again. Live traffic changes immediately.") {
                        try await monitor.rollback(to: d) } }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

}

/// Actions shared by the card's buttons, its menu and the keyboard.
@MainActor
enum DeployCommands {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func copyPrompt(_ d: Deployment, state: DeployPanelState, monitor: DeployMonitor) {
        state.say("Copying…", on: d.id)
        Task { @MainActor in
            await monitor.copyPrompt(for: d)
            state.say("Copied for Claude", on: d.id)
        }
    }

    static func redeploy(_ d: Deployment, monitor: DeployMonitor) {
        guard Defaults[.deployAllowActions], d.provider == .vercel, d.state.isFinished else { NSSound.beep(); return }
        confirm("Redeploy \(d.project)?",
                "Vercel builds this deployment's source again\(d.target.isProduction ? " and promotes it to production" : "").") {
            try await monitor.redeploy(d)
        }
    }

    static func confirm(_ title: String, _ body: String, _ action: @escaping @MainActor () async throws -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do { try await action() } catch {
                let failure = NSAlert()
                failure.messageText = "That did not work"
                failure.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failure.runModal()
            }
        }
    }
}

// MARK: - Insights

struct DeployInsights: View {
    let history: [Deployment]
    @State private var range = StatsRange.week

    var body: some View {
        let stats = DeployStats(history, range: range)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    tile("Deploys", "\(stats.total)", sub: "\(stats.today) today")
                    tile("Success", stats.successRate.map { percent($0) } ?? "–", sub: delta(stats))
                    tile("Median build", stats.medianDuration.map(DeployText.duration) ?? "–",
                         sub: stats.p95Duration.map { "p95 \(DeployText.duration($0))" } ?? "")
                    tile("Recovery", stats.mttr.map(DeployText.duration) ?? "–", sub: "mean, prod")
                    tile("Preview → prod", stats.leadTime.map(DeployText.duration) ?? "–", sub: "lead time")
                    tile("Green streak", "\(stats.greenStreak)", sub: "prod in a row")
                }

                if stats.total == 0 {
                    Text("No deployments in this range.").font(Ink.meta).foregroundStyle(Ink.secondary)
                } else {
                    chartTitle("Deployments")
                    Chart {
                        ForEach(stats.buckets) { b in
                            BarMark(x: .value("Time", b.start, unit: range.bucket), y: .value("Ready", b.ready))
                                .foregroundStyle(by: .value("State", "Ready"))
                            BarMark(x: .value("Time", b.start, unit: range.bucket), y: .value("Failed", b.failed))
                                .foregroundStyle(by: .value("State", "Failed"))
                            BarMark(x: .value("Time", b.start, unit: range.bucket), y: .value("Canceled", b.canceled))
                                .foregroundStyle(by: .value("State", "Canceled"))
                        }
                    }
                    .chartForegroundStyleScale(["Ready": Ink.green, "Failed": Ink.red, "Canceled": Ink.secondary])
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 120)

                    if !stats.durations.isEmpty {
                        chartTitle("Build time")
                        Chart {
                            ForEach(stats.durations) { p in
                                LineMark(x: .value("Time", p.start, unit: range.bucket), y: .value("Seconds", p.p50))
                                    .foregroundStyle(by: .value("Series", "Median"))
                                    .symbol(.circle)
                                LineMark(x: .value("Time", p.start, unit: range.bucket), y: .value("Seconds", p.p95))
                                    .foregroundStyle(by: .value("Series", "p95"))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                        }
                        .chartForegroundStyleScale(["Median": Ink.primary, "p95": Ink.warning])
                        .chartYAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel { if let s = value.as(Double.self) { Text(DeployText.duration(s)) } }
                            }
                        }
                        .chartLegend(position: .bottom, alignment: .leading)
                        .frame(height: 110)
                    }

                    chartTitle("Busiest hours")
                    Chart(stats.heatmap) { cell in
                        RectangleMark(x: .value("Hour", cell.hour), y: .value("Day", weekday(cell.weekday)),
                                      width: .ratio(0.9), height: .ratio(0.85))
                            .foregroundStyle(by: .value("Deploys", cell.count))
                    }
                    .chartForegroundStyleScale(range: [Ink.accent.opacity(0.15), Ink.accent])
                    .chartXScale(domain: 0...23)
                    .chartYScale(domain: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].reversed())
                    .chartLegend(.hidden)
                    .frame(height: 120)

                    if let slow = stats.slowestProject {
                        Text("Slowest project: \(slow.name), median \(DeployText.duration(slow.median))")
                            .font(Ink.meta).foregroundStyle(Ink.secondary)
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .contextMenu {
                Picker("Range", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Copy Summary") {
                    var lines = ["Deployments, last \(range.rawValue): \(stats.total)"]
                    if let rate = stats.successRate { lines.append("Success rate: \(percent(rate))") }
                    if let p95 = stats.p95Duration { lines.append("Build time p95: \(DeployText.duration(p95))") }
                    if let slow = stats.slowestProject { lines.append("Slowest project: \(slow.name), median \(DeployText.duration(slow.median))") }
                    DeployCommands.copy(lines.joined(separator: "\n"))
                }
                Button("Refresh Deployments") { DeployMonitor.shared.refresh() }
            }
        }
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func weekday(_ n: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][max(0, min(6, n - 1))]
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func delta(_ stats: DeployStats) -> String {
        guard let now = stats.successRate, let before = stats.previousSuccessRate else { return "" }
        let points = Int(((now - before) * 100).rounded())
        return points == 0 ? "same as before" : "\(points > 0 ? "+" : "")\(points) pts"
    }

    private func chartTitle(_ s: String) -> some View {
        Text(s).font(Ink.meta.weight(.semibold)).foregroundStyle(Ink.secondary)
    }

    private func tile(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(Ink.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10)).foregroundStyle(Ink.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
    }
}
