import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "local.voxflow.app", category: "AppDelegate")
    private var pendingAutomationURLs: [URL] = []
    private var automationURLHandler: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register atexit as a last-resort fallback. If applicationWillTerminate
        // doesn't fire (e.g. SIGKILL, crash), this C-level handler still runs for
        // normal exit paths and sends SIGTERM to the backend via the PID file.
        atexit {
            BackendProcessManager.killStaleBackend()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("applicationWillTerminate — stopping backend")
        AppCoordinator.shared.shutdownBackend()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let automationURLHandler = self.automationURLHandler {
                urls.forEach(automationURLHandler)
            } else {
                self.pendingAutomationURLs.append(contentsOf: urls)
            }
        }
    }

    @MainActor
    func installAutomationURLHandler(_ handler: @escaping (URL) -> Void) {
        automationURLHandler = handler
        guard !pendingAutomationURLs.isEmpty else { return }
        let pending = pendingAutomationURLs
        pendingAutomationURLs.removeAll()
        pending.forEach(handler)
    }
}
