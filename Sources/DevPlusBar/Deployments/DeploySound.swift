import AppKit
import Defaults

/// Sounds for deployment events. One sound per poll at most: the worst news wins.
@MainActor
enum DeploySound {
    /// macOS system sounds, so nothing has to be bundled or licensed.
    static let choices = ["None", "Glass", "Hero", "Ping", "Pop", "Purr", "Submarine", "Basso",
                          "Funk", "Sosumi", "Tink", "Blow", "Bottle", "Frog", "Morse"]

    static func name(for tone: DeployAlert.Tone) -> String {
        switch tone {
        case .success: Defaults[.deploySoundSuccess]
        case .failure: Defaults[.deploySoundFailure]
        case .started: Defaults[.deploySoundStarted]
        }
    }

    static var isQuietNow: Bool {
        guard Defaults[.deployQuietHours] else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let from = Defaults[.deployQuietFrom], to = Defaults[.deployQuietTo]
        return from <= to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }

    /// Plays the most important tone among `tones`, if sounds are on.
    static func play(_ tones: [DeployAlert.Tone]) {
        guard Defaults[.deploySoundsEnabled], !isQuietNow else { return }
        let order: [DeployAlert.Tone] = [.failure, .success, .started]
        guard let tone = order.first(where: tones.contains) else { return }
        preview(name(for: tone))
    }

    static func preview(_ name: String) {
        guard name != "None", let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = Float(Defaults[.deploySoundVolume])
        sound.play()
    }
}
