import Foundation

/// A git repository on this Mac and what has not left it yet.
struct RepoState: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
    var branch: String?
    /// "origin/main"; nil when the branch was never pushed.
    var upstream: String?
    var ahead = 0
    /// As of the last `git fetch`; Dev+ Bar never fetches.
    var behind = 0
    /// Modified, staged, conflicted and untracked files.
    var changed = 0
    /// "owner/name" when origin is on GitHub.
    var github: String?
    var hasRemote = false
    /// Subjects of the unpushed commits, newest first.
    var unpushed: [String] = []
    /// Commit dates of the newest and oldest commit that is only on this Mac.
    var unpushedNewest: Date?
    var unpushedOldest: Date?
    /// `git status` answered. When it did not (a timeout under load), nothing here says the work
    /// was pushed.
    var statusRead = false

    /// A branch with commits that has a remote to go to but was never pushed.
    var isUnpublished: Bool { upstream == nil && hasRemote && branch != nil }
    var needsAttention: Bool { ahead > 0 || changed > 0 || isUnpublished }
    var hasUnpushed: Bool { ahead > 0 || isUnpublished }

    /// Nothing new committed for this long: set aside, not today's work at risk.
    static let parkedAfter: TimeInterval = 7 * 86_400

    func isParked(now: Date = Date()) -> Bool {
        guard hasUnpushed, let newest = unpushedNewest else { return false }
        return now.timeIntervalSince(newest) > Self.parkedAfter
    }

    /// "22h", "3d", "4mo": how long the oldest unpushed commit has been only here.
    func unpushedAge(now: Date = Date()) -> String? {
        unpushedOldest.map { RepoState.age(now.timeIntervalSince($0)) }
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 2 * 86_400 { return "\(Int(s / 3600))h" }
        if s < 60 * 86_400 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (30 * 86_400)))mo"
    }
}

/// A process listening on a TCP port, grouped by command, port and folder.
struct DevServer: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable { case dev, database }
    var id: String { "\(command):\(ports.map(String.init).joined(separator: ","))" }
    let pids: [Int32]
    /// "node", "php", "mysqld".
    let command: String
    /// What it runs: "vite", "next", "tool-server.cjs"; nil when the command says it all.
    let detail: String?
    let ports: [Int]
    let cwd: String?
    /// Kilobytes, the listening processes and everything they started.
    let memoryKB: Int
    let kind: Kind

    var title: String { detail.map { "\(command) · \($0)" } ?? command }
}

enum GitStatusParser {
    /// `git status --porcelain=v2 --branch`.
    static func parse(_ text: String, into repo: inout RepoState) {
        for line in text.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst("# branch.head ".count))
                repo.branch = head == "(detached)" ? nil : head
            } else if line.hasPrefix("# branch.upstream ") {
                repo.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                repo.ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                repo.behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
            } else if let kind = line.first, "12u?".contains(kind), line.dropFirst().first == " " {
                repo.changed += 1
            }
        }
    }

    /// origin's URL from `.git/config`, as "owner/name" when it is on GitHub.
    static func origin(fromConfig text: String) -> (hasRemote: Bool, github: String?) {
        var inOrigin = false, hasRemote = false, github: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                if line.hasPrefix("[remote ") { hasRemote = true }
            } else if inOrigin, line.hasPrefix("url") {
                github = Self.github(fromURL: line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
            }
        }
        return (hasRemote, github)
    }

    /// `git log --format=%ct%x09%s`, newest first: the first subjects, and the newest and
    /// oldest commit dates.
    static func unpushedLog(_ text: String, keep: Int = 5) -> (subjects: [String], newest: Date?, oldest: Date?) {
        var subjects: [String] = [], dates: [Date] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let seconds = parts.first.flatMap({ TimeInterval($0) }) else { continue }
            dates.append(Date(timeIntervalSince1970: seconds))
            if subjects.count < keep { subjects.append(parts.count > 1 ? String(parts[1]) : "") }
        }
        return (subjects, dates.max(), dates.min())
    }

    static func github(fromURL url: String) -> String? {
        guard let range = url.range(of: "github.com") else { return nil }
        var rest = url[range.upperBound...]
        if rest.first == ":" || rest.first == "/" { rest = rest.dropFirst() }
        let parts = rest.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(parts[0])/\(name)"
    }
}

enum ProcessParser {
    /// `lsof -nP -iTCP -sTCP:LISTEN -F pcn`: pid, command and the ports it listens on.
    static func listeners(_ text: String) -> [Int32: (command: String, ports: Set<Int>)] {
        var result: [Int32: (command: String, ports: Set<Int>)] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value); if let pid, result[pid] == nil { result[pid] = ("", []) }
            case "c": if let pid { result[pid]?.command = String(value) }
            case "n":
                if let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
                    result[pid]?.ports.insert(port)
                }
            default: break
            }
        }
        return result
    }

    /// `ps -axo pid=,ppid=,rss=,args=`.
    static func table(_ text: String) -> [Int32: (ppid: Int32, rss: Int, args: String)] {
        var result: [Int32: (ppid: Int32, rss: Int, args: String)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]), let rss = Int(parts[2]) else { continue }
            result[pid] = (ppid, rss, parts.count > 3 ? String(parts[3]) : "")
        }
        return result
    }

    /// `lsof -a -d cwd -Fn -p …`: each process's working folder.
    static func folders(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if line.hasPrefix("n"), let pid { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    static let databases: Set<String> = ["mysqld", "postgres", "redis-server", "mongod", "memcached", "mariadbd", "clickhouse"]
    static let devCommands: Set<String> = [
        "node", "bun", "deno", "python", "python3", "Python", "ruby", "php", "php-fpm", "java", "go", "dotnet",
        "beam.smp", "rails", "puma", "uvicorn", "gunicorn", "nginx", "httpd", "caddy", "hugo", "esbuild", "vite",
        "air", "flask", "uwsgi", "qemu-system-aarch64", "qemu-system-x86_64", "wrangler", "workerd", "ngrok", "cloudflared",
    ]

    /// "node /x/node_modules/.bin/vite --port 4000" -> "vite"; "node server.js" -> "server.js".
    static func detail(args: String, command: String) -> String? {
        let tokens = args.split(separator: " ").map(String.init)
        guard ["node", "bun", "deno", "python", "python3", "Python", "ruby", "java"].contains(command),
              let script = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        if let range = script.range(of: "node_modules/", options: .backwards) {
            let parts = script[range.upperBound...].split(separator: "/").map(String.init)
            let package = parts.first == ".bin" ? parts.dropFirst().first
                : parts.first?.hasPrefix("@") == true ? parts.dropFirst().first : parts.first
            if let package { return package }
        }
        return (script as NSString).lastPathComponent
    }

    /// Groups listeners into rows, with the memory of each process tree.
    static func servers(listeners: [Int32: (command: String, ports: Set<Int>)],
                        table: [Int32: (ppid: Int32, rss: Int, args: String)],
                        folders: [Int32: String]) -> [DevServer] {
        var children: [Int32: [Int32]] = [:]
        for (pid, row) in table { children[row.ppid, default: []].append(pid) }
        func tree(_ pid: Int32, _ seen: inout Set<Int32>) -> Int {
            guard seen.insert(pid).inserted else { return 0 }
            return (table[pid]?.rss ?? 0) + (children[pid] ?? []).reduce(0) { $0 + tree($1, &seen) }
        }
        struct Key: Hashable { let command: String; let ports: [Int]; let cwd: String? }
        var groups: [Key: [Int32]] = [:]
        for (pid, listener) in listeners {
            let args = table[pid]?.args ?? listener.command
            let command = ((args.split(separator: " ").first.map(String.init) ?? listener.command) as NSString).lastPathComponent
            guard databases.contains(command) || devCommands.contains(command) else { continue }
            groups[Key(command: command, ports: listener.ports.sorted(), cwd: folders[pid]), default: []].append(pid)
        }
        return groups.map { key, pids in
            var seen = Set<Int32>()
            let memory = pids.reduce(0) { $0 + tree($1, &seen) }
            let first = pids.min()!
            return DevServer(pids: pids.sorted(), command: key.command,
                             detail: detail(args: table[first]?.args ?? "", command: key.command),
                             ports: key.ports, cwd: key.cwd, memoryKB: memory,
                             kind: databases.contains(key.command) ? .database : .dev)
        }
        .sorted { ($0.kind == .dev ? 0 : 1, $0.ports.first ?? 0) < ($1.kind == .dev ? 0 : 1, $1.ports.first ?? 0) }
    }

    static func memory(_ kb: Int) -> String {
        kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576)
            : kb >= 1024 ? "\(kb / 1024) MB" : "\(kb) KB"
    }
}

/// Runs git, lsof and ps. Nothing here writes to a repository: `GIT_OPTIONAL_LOCKS=0` keeps
/// `git status` from refreshing the index, which would race an editor's own git.
enum LocalScanner {
    static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        ["Developer", "Projects", "Code", "code", "src", "dev", "GitHub", "Documents/GitHub", "Desktop"]
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func roots(_ setting: String) -> [String] {
        let listed = setting.split(separator: ",").map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty }
        return listed.isEmpty ? defaultRoots() : listed
    }

    static let skipped: Set<String> = ["node_modules", "Library", "vendor", "Pods", "build", "dist", "DerivedData", "venv"]

    /// Folders holding a `.git`, up to three levels under each root; not inside other repositories.
    static func discover(roots: [String], depth: Int = 3) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        func walk(_ path: String, _ level: Int) {
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { found.append(path); return }
            guard level < depth, let names = try? fm.contentsOfDirectory(atPath: path) else { return }
            for name in names where !name.hasPrefix(".") && !skipped.contains(name) {
                let child = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                walk(child, level + 1)
            }
        }
        for root in roots { walk(root, 0) }
        return Array(Set(found)).sorted()
    }

    static func repo(at path: String) -> RepoState {
        var repo = RepoState(path: path)
        // A large working tree takes seconds to stat while the AI log scan is running; at 5 s
        // two repositories here dropped out of the list now and then.
        if let status = run("/usr/bin/git", ["-C", path, "status", "--porcelain=v2", "--branch"], timeout: 15) {
            GitStatusParser.parse(status, into: &repo)
            repo.statusRead = true
        }
        if let config = try? String(contentsOfFile: (path as NSString).appendingPathComponent(".git/config"), encoding: .utf8) {
            (repo.hasRemote, repo.github) = GitStatusParser.origin(fromConfig: config)
        }
        // No upstream set is not the same as never pushed: compare with origin's copy if it has one.
        if repo.upstream == nil, repo.hasRemote, let branch = repo.branch,
           let count = run("/usr/bin/git", ["-C", path, "rev-list", "--count", "refs/remotes/origin/\(branch)..HEAD"], exitCodes: [0]),
           let ahead = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) {
            repo.upstream = "origin/\(branch)"
            repo.ahead = ahead
        }
        // Every unpushed commit's date, for how long the work has been only here.
        let range: [String]? = repo.ahead > 0 ? repo.upstream.map { ["\($0)..HEAD"] }
            : repo.isUnpublished ? ["HEAD", "--not", "--remotes", "-n", "500"] : nil
        if let range,
           let log = run("/usr/bin/git", ["-C", path, "log"] + range + ["--format=%ct%x09%s"], exitCodes: [0]) {
            let parsed = GitStatusParser.unpushedLog(log)
            repo.unpushed = parsed.subjects
            repo.unpushedNewest = parsed.newest
            repo.unpushedOldest = parsed.oldest
        }
        return repo
    }

    static func repos(_ paths: [String]) async -> [RepoState] {
        await withTaskGroup(of: RepoState.self) { group in
            var iterator = paths.makeIterator()
            for _ in 0..<8 { if let p = iterator.next() { group.addTask { repo(at: p) } } }
            var out: [RepoState] = []
            for await state in group {
                out.append(state)
                if let p = iterator.next() { group.addTask { repo(at: p) } }
            }
            return out
        }
    }

    static func servers() -> [DevServer] {
        guard let lsof = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return [] }
        let listeners = ProcessParser.listeners(lsof)
        guard !listeners.isEmpty else { return [] }
        let table = ProcessParser.table(run("/bin/ps", ["-axo", "pid=,ppid=,rss=,args="]) ?? "")
        let pids = listeners.keys.map(String.init).joined(separator: ",")
        let folders = ProcessParser.folders(run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids]) ?? "")
        return ProcessParser.servers(listeners: listeners, table: table, folders: folders)
    }

    /// Output of a short command, or nil if it fails or takes over `timeout` seconds.
    /// `exitCodes` nil accepts any: lsof exits 1 when one of several pids has gone, with good output.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 5, exitCodes: Set<Int32>? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit,
              exitCodes?.contains(process.terminationStatus) ?? true else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
