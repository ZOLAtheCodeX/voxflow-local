import Foundation
import os.log

private let log = Logger(subsystem: "local.voxflow.app", category: "BackendProcessManager")

struct BackendLaunchConfiguration: Equatable {
    let sttBackend: String
    let sttModel: String
    let whisperModel: String
    let voxtralSafeModeEnabled: Bool
    let translateModel: String
    let translateBackend: String
    let privateAPIBaseURL: String
    let privateAPIModel: String
    let privateAPIKey: String
    let openAIBaseURL: String
    let openAIAPIKey: String
    let openAISTTModel: String
    let openAITTSModel: String
    let openAITTSVoice: String
}

final class BackendProcessManager {
    private struct PythonInvocation {
        let executableURL: URL
        let arguments: [String]
    }

    private var process: Process?
    private var activeConfiguration: BackendLaunchConfiguration?

    var isRunning: Bool {
        process?.isRunning == true
    }

    func startIfNeeded(configuration: BackendLaunchConfiguration) {
        if process?.isRunning == true {
            if activeConfiguration == configuration {
                return
            }
            stop()
        }

        let backendPath = resolveBackendPath()
        guard FileManager.default.fileExists(atPath: backendPath) else {
            return
        }

        let invocation = resolvePythonInvocation(forBackendPath: backendPath)
        let task = Process()
        task.executableURL = invocation.executableURL
        task.arguments = invocation.arguments
        task.environment = mergedEnvironment(configuration: configuration)
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            process = task
            activeConfiguration = configuration
            log.info("Backend started (pid: \(task.processIdentifier))")
        } catch {
            log.error("Failed to start backend: \(error.localizedDescription)")
            process = nil
            activeConfiguration = nil
        }
    }

    func restart(configuration: BackendLaunchConfiguration) {
        stop()
        startIfNeeded(configuration: configuration)
    }

    func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            activeConfiguration = nil
            return
        }

        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }

        if process.isRunning {
            process.interrupt()
        }

        self.process = nil
        activeConfiguration = nil
    }

    private func resolveBackendPath() -> String {
        if let explicit = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_PATH"], !explicit.isEmpty {
            return explicit
        }

        if let bundledBackend = Bundle.main.resourceURL?
            .appendingPathComponent("backend/app/server.py")
            .path,
           FileManager.default.fileExists(atPath: bundledBackend) {
            return bundledBackend
        }

        if let projectRoot = ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"], !projectRoot.isEmpty {
            let path = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent("backend/app/server.py")
                .path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let currentDirectory = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: currentDirectory)
            .appendingPathComponent("backend/app/server.py")
            .path
    }

    private func resolvePythonInvocation(forBackendPath backendPath: String) -> PythonInvocation {
        if let explicitPython = ProcessInfo.processInfo.environment["VOXFLOW_PYTHON_PATH"], !explicitPython.isEmpty {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: explicitPython),
                arguments: [backendPath]
            )
        }

        if let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("venv/bin/python3")
            .path,
           FileManager.default.fileExists(atPath: bundledPython) {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: bundledPython),
                arguments: [backendPath]
            )
        }

        if let projectRoot = ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"], !projectRoot.isEmpty {
            let projectPython = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent(".venv/bin/python3")
                .path
            if FileManager.default.fileExists(atPath: projectPython) {
                return PythonInvocation(
                    executableURL: URL(fileURLWithPath: projectPython),
                    arguments: [backendPath]
                )
            }
        }

        let currentDirectoryPython = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".venv/bin/python3")
            .path
        if FileManager.default.fileExists(atPath: currentDirectoryPython) {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: currentDirectoryPython),
                arguments: [backendPath]
            )
        }

        return PythonInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", backendPath]
        )
    }

    private func mergedEnvironment(configuration: BackendLaunchConfiguration) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? "",
            "TMPDIR": inherited["TMPDIR"] ?? "/tmp",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
        ]
        if let modelsDir = inherited["VOXFLOW_MODELS_DIR"] {
            environment["VOXFLOW_MODELS_DIR"] = modelsDir
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPYCACHEPREFIX"] = "/tmp/voxflow-pycache"
        environment["VOXFLOW_OFFLINE"] = "1"
        environment["VOXFLOW_STT_BACKEND"] = configuration.sttBackend
        environment["VOXFLOW_STT_MODEL"] = configuration.sttModel
        environment["VOXFLOW_WHISPER_MODEL"] = configuration.whisperModel
        environment["VOXFLOW_STT_ALLOW_FALLBACK"] = environment["VOXFLOW_STT_ALLOW_FALLBACK"] ?? "1"
        environment["VOXFLOW_VOXTRAL_SKIP_PRIMARY"] = configuration.voxtralSafeModeEnabled ? "1" : "0"
        environment["VOXFLOW_TRANSLATE_MODEL"] = configuration.translateModel
        environment["VOXFLOW_TRANSLATE_BACKEND"] = configuration.translateBackend
        environment["VOXFLOW_PRIVACY_POLICY_VERSION"] = "2026-02"
        environment["VOXFLOW_PRIVACY_REQUIRE_CONSENT"] = "1"
        environment["VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED"] = "1"
        environment["VOXFLOW_PRIVATE_API_BASE_URL"] = configuration.privateAPIBaseURL
        environment["VOXFLOW_PRIVATE_API_MODEL"] = configuration.privateAPIModel
        environment["VOXFLOW_PRIVATE_API_KEY"] = configuration.privateAPIKey
        environment["VOXFLOW_OPENAI_BASE_URL"] = configuration.openAIBaseURL
        environment["VOXFLOW_OPENAI_API_KEY"] = configuration.openAIAPIKey
        environment["VOXFLOW_OPENAI_STT_MODEL"] = configuration.openAISTTModel
        environment["VOXFLOW_OPENAI_TTS_MODEL"] = configuration.openAITTSModel
        environment["VOXFLOW_OPENAI_TTS_VOICE"] = configuration.openAITTSVoice
        return environment
    }
}
