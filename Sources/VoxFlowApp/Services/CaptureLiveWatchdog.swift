import Foundation

/// Watches the gap between `engine.start()` returning and the first audio
/// buffer actually arriving. The "speak now" cue is gated on that first
/// buffer, so an input device that starts but never delivers (wedged
/// CoreAudio, zero-input aggregate device, device yanked mid-start) would
/// otherwise leave the user waiting in silence with recording armed until
/// the multi-minute capture timeout. The watchdog turns that silent hang
/// into a prompt, surfaced failure.
@MainActor
final class CaptureLiveWatchdog {
    private var countdown: Task<Void, Never>?

    /// Arms the watchdog: `onStalled` runs on the main actor after `timeout`
    /// seconds unless ``markLive()`` or ``cancel()`` disarms it first.
    /// Re-arming replaces any previous countdown.
    func arm(timeout: TimeInterval, onStalled: @escaping @MainActor () -> Void) {
        countdown?.cancel()
        countdown = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onStalled()
        }
    }

    /// The first buffer arrived — the capture is genuinely live.
    func markLive() {
        cancel()
    }

    func cancel() {
        countdown?.cancel()
        countdown = nil
    }
}
