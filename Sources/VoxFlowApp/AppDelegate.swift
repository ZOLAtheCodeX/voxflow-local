import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "local.voxflow.app", category: "AppDelegate")

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
}
