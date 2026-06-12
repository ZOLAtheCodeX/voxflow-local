import Foundation
import os

/// R5.4 (experimental, off by default) — hand the current transcript to a
/// user-configured agent CLI (`claude -p`, `codex exec`, any command) and
/// return its stdout for review.
///
/// Security posture, by construction:
/// - The transcript travels via STDIN. It is NEVER interpolated into the
///   command line, so dictated text cannot inject shell syntax.
/// - This service never auto-executes anything: the UI contract requires a
///   visible payload preview + explicit user approval before each run, and
///   the result is only DISPLAYED — execution authority stays entirely with
///   the external agent's own permission model.
/// - Disabled unless the Settings ▸ Advanced toggle opts in.
@MainActor
final class AssistantHandoffService {

    enum HandoffError: Error, Equatable {
        case disabled
        case notConfigured
        case commandFailed(exitCode: Int32, stderr: String)
        case launchFailed(String)
        case timedOut
    }

    private let isEnabled: () -> Bool
    private let command: () -> String
    private let timeoutSeconds: TimeInterval
    private let log = Logger(subsystem: "local.voxflow.app", category: "AssistantHandoff")

    init(
        isEnabled: @escaping () -> Bool,
        command: @escaping () -> String,
        timeoutSeconds: TimeInterval = 120
    ) {
        self.isEnabled = isEnabled
        self.command = command
        self.timeoutSeconds = timeoutSeconds
    }

    func run(transcript: String) async -> Result<String, HandoffError> {
        guard isEnabled() else { return .failure(.disabled) }
        let commandLine = command().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else { return .failure(.notConfigured) }

        let timeout = timeoutSeconds
        return await Task.detached(priority: .userInitiated) { () -> Result<String, HandoffError> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -l so the user's PATH (homebrew etc.) resolves their CLI.
            process.arguments = ["-lc", commandLine]

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return .failure(.launchFailed(error.localizedDescription))
            }

            stdin.fileHandleForWriting.write(Data(transcript.utf8))
            try? stdin.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                return .failure(.timedOut)
            }

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                return .failure(.commandFailed(exitCode: process.terminationStatus, stderr: String(errText.prefix(500))))
            }
            return .success(output)
        }.value
    }
}
