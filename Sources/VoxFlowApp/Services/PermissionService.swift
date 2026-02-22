import AVFoundation
import AppKit
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
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func microphoneStatus() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
