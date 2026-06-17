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

            // Drain stdout/stderr CONCURRENTLY with execution. Reading them only
            // after exit deadlocks any command whose output exceeds the ~64 KB OS
            // pipe buffer: the child blocks on its write forever, never exits, and
            // is killed at the timeout. readabilityHandler delivers chunks as they
            // arrive (off-thread) so the buffer never backs up; an empty chunk is
            // EOF (the child closed the pipe on exit/terminate).
            let outBox = DataBox(), errBox = DataBox()
            let readersDone = AtomicCounter()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; readersDone.increment() }
                else { outBox.append(chunk) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; readersDone.increment() }
                else { errBox.append(chunk) }
            }
            // After exit/terminate the pipes close and both handlers see EOF. Poll
            // (bounded) for that rather than DispatchGroup.wait, which is
            // unavailable in this async Task context.
            func awaitDrain() {
                let deadline = Date().addingTimeInterval(2)
                while readersDone.value < 2 && Date() < deadline { usleep(20_000) }
            }

            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                return .failure(.launchFailed(error.localizedDescription))
            }

            stdin.fileHandleForWriting.write(Data(transcript.utf8))
            try? stdin.fileHandleForWriting.close()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()   // closes the pipes → the readers hit EOF
                awaitDrain()
                return .failure(.timedOut)
            }

            // Process exited; wait for the readers to consume the final bytes.
            awaitDrain()
            let output = String(data: outBox.data, encoding: .utf8) ?? ""
            let errText = String(data: errBox.data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                return .failure(.commandFailed(exitCode: process.terminationStatus, stderr: String(errText.prefix(500))))
            }
            return .success(output)
        }.value
    }
}

/// Thread-safe accumulator for a pipe's bytes drained off the readability queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// Thread-safe counter for "how many pipe readers have hit EOF".
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
