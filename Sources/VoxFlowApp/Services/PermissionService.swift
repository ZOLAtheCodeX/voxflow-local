import AVFoundation
@preconcurrency import ApplicationServices
import Foundation

struct PermissionSnapshot {
    let microphoneAuthorized: Bool
    let accessibilityAuthorized: Bool
}

final class PermissionService {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphoneAuthorized: microphoneStatus(),
            accessibilityAuthorized: AXIsProcessTrusted()
        )
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func promptAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func microphoneStatus() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
