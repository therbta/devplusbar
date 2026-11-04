import Foundation
import Defaults

extension Defaults.Keys {
    /// Vercel team id ("team_…"); empty = personal account.
    static let vercelTeamID = Key<String>("vercelTeamID", default: "")
    /// Who each provider's token belongs to, shown in Settings. nil = not connected.
    static let vercelAccount = Key<String?>("vercelAccount", default: nil)
    static let herokuAccount = Key<String?>("herokuAccount", default: nil)
    /// Watched Heroku apps; empty = the most recently updated ones.
    static let herokuApps = Key<[String]>("herokuApps", default: [])
    /// Projects/apps the user hid, as "provider:name".
    static let deployHiddenProjects = Key<[String]>("deployHiddenProjects", default: [])
    /// Projects pinned to the header strip, as "provider:name".
    static let deployPinnedProjects = Key<[String]>("deployPinnedProjects", default: [])
    static let deployShowPreviews = Key<Bool>("deployShowPreviews", default: true)
    /// Seconds between polls while nothing builds; 0 = the GitHub refresh interval.
    static let deployIdleSeconds = Key<Int>("deployIdleSeconds", default: 0)
    /// Deployments opened or marked seen, by id.
    static let deploySeen = Key<[String]>("deploySeen", default: [])

    static let deployNotifyProductionStarted = Key<Bool>("deployNotifyProductionStarted", default: false)
    static let deployNotifyProductionReady = Key<Bool>("deployNotifyProductionReady", default: true)
    static let deployNotifyProductionFailed = Key<Bool>("deployNotifyProductionFailed", default: true)
    static let deployNotifyPreviewReady = Key<Bool>("deployNotifyPreviewReady", default: false)
    static let deployNotifyPreviewFailed = Key<Bool>("deployNotifyPreviewFailed", default: true)
    static let deployNotifyMineReady = Key<Bool>("deployNotifyMineReady", default: true)
    static let deployNotifySlow = Key<Bool>("deployNotifySlow", default: true)
    static let deployToast = Key<Bool>("deployToast", default: true)

    static let deploySoundsEnabled = Key<Bool>("deploySoundsEnabled", default: true)
    static let deploySoundSuccess = Key<String>("deploySoundSuccess", default: "Glass")
    static let deploySoundFailure = Key<String>("deploySoundFailure", default: "Basso")
    static let deploySoundStarted = Key<String>("deploySoundStarted", default: "Tink")
    static let deploySoundVolume = Key<Double>("deploySoundVolume", default: 0.7)
    static let deployQuietHours = Key<Bool>("deployQuietHours", default: false)
    static let deployQuietFrom = Key<Int>("deployQuietFrom", default: 22)
    static let deployQuietTo = Key<Int>("deployQuietTo", default: 8)

    /// Watch GitHub Actions on each project's production branch.
    static let deployWatchCI = Key<Bool>("deployWatchCI", default: true)
    /// GitHub repository of each project, "provider:name" -> "owner/repo"; found by commit search
    /// for Heroku apps, whose API does not say.
    static let deployRepoMap = Key<[String: String]>("deployRepoMap", default: [:])
    /// Optional webhook relay (Relay/README.md). Empty = polling only.
    static let deployRelayURL = Key<String>("deployRelayURL", default: "")
    /// Shows Redeploy / Roll back in the card menu. Off by default: they change production.
    static let deployAllowActions = Key<Bool>("deployAllowActions", default: false)
}

extension DeployAlertRules {
    static func fromDefaults() -> DeployAlertRules {
        DeployAlertRules(
            productionStarted: Defaults[.deployNotifyProductionStarted],
            productionReady: Defaults[.deployNotifyProductionReady],
            productionFailed: Defaults[.deployNotifyProductionFailed],
            previewReady: Defaults[.deployNotifyPreviewReady],
            previewFailed: Defaults[.deployNotifyPreviewFailed],
            toastPreviews: Defaults[.deployShowPreviews],
            mineReady: Defaults[.deployNotifyMineReady],
            slowBuilds: Defaults[.deployNotifySlow],
            sounds: Defaults[.deploySoundsEnabled]
        )
    }
}
