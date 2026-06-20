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
        case cancelled
    }

    private let isEnabled: () -> Bool
    private let command: () -> String
    private let timeoutSeconds: TimeInterval
    private let maxOutputBytes: Int
    private let log = Logger(subsystem: "local.voxflow.app", category: "AssistantHandoff")

    init(
        isEnabled: @escaping () -> Bool,
        command: @escaping () -> String,
        timeoutSeconds: TimeInterval = 120,
        maxOutputBytes: Int = 2_000_000
    ) {
        self.isEnabled = isEnabled
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
    }

    func run(transcript: String) async -> Result<String, HandoffError> {
        guard isEnabled() else { return .failure(.disabled) }
        let commandLine = command().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else { return .failure(.notConfigured) }

        let timeout = timeoutSeconds
        let cap = maxOutputBytes
        // Caller cancellation: the heavy work runs in a detached Task that can't
        // observe the parent's cancellation directly, so onCancel flips a shared
        // flag the poll loop checks — and the child process is then terminated.
        let cancelBox = CancelBox()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> Result<String, HandoffError> in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // -l so the user's PATH (homebrew etc.) resolves their CLI.
                process.arguments = ["-lc", commandLine]

                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                // Drain stdout/stderr CONCURRENTLY with execution (reading after
                // exit would deadlock on output exceeding the ~64 KB pipe buffer),
                // and BOUND the capture so a chatty command can't grow memory.
                let outBox = DataBox(cap: cap), errBox = DataBox(cap: cap)
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
                var cancelled = false
                var timedOut = false
                while process.isRunning {
                    if cancelBox.isCancelled { cancelled = true; break }
                    if Date() >= deadline { timedOut = true; break }
                    usleep(100_000)
                }
                if cancelled || timedOut {
                    Self.terminate(process)   // SIGTERM → grace → SIGKILL
                    awaitDrain()
                    return .failure(cancelled ? .cancelled : .timedOut)
                }

                awaitDrain()
                let output = String(data: outBox.data, encoding: .utf8) ?? ""
                let errText = String(data: errBox.data, encoding: .utf8) ?? ""
                guard process.terminationStatus == 0 else {
                    return .failure(.commandFailed(exitCode: process.terminationStatus, stderr: String(errText.prefix(500))))
                }
                return .success(output)
            }.value
        } onCancel: {
            cancelBox.cancel()
        }
    }

    /// Stop a child cleanly: SIGTERM, a short grace period, then SIGKILL if it
    /// still hasn't exited — and only return once it's actually gone.
    nonisolated private static func terminate(_ process: Process) {
        process.terminate()   // SIGTERM
        let graceDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < graceDeadline { usleep(50_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline { usleep(50_000) }
        }
    }
}

/// Thread-safe, size-bounded accumulator for a pipe's bytes drained off the
/// readability queue. Caps total bytes so a chatty command can't grow memory
/// without limit; excess is dropped (truncated).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let cap: Int
    private(set) var truncated = false

    init(cap: Int) { self.cap = cap }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard bytes.count < cap else { truncated = true; return }
        let room = cap - bytes.count
        if data.count <= room {
            bytes.append(data)
        } else {
            bytes.append(data.prefix(room))
            truncated = true
        }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// Thread-safe one-way cancellation flag bridging the task-cancellation handler
/// (which can't touch the detached work directly) to the process poll loop.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Thread-safe counter for "how many pipe readers have hit EOF".
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
