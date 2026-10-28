import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct PreparedComputerAction: Decodable, Equatable, Sendable {
    let version: Int
    let id: String
    let operation: ComputerAction.Operation
    let argument: String

    func validates(_ action: ComputerAction) -> Bool {
        version == 1 && id == action.id && operation == action.operation && argument == action.argument && action.isSupported
    }
}

protocol ComputerActionPreparing: Sendable {
    func prepare(_ action: ComputerAction) async throws -> PreparedComputerAction
}

/// A separate actor keeps process and pipe work off the UI actor. Python runs
/// isolated, with site imports disabled, and can only prepare a registered action.
actor PythonComputerActionPreparer: ComputerActionPreparing {
    func prepare(_ action: ComputerAction) async throws -> PreparedComputerAction {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = try ComputerActionResources.pythonURL()
        process.arguments = ["-I", "-S", try ComputerActionResources.scriptURL().path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "action_id": action.id])
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ComputerActionError.preparationFailed }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, data.count <= 4096,
              let result = try? JSONDecoder().decode(PreparedComputerAction.self, from: data),
              result.validates(action) else { throw ComputerActionError.preparationFailed }
        return result
    }
}

enum ComputerActionOutcome: String, Sendable {
    case applicationOpened, keyPosted
    var label: String {
        switch self {
        case .applicationOpened: "application opened"
        case .keyPosted: "shortcut sent"
        }
    }
}

@MainActor
protocol ComputerActionPerforming {
    func perform(_ action: PreparedComputerAction, permissions: CapturedVoiceActions, target: NSRunningApplication?,
                 focus: CapturedInsertionFocus?) async throws -> ComputerActionOutcome
}

@MainActor
final class NativeComputerActionBridge: ComputerActionPerforming {
    struct Shortcut: Equatable {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    static func shortcut(_ name: String) -> Shortcut? {
        switch name {
        case "copy": Shortcut(code: 8, flags: .maskCommand)
        case "paste": Shortcut(code: 9, flags: .maskCommand)
        case "selectAll": Shortcut(code: 0, flags: .maskCommand)
        case "undo": Shortcut(code: 6, flags: .maskCommand)
        case "redo": Shortcut(code: 6, flags: [.maskCommand, .maskShift])
        case "find": Shortcut(code: 3, flags: .maskCommand)
        case "newTab": Shortcut(code: 17, flags: .maskCommand)
        default: nil
        }
    }

    func perform(_ action: PreparedComputerAction, permissions: CapturedVoiceActions, target: NSRunningApplication?,
                 focus: CapturedInsertionFocus?) async throws -> ComputerActionOutcome {
        try Task.checkCancellation()
        guard !permissions.revoked, permissions.mode.includesComputerActions,
              permissions.enabledIDs.contains(action.id) else { throw CancellationError() }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session != nil, session?["CGSSessionScreenIsLocked"] as? Bool != true,
              !IsSecureEventInputEnabled() else { throw ComputerActionError.targetChanged }
        switch action.operation {
        case .openApplication:
            guard ComputerAction.applications.contains(action.argument),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.argument) else {
                throw ComputerActionError.unavailable
            }
            // LaunchServices addresses the explicit destination. Once dispatched,
            // report its result without automatically retrying a possible effect.
            return try await withCheckedThrowingContinuation { continuation in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if app != nil { continuation.resume(returning: .applicationOpened) }
                    else { continuation.resume(throwing: ComputerActionError.unavailable) }
                }
            }
        case .shortcut:
            guard let key = Self.shortcut(action.argument), let target,
                  !target.isTerminated, target.isActive,
                  focus?.matchesForAction(targetPID: target.processIdentifier) == true else {
                throw ComputerActionError.targetChanged
            }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { throw ComputerActionError.unavailable }
            // Use ordinary untagged events: these actions should invalidate the
            // previous dictation's smart-spacing boundary, just like user input.
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else {
                throw ComputerActionError.unavailable
            }
            down.flags = key.flags
            up.flags = key.flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return .keyPosted
        }
    }
}

@MainActor
final class ComputerActionService {
    private let preparer: any ComputerActionPreparing
    private let bridge: any ComputerActionPerforming

    init(preparer: any ComputerActionPreparing, bridge: any ComputerActionPerforming) {
        self.preparer = preparer
        self.bridge = bridge
    }

    func execute(_ action: ComputerAction, permissions: CapturedVoiceActions,
                 target: NSRunningApplication?, focus: CapturedInsertionFocus?) async throws -> ComputerActionOutcome {
        try checkPermission(action, permissions: permissions)
        let prepared = try await preparer.prepare(action)
        try checkPermission(action, permissions: permissions)
        guard prepared.validates(action) else { throw ComputerActionError.preparationFailed }
        // No suspension between this last permission check and entering the
        // MainActor bridge, whose effect has its own focus/cancellation gate.
        return try await bridge.perform(prepared, permissions: permissions, target: target, focus: focus)
    }

    private func checkPermission(_ action: ComputerAction, permissions: CapturedVoiceActions) throws {
        try Task.checkCancellation()
        guard !permissions.revoked, permissions.mode.includesComputerActions,
              permissions.enabledIDs.contains(action.id) else { throw CancellationError() }
    }
}
