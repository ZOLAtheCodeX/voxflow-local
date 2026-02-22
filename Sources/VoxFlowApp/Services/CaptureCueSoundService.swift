import AppKit

final class CaptureCueSoundService {
    private let startSound = NSSound(named: NSSound.Name("Tink"))
    private let stopSound = NSSound(named: NSSound.Name("Basso"))

    func playStartCue() {
        play(startSound)
    }

    func playStopCue() {
        play(stopSound)
    }

    private func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
