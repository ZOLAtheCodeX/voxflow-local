import AppKit
import SwiftUI

/// Offscreen render harness for the UI refresh. Hosts a SwiftUI view in a
/// borderless window that is never ordered front, lets `onAppear` and `.task`
/// run, and writes a PNG per appearance. Tooling only, used by the opt-in
/// `UISnapshotExportTests` (skipped unless `VOXFLOW_UI_SNAPSHOTS` is set,
/// never run in CI): nothing here asserts, and it never touches the screen,
/// the installed app or the pasteboard. The `onAppear` and `.task` bodies it
/// runs are the views' own, so a view that queries permissions or probes the
/// loopback backend does so here too.
@MainActor
enum SnapshotRenderer {
    enum Failure: Error, CustomStringConvertible {
        case outputDirectoryNotAbsolute(String)
        case bitmapUnavailable(String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .outputDirectoryNotAbsolute(let path):
                return "VOXFLOW_UI_SNAPSHOTS must be an absolute path, got \"\(path)\""
            case .bitmapUnavailable(let name):
                return "No bitmap could be created for \(name)"
            case .encodingFailed(let name):
                return "PNG encoding failed for \(name)"
            }
        }
    }

    /// Seconds the main run loop is spun after layout, so `onAppear` and
    /// `.task` bodies run and their state changes reach the view.
    static let settleSeconds: TimeInterval = 0.4

    /// The directory named by `VOXFLOW_UI_SNAPSHOTS`, or nil when unset.
    static func outputDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] else { return nil }
        guard path.hasPrefix("/") else { throw Failure.outputDirectoryNotAbsolute(path) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Renders `view` at `size` once per appearance and writes
    /// `<VOXFLOW_UI_SNAPSHOTS>/<name>-light.png` or `-dark.png`.
    /// `prepare` runs once the view has laid out and settled, before the
    /// capture; it may poke the live NSView tree (for example to pick a
    /// segment of a segmented control that has no injection seam), after
    /// which the run loop is spun once more.
    /// With `fitHeight`, `size.height` is a minimum: a view whose content is
    /// taller at `size.width` (the menu bar palette is sized by its content in
    /// the app) is rendered at its full height instead of being clipped.
    static func export<V: View>(
        _ view: V,
        name: String,
        size requested: CGSize,
        appearances: [NSAppearance.Name] = [.aqua, .darkAqua],
        fitHeight: Bool = false,
        prepare: ((NSView) -> Void)? = nil
    ) throws {
        guard let directory = try outputDirectory() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var size = requested
        if fitHeight {
            let probe = NSHostingView(rootView: view.frame(width: requested.width))
            size.height = max(requested.height, probe.fittingSize.height.rounded(.up))
        }

        for appearanceName in appearances {
            let appearance = NSAppearance(named: appearanceName)
            let host = NSHostingView(rootView: backdropped(view, size: size))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = appearance

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            settle()
            if let prepare {
                prepare(host)
                host.layoutSubtreeIfNeeded()
                settle()
            }
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw Failure.bitmapUnavailable(name)
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw Failure.encodingFailed(name)
            }
            let suffix = appearanceName == .darkAqua ? "dark" : "light"
            try png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"), options: .atomic)

            window.contentView = nil
            window.close()
        }
    }

    /// Views meant for a translucent panel or pill (the menu bar palette, the
    /// recording pill) draw no opaque background of their own, so an offscreen
    /// render would show them on bare white and dark-mode text would vanish.
    /// A window-colored backdrop stands in for the surface they sit on; views
    /// with their own background are unaffected.
    private static func backdropped<V: View>(_ view: V, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(settleSeconds))
    }

    /// Depth-first search of an NSView tree.
    static func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstSubview(of: type, in: child) { return match }
        }
        return nil
    }
}
