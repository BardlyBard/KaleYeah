import Foundation
#if os(macOS)
import AppKit
#endif

/// Soft ascending muse/lyre chime for new mail — short, gentle, not harsh.
enum MuseNewMailSound {
    private static var cached: NSSound?

    static func play() {
#if os(macOS)
        if let cached {
            cached.stop()
            cached.currentTime = 0
            cached.play()
            return
        }
        let url =
            Bundle.main.url(forResource: "NewMail", withExtension: "aiff", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "NewMail", withExtension: "aiff")
        guard let url else {
            // Fallback: system "Purr" is softer than Glass/Funk if bundle asset missing.
            NSSound(named: NSSound.Name("Purr"))?.play()
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: false) else { return }
        sound.volume = 0.7
        cached = sound
        sound.play()
#endif
    }
}
