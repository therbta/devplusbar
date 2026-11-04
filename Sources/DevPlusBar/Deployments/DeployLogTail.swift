import SwiftUI

/// The end of a deployment's build log under its card: follows a running build every few
/// seconds, then stays as it ended.
struct DeployLogTail: View {
    let deployment: Deployment
    let monitor: DeployMonitor
    @State private var lines: [String] = []
    @State private var loaded = false

    static let lineCount = 8
    static let followEvery: Duration = .seconds(3)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !loaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the build log…")
                }
                .font(Ink.meta).foregroundStyle(Ink.tertiary)
            } else if lines.isEmpty {
                Text(deployment.releaseKind != nil ? "This release has no build log." : "No build log available.")
                    .font(Ink.meta).foregroundStyle(Ink.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Self.tint(line))
                        .lineLimit(1).truncationMode(.tail)
                }
                if deployment.state.isActive {
                    HStack(spacing: 4) {
                        Circle().fill(Ink.warning).frame(width: 5, height: 5)
                        Text("live").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Ink.warning)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
        .contextMenu {
            Button("Copy log lines") { DeployCommands.copy(lines.joined(separator: "\n")) }
        }
        // Restarts when the state changes, so a finished build is read once more in full.
        .task(id: deployment.state) {
            repeat {
                let fresh = await monitor.logLines(for: deployment, limit: Self.lineCount)
                if !fresh.isEmpty || !loaded { lines = fresh }
                loaded = true
                guard deployment.state.isActive else { break }
                try? await Task.sleep(for: Self.followEvery)
            } while !Task.isCancelled
        }
    }

    static func tint(_ line: String) -> Color {
        let lower = line.lowercased()
        if ["error", "failed", "err!", "cannot"].contains(where: lower.contains) { return Ink.red }
        if lower.contains("warn") { return Ink.warning }
        return Ink.secondary
    }
}
