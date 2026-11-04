import SwiftUI
import Defaults

/// The keyboard on the Deploys side, mirroring the GitHub side: arrows move, Return acts.
@MainActor
enum DeployKeys {
    static func handle(_ press: KeyPress, model: PanelModel, open: (String) -> Void) -> Bool {
        let state = model.deploys
        let monitor = DeployMonitor.shared
        let list = state.page == .activity ? state.shown(monitor) : []
        let current = list.first { $0.id == state.cursor }
        let command = press.modifiers.contains(.command)
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)

        switch press.key {
        case .leftArrow, .rightArrow:
            model.step(press.key == .rightArrow ? 1 : -1)
        case .tab:
            state.page = state.page == .activity ? .insights : .activity
        case .upArrow, .downArrow:
            guard !list.isEmpty else { return true }
            let ids = list.map(\.id)
            let index = state.cursor.flatMap(ids.firstIndex(of:))
            let down = press.key == .downArrow
            let next = switch (index, down) {
            case (nil, true): 0
            case (nil, false): ids.count - 1
            case (let i?, true): min(i + 1, ids.count - 1)
            case (let i?, false): max(i - 1, 0)
            }
            state.cursor = ids[next]
        case .return:
            guard let d = current else { return true }
            if command, let logs = d.dashboardURL {
                monitor.markSeen([d.id]); open(logs.absoluteString)
            } else if option, let site = d.url {
                monitor.markSeen([d.id]); open(site.absoluteString)
            } else {
                state.toggle(d.id)
            }
        default:
            guard command, let d = current else { return false }
            switch press.characters.lowercased() {
            case "c" where shift:
                DeployCommands.copyPrompt(d, state: state, monitor: monitor)
            case "c":
                guard let address = d.url?.absoluteString ?? d.dashboardURL?.absoluteString else { return true }
                DeployCommands.copy(address)
                state.say("URL copied", on: d.id)
            case "r" where shift:
                DeployCommands.redeploy(d, monitor: monitor)
            default:
                return false
            }
        }
        return true
    }
}
