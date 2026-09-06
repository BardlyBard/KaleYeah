import Foundation

/// Launch open-sequence preference + one-shot "has seen" gate.
enum OpenSequenceController {
    static let hasSeenKey = "rapSoDee.hasSeenOpenSequence"
    static let playOnLaunchKey = "rapSoDee.playOpenSequenceOnLaunch"

    /// Bundled movie URL, if present.
    static var videoURL: URL? {
        Bundle.main.url(forResource: "OpenSequence", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "OpenSequence", withExtension: "mp4", subdirectory: "Resources")
    }

    /// Play when the movie exists and either the user hasn't seen it yet, or Settings re-enabled it.
    static var shouldPlayOnLaunch: Bool {
        guard videoURL != nil else { return false }
        if UserDefaults.standard.bool(forKey: playOnLaunchKey) { return true }
        return !UserDefaults.standard.bool(forKey: hasSeenKey)
    }

    static var playOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: playOnLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: playOnLaunchKey) }
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: hasSeenKey)
    }

    /// Force next launch (or immediate preview) without flipping the every-launch toggle.
    static func resetSeenForReplay() {
        UserDefaults.standard.set(false, forKey: hasSeenKey)
    }
}
