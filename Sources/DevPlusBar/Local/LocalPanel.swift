import AppKit
import SwiftUI
import Defaults

/// The Local side's cursor and feedback, kept on the panel model so the keyboard can drive it.
@MainActor
final class LocalPanelState: ObservableObject {
    @Published var cursor: String?
    /// Repositories with only uncommitted edits stay folded until asked for.
    @Published var showUncommitted = false
    /// Unpushed work set aside for over a week stays folded too.
    @Published var showParked = false
    @Published var flash: [String: String] = [:]

    func rowIDs(_ monitor: LocalMonitor) -> [String] {
        (monitor.unpushed + (showParked ? monitor.parked : []) + (showUncommitted ? monitor.uncommitted : [])).map(\.id)
            + monitor.servers.map { "srv:" + $0.id }
    }

    func say(_ text: String, on id: String) {
        flash[id] = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if self.flash[id] == text { self.flash[id] = nil }
        }
    }
}

/// The Local side: what is committed or changed on disk but not on GitHub yet, and what is
/// listening on a port. Each repository shows where its deployment stands, so one row reads
/// local → pushed → merged → deployed.
struct LocalPanel: View {
    @ObservedObject var monitor: LocalMonitor
    @ObservedObject var deploys: DeployMonitor
    @ObservedObject var state: LocalPanelState
    var open: (String) -> Void

    var body: some View {
        let repos = monitor.unpushed
        let parked = monitor.parked
        let uncommitted = monitor.uncommitted
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Ink.hairline).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        heading("Not pushed", trailing: "\(repos.count) of \(monitor.repos.count) repositories")
                        if repos.isEmpty && !parked.isEmpty {
                            Text("Nothing recent waiting to be pushed.")
                                .font(Ink.meta).foregroundStyle(Ink.secondary).padding(.horizontal, 10).padding(.bottom, 6)
                        } else if repos.isEmpty {
                            Text(monitor.lastScan == nil ? "Looking for repositories…"
                                 : monitor.repos.isEmpty ? "No git repositories found. Set the folders in Settings › General."
                                 : "Every commit on this Mac is on GitHub.")
                                .font(Ink.meta).foregroundStyle(Ink.secondary).padding(.horizontal, 10).padding(.bottom, 6)
                        }
                        ForEach(repos) { repo in
                            RepoRow(repo: repo, monitor: monitor, deploys: deploys,
                                    selected: state.cursor == repo.id, flash: state.flash[repo.id],
                                    copied: { state.say($0, on: repo.id) }, open: open)
                                .id(repo.id)
                        }
                        if !parked.isEmpty {
                            fold(state.showParked ? "Hide parked" : "\(parked.count) parked, nothing new for over a week") {
                                state.showParked.toggle()
                            }
                            .help("Unpushed commits nothing was added to for 7 days. They are not counted on the icon and never notify.")
                            if state.showParked {
                                ForEach(parked) { repo in
                                    RepoRow(repo: repo, monitor: monitor, deploys: deploys,
                                            selected: state.cursor == repo.id, flash: state.flash[repo.id],
                                            copied: { state.say($0, on: repo.id) }, open: open)
                                        .id(repo.id)
                                }
                            }
                        }
                        if state.showUncommitted {
                            ForEach(uncommitted) { repo in
                                RepoRow(repo: repo, monitor: monitor, deploys: deploys,
                                        selected: state.cursor == repo.id, flash: state.flash[repo.id],
                                        copied: { state.say($0, on: repo.id) }, open: open)
                                    .id(repo.id)
                            }
                        }
                        if !uncommitted.isEmpty {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) { state.showUncommitted.toggle() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: state.showUncommitted ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(state.showUncommitted ? "Hide uncommitted-only"
                                         : "\(uncommitted.count) more with uncommitted changes only")
                                }
                                .font(Ink.meta).foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if !monitor.servers.isEmpty {
                            heading("Listening on this Mac",
                                    trailing: ProcessParser.memory(monitor.servers.reduce(0) { $0 + $1.memoryKB }))
                                .padding(.top, 8)
                            ForEach(monitor.servers) { server in
                                ServerRow(server: server, project: monitor.repo(containing: server.cwd)?.name
                                          ?? server.cwd.map { ($0 as NSString).lastPathComponent },
                                          selected: state.cursor == "srv:" + server.id,
                                          stopping: !monitor.terminated.isDisjoint(with: server.pids),
                                          stop: { monitor.stop(server) },
                                          openFolder: { if let cwd = server.cwd { monitor.openInTerminal(cwd) } })
                                    .id("srv:" + server.id)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.cursor) {
                    if let cursor = state.cursor { withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(cursor) } }
                }
            }
        }
        .task { await monitor.scanIfStale() }
    }

    private func fold(_ title: String, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: title.hasPrefix("Hide") ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
            }
            .font(Ink.meta).foregroundStyle(Ink.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func heading(_ title: String, trailing: String?) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Ink.tertiary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Ink.tertiary) }
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }
}

struct RepoRow: View {
    let repo: RepoState
    let monitor: LocalMonitor
    @ObservedObject var deploys: DeployMonitor
    let selected: Bool
    let flash: String?
    let copied: (String) -> Void
    let open: (String) -> Void
    @State private var hover = false

    /// The production deployment built from this repository, if one is followed.
    private var production: (key: String, deployment: Deployment)? {
        guard let github = repo.github?.lowercased() else { return nil }
        let map = Defaults[.deployRepoMap]
        return deploys.deployments.first { d in
            d.target.isProduction && d.releaseKind?.isConfig != true
                && (d.commit?.repository ?? map["\(d.provider.rawValue):\(d.project)"])?.lowercased() == github
        }.map { ("\($0.provider.rawValue):\($0.project)", $0) }
    }

    var body: some View {
        Button { monitor.openInEditor(repo.path) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: repo.hasUnpushed ? (repo.isParked() ? "moon.zzz" : "arrow.up.circle.fill") : "pencil.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(repo.hasUnpushed && !repo.isParked() ? Ink.warning : Ink.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(repo.name).font(Ink.body).lineLimit(1)
                        if let branch = repo.branch {
                            Text(branch).font(Ink.meta).foregroundStyle(Ink.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let flash { Text(flash).font(Ink.meta).foregroundStyle(Ink.green) }
                    }
                    HStack(spacing: 8) {
                        let parked = repo.isParked()
                        let age = repo.unpushedAge().map { " · \($0)" } ?? ""
                        if repo.ahead > 0 { chip("↑\(repo.ahead) unpushed\(age)", parked ? Ink.tertiary : Ink.warning) }
                        if repo.isUnpublished { chip("branch not pushed\(age)", parked ? Ink.tertiary : Ink.warning) }
                        if repo.changed > 0 { chip("\(repo.changed) changed", Ink.secondary) }
                        if repo.behind > 0 { chip("↓\(repo.behind)", Ink.tertiary) }
                        if let production { pipeline(production.key, production.deployment) }
                    }
                    if let subject = repo.unpushed.first {
                        Text("“\(subject)”").font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected || hover ? Ink.raised : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .contextMenu {
            Button("Open in Editor") { monitor.openInEditor(repo.path) }
            Button("Open in Terminal") { monitor.openInTerminal(repo.path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)]) }
            if let github = repo.github {
                Button("Open on GitHub") { open("https://github.com/\(github)") }
            }
            Divider()
            if let production {
                Button("Open \(production.deployment.project) in \(production.deployment.provider.title)") {
                    if let url = production.deployment.dashboardURL ?? production.deployment.url { open(url.absoluteString) }
                }
            }
            Divider()
            Button("Copy Path") { DeployCommands.copy(repo.path); copied("Path copied") }
            if repo.ahead > 0 || repo.isUnpublished {
                Button("Copy Push Command") {
                    let push = repo.isUnpublished ? "git push -u origin \(repo.branch ?? "HEAD")" : "git push"
                    DeployCommands.copy("cd \(shellQuoted(repo.path)) && \(push)")
                    copied("Command copied")
                }
            }
            if !repo.unpushed.isEmpty {
                Button("Copy Unpushed Commits") { DeployCommands.copy(repo.unpushed.map { "- \($0)" }.joined(separator: "\n")); copied("Commits copied") }
            }
            Divider()
            Button("Rescan") { Task { await monitor.scanNow() } }
        }
    }

    /// Where the pushed work goes next: the production pill's state, waiting commits, CI.
    @ViewBuilder private func pipeline(_ key: String, _ d: Deployment) -> some View {
        HStack(spacing: 4) {
            if d.isCrashed { Circle().fill(Ink.red).frame(width: 6, height: 6) } else { StateDot(state: d.state, size: 6) }
            Text(d.project).font(.system(size: 10.5)).foregroundStyle(Ink.secondary).lineLimit(1)
            if let waiting = deploys.pending[key], waiting.count > 0 {
                Text("\(waiting.count) waiting").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Ink.warning)
            }
            if let checks = deploys.ci[key], checks.isFailing {
                Text("CI ✗").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(checks.hasFreshBreak ? Ink.red : Ink.warning)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private var help: String {
        var lines = [repo.path]
        if repo.ahead > 0 { lines.append("\(repo.ahead) commit\(repo.ahead == 1 ? "" : "s") not pushed to \(repo.upstream ?? "origin"):") }
        lines += repo.unpushed.map { "• \($0)" }
        if repo.ahead > repo.unpushed.count { lines.append("…") }
        if let oldest = repo.unpushedOldest {
            lines.append("Only on this Mac since \(oldest.formatted(date: .abbreviated, time: .shortened))"
                         + (repo.isParked() ? "; parked, nothing new for over a week" : ""))
        }
        if repo.changed > 0 { lines.append("\(repo.changed) file\(repo.changed == 1 ? "" : "s") changed or untracked") }
        if repo.behind > 0 { lines.append("\(repo.behind) behind \(repo.upstream ?? "upstream") as of the last fetch") }
        lines.append("Click to open in your editor; right-click for more.")
        return lines.joined(separator: "\n")
    }
}

func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

struct ServerRow: View {
    let server: DevServer
    let project: String?
    let selected: Bool
    let stopping: Bool
    let stop: () -> Void
    let openFolder: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: server.kind == .database ? "cylinder.split.1x2" : "server.rack")
                .font(.system(size: 12)).foregroundStyle(Ink.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.ports.map { ":\($0)" }.joined(separator: " ")).font(Ink.body).monospacedDigit()
                    Text(server.title).font(Ink.meta).foregroundStyle(Ink.secondary).lineLimit(1)
                }
                Text([project, ProcessParser.memory(server.memoryKB)].compactMap { $0 }.joined(separator: " · "))
                    .font(Ink.meta).foregroundStyle(Ink.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if server.kind == .dev {
                Button(action: stop) {
                    Text(stopping ? "Force quit" : "Stop").font(Ink.meta)
                        .foregroundStyle(stopping ? Ink.red : Ink.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().strokeBorder(Ink.hairline))
                }
                .buttonStyle(.plain)
                .help("Asks first, then sends SIGTERM to \(server.pids.map(String.init).joined(separator: ", "))")
            } else {
                Text("service").font(Ink.meta).foregroundStyle(Ink.tertiary)
                    .help("A database. Stop it with brew services or your project's own script.")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected || hover ? Ink.raised : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: openFolder)
        .help((server.cwd ?? "") + "\nDouble-click to open a terminal there; right-click for more.")
        .contextMenu {
            let monitor = LocalMonitor.shared
            if server.kind == .dev, let port = server.ports.first {
                Button("Open http://localhost:\(port)") {
                    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                }
            }
            if let cwd = server.cwd {
                let folder = monitor.repo(containing: cwd)?.path ?? cwd
                Button("Open Project in Editor") { monitor.openInEditor(folder) }
                Button("Open Terminal Here") { monitor.openInTerminal(cwd) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)]) }
            }
            Divider()
            if let port = server.ports.first { Button("Copy http://localhost:\(port)") { DeployCommands.copy("http://localhost:\(port)") } }
            Button("Copy PID") { DeployCommands.copy(server.pids.map(String.init).joined(separator: " ")) }
            if let cwd = server.cwd { Button("Copy Folder Path") { DeployCommands.copy(cwd) } }
            Divider()
            if server.kind == .dev {
                Button(stopping ? "Force Quit…" : "Stop…", action: stop)
            }
            Button("Rescan") { Task { await monitor.scanNow() } }
        }
    }
}

/// The keyboard on the Local side.
@MainActor
enum LocalKeys {
    static func handle(_ press: KeyPress, model: PanelModel) -> Bool {
        let state = model.local
        let monitor = LocalMonitor.shared
        let ids = state.rowIDs(monitor)
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .leftArrow, .rightArrow:
            model.step(press.key == .rightArrow ? 1 : -1)
        case .upArrow, .downArrow:
            guard !ids.isEmpty else { return true }
            let index = state.cursor.flatMap(ids.firstIndex(of:))
            let next = switch (index, press.key == .downArrow) {
            case (nil, true): 0
            case (nil, false): ids.count - 1
            case (let i?, true): min(i + 1, ids.count - 1)
            case (let i?, false): max(i - 1, 0)
            }
            state.cursor = ids[next]
        case .return:
            guard let cursor = state.cursor else { return true }
            let path = cursor.hasPrefix("srv:") ? server(cursor, monitor)?.cwd : cursor
            guard let path else { return true }
            if command || cursor.hasPrefix("srv:") { monitor.openInTerminal(path) } else { monitor.openInEditor(path) }
        case .delete where command:
            if let cursor = state.cursor, let server = server(cursor, monitor) { monitor.stop(server) }
        default:
            guard command, press.characters.lowercased() == "c", let cursor = state.cursor else { return false }
            guard let path = cursor.hasPrefix("srv:") ? server(cursor, monitor)?.cwd : cursor else { return true }
            DeployCommands.copy(path)
            state.say("Path copied", on: cursor)
        }
        return true
    }

    private static func server(_ id: String, _ monitor: LocalMonitor) -> DevServer? {
        monitor.servers.first { "srv:" + $0.id == id }
    }
}
