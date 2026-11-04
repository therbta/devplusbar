import SwiftUI
import Defaults

/// Settings › Deployments: connect providers, choose projects, alerts and sounds.
struct DeploymentsPane: View {
    @ObservedObject private var monitor = DeployMonitor.shared
    @Default(.vercelAccount) private var vercelAccount
    @Default(.herokuAccount) private var herokuAccount
    @Default(.vercelTeamID) private var vercelTeamID
    @Default(.herokuApps) private var herokuApps
    @Default(.deployHiddenProjects) private var hidden
    @Default(.deployPinnedProjects) private var pinned
    @Default(.deployShowPreviews) private var showPreviews
    @Default(.deployWatchCI) private var watchCI
    @Default(.deployNotifyProductionStarted) private var prodStarted
    @Default(.deployNotifyProductionReady) private var prodReady
    @Default(.deployNotifyProductionFailed) private var prodFailed
    @Default(.deployNotifyPreviewReady) private var previewReady
    @Default(.deployNotifyPreviewFailed) private var previewFailed
    @Default(.deployNotifyMineReady) private var mineReady
    @Default(.deployNotifySlow) private var slow
    @Default(.deployToast) private var toast
    @Default(.deploySoundsEnabled) private var sounds
    @Default(.deploySoundSuccess) private var soundSuccess
    @Default(.deploySoundFailure) private var soundFailure
    @Default(.deploySoundStarted) private var soundStarted
    @Default(.deploySoundVolume) private var volume
    @Default(.deployQuietHours) private var quiet
    @Default(.deployQuietFrom) private var quietFrom
    @Default(.deployQuietTo) private var quietTo
    @Default(.deployIdleSeconds) private var idleSeconds
    @Default(.deployRelayURL) private var relayURL
    @Default(.deployAllowActions) private var allowActions

    @State private var vercelToken = ""
    @State private var teamDraft = ""
    @State private var herokuToken = ""
    @State private var appsDraft = ""
    @State private var busy: DeployProvider?
    @State private var failure: [DeployProvider: String] = [:]

    var body: some View {
        Form {
            providerSection(.vercel, account: vercelAccount, token: $vercelToken,
                            tokenPage: "https://vercel.com/account/tokens") {
                TextField("Team ID (optional)", text: $teamDraft, prompt: Text("team_…"))
            } connectedExtra: {
                LabeledContent("Team", value: vercelTeamID.isEmpty ? "Personal account" : vercelTeamID)
            }
            providerSection(.heroku, account: herokuAccount, token: $herokuToken,
                            tokenPage: "https://dashboard.heroku.com/account/applications") {
                EmptyView()
            } connectedExtra: {
                TextField("Apps (comma separated, empty = 8 most recent)", text: $appsDraft)
                    .onSubmit(saveApps)
            }

            if !monitor.knownProjects.isEmpty {
                Section("Projects") {
                    Toggle("Show preview deployments", isOn: $showPreviews)
                    Toggle("Watch GitHub Actions on each production branch", isOn: $watchCI)
                    ForEach(monitor.knownProjects, id: \.self) { key in
                        HStack {
                            Toggle(label(key), isOn: Binding(
                                get: { !hidden.contains(key) },
                                set: { on in if on { hidden.removeAll { $0 == key } } else { hidden.append(key) } }))
                            Spacer()
                            Button {
                                if pinned.contains(key) { pinned.removeAll { $0 == key } } else { pinned.append(key) }
                            } label: {
                                Image(systemName: pinned.contains(key) ? "pin.fill" : "pin")
                            }
                            .buttonStyle(.borderless)
                            .help("Pin to the production strip")
                        }
                    }
                }
            }

            Section("Notify me when") {
                Toggle("A production deployment starts", isOn: $prodStarted)
                Toggle("A production deployment is live", isOn: $prodReady)
                Toggle("A production deployment fails", isOn: $prodFailed)
                Toggle("A preview is ready", isOn: $previewReady)
                Toggle("A preview fails", isOn: $previewFailed)
                Toggle("A deployment of my commit is live", isOn: $mineReady)
                Toggle("A build takes over twice its usual time", isOn: $slow)
                Toggle("Show the box under the menu bar icon", isOn: $toast)
            }

            Section("Sounds") {
                Toggle("Play sounds", isOn: $sounds)
                soundPicker("Live", $soundSuccess)
                soundPicker("Failed", $soundFailure)
                soundPicker("Started", $soundStarted)
                Slider(value: $volume, in: 0...1) { Text("Volume") }
                Toggle("Quiet hours", isOn: $quiet)
                if quiet {
                    Stepper("From \(quietFrom):00", value: $quietFrom, in: 0...23)
                    Stepper("Until \(quietTo):00", value: $quietTo, in: 0...23)
                }
            }
            .disabled(!sounds)

            Section("Advanced") {
                Picker("Check when idle", selection: $idleSeconds) {
                    Text("With GitHub").tag(0)
                    Text("Every minute").tag(60)
                    Text("Every 2 minutes").tag(120)
                    Text("Every 10 minutes").tag(600)
                }
                Text("While something builds, Dev+ Bar checks every 15 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Webhook relay URL (optional)", text: $relayURL, prompt: Text("https://…"))
                Text("A relay you host turns Vercel and Heroku webhooks into instant updates. See Relay/README.md. Leave empty to only poll.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow Redeploy and Roll back from the panel", isOn: $allowActions)
                Text("Right-click a deployment card. Each action asks first; both change what is live.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { saveApps() }
        .onAppear {
            teamDraft = vercelTeamID
            appsDraft = herokuApps.joined(separator: ", ")
        }
    }

    @ViewBuilder
    private func providerSection<Extra: View, Connected: View>(
        _ provider: DeployProvider, account: String?, token: Binding<String>, tokenPage: String,
        @ViewBuilder extra: () -> Extra, @ViewBuilder connectedExtra: () -> Connected
    ) -> some View {
        Section(provider.title) {
            if let account, monitor.connected.contains(provider) {
                LabeledContent("Connected as", value: account)
                connectedExtra()
                if let error = monitor.errors[provider] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Button("Disconnect", role: .destructive) { monitor.disconnect(provider) }
            } else {
                SecureField("Token", text: token)
                extra()
                HStack {
                    Link("Create a token", destination: URL(string: tokenPage)!).font(.caption)
                    Spacer()
                    if busy == provider { ProgressView().controlSize(.small) }
                    Button("Connect") { connect(provider, token: token.wrappedValue) }
                        .disabled(token.wrappedValue.isEmpty || busy != nil)
                }
                if let message = failure[provider] {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Text("Stored in your Keychain and sent only to \(provider.title).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveApps() {
        let apps = appsDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if apps != herokuApps { herokuApps = apps }
    }

    private func connect(_ provider: DeployProvider, token: String) {
        busy = provider
        failure[provider] = nil
        Task {
            do {
                _ = try await monitor.connect(provider, token: token,
                                              teamID: provider == .vercel ? teamDraft.trimmingCharacters(in: .whitespaces) : "")
                if provider == .vercel { vercelToken = "" } else { herokuToken = "" }
            } catch {
                failure[provider] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = nil
        }
    }

    private func soundPicker(_ title: String, _ selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(DeploySound.choices, id: \.self) { Text($0).tag($0) }
            }
            Button { DeploySound.preview(selection.wrappedValue) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Play")
        }
    }

    private func label(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = DeployProvider(rawValue: parts[0]) else { return key }
        return "\(parts[1])  ·  \(provider.title)"
    }
}
