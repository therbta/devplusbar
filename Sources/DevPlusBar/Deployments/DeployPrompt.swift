import Foundation

/// A self-contained prompt for a coding agent about a failed or crashed deployment.
enum DeployPrompt {
    static func text(_ d: Deployment, repository: String?, log: [String]) -> String {
        var out: [String] = []
        let what = d.isCrashed ? "crashed right after its release went live" : "failed to deploy"
        out.append("The \(d.target.title.lowercased()) deployment of \(d.project) on \(d.provider.title) \(what).")
        out.append("")
        if let repository { out.append("Repository: \(repository)") }
        if let ref = d.commit?.ref { out.append("Branch: \(ref)") }
        if let sha = d.commit?.sha { out.append("Commit: \(sha)" + (d.commit?.firstLine.map { " — \($0)" } ?? "")) }
        if let version = d.version { out.append("Heroku release: v\(version)") }
        if let dynos = d.crashedDynos, !dynos.isEmpty { out.append("Crashed dynos: \(dynos.joined(separator: ", "))") }
        if let line = d.failureSummary { out.append("Error: \(line)") }
        if let logs = d.dashboardURL { out.append("Dashboard: \(logs.absoluteString)") }
        if !log.isEmpty {
            out.append("")
            out.append("Last \(log.count) lines of the build log:")
            out.append("```")
            out.append(contentsOf: log)
            out.append("```")
        }
        out.append("")
        if d.isCrashed {
            out.append("Check out that commit, find why the process crashes on boot (read `heroku logs --tail -a \(d.project)` "
                + "if you can), fix it, and verify by running the app's start command locally before proposing a deploy.")
        } else {
            out.append("Check out that commit, reproduce the failure with the project's own build command, fix the cause "
                + "(not the symptom), and verify the build passes locally before proposing a push.")
        }
        return out.joined(separator: "\n")
    }
}
