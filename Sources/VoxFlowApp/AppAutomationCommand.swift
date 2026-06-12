import Foundation

enum AutomationWindowTarget: String, Equatable {
    case main
    case dashboard
    case setup
    case settings
    case cockpit
}

enum AutomationBackendAction: String, Equatable {
    case start
    case stop
    case recheck
}

enum AppAutomationCommand: Equatable {
    case openWindow(AutomationWindowTarget)
    case selectWorkflow(WorkflowMode, enableIfNeeded: Bool)
    case backend(AutomationBackendAction)

    init(url: URL) throws {
        guard url.scheme?.lowercased() == "voxflow" else {
            throw AutomationURLParseError.unsupportedScheme(url.scheme ?? "")
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? "").lowercased()
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        guard !host.isEmpty else {
            throw AutomationURLParseError.missingCommandGroup
        }
        guard pathComponents.count == 1, let rawTarget = pathComponents.first?.lowercased() else {
            throw AutomationURLParseError.missingCommandTarget(group: host)
        }

        switch host {
        case "window":
            guard let target = AutomationWindowTarget(rawValue: rawTarget) else {
                throw AutomationURLParseError.unknownTarget(group: host, target: rawTarget)
            }
            self = .openWindow(target)
        case "workflow":
            guard let mode = WorkflowMode(automationSlug: rawTarget) else {
                throw AutomationURLParseError.unknownTarget(group: host, target: rawTarget)
            }
            let enableIfNeeded = Self.boolQueryValue(named: "enable", components: components) ?? false
            self = .selectWorkflow(mode, enableIfNeeded: enableIfNeeded)
        case "backend":
            guard let action = AutomationBackendAction(rawValue: rawTarget) else {
                throw AutomationURLParseError.unknownTarget(group: host, target: rawTarget)
            }
            self = .backend(action)
        default:
            throw AutomationURLParseError.unknownCommandGroup(host)
        }
    }

    private static func boolQueryValue(named name: String, components: URLComponents?) -> Bool? {
        guard let rawValue = components?.queryItems?.first(where: { $0.name == name })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty
        else {
            return nil
        }

        switch rawValue {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

enum AutomationURLParseError: LocalizedError {
    case unsupportedScheme(String)
    case missingCommandGroup
    case unknownCommandGroup(String)
    case missingCommandTarget(group: String)
    case unknownTarget(group: String, target: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme):
            return "Unsupported automation URL scheme: \(scheme)"
        case .missingCommandGroup:
            return "Automation URL is missing a command group"
        case .unknownCommandGroup(let group):
            return "Unknown automation command group: \(group)"
        case .missingCommandTarget(let group):
            return "Automation URL is missing a target for \(group)"
        case .unknownTarget(let group, let target):
            return "Unknown automation target '\(target)' for \(group)"
        }
    }
}

extension WorkflowMode {
    init?(automationSlug: String) {
        switch automationSlug {
        case "dictation":
            self = .dictation
        case "translate", "translate-en-de", "translateentode":
            self = .translateEnToDe
        case "meeting":
            self = .meeting
        case "prompt":
            self = .prompt
        default:
            return nil
        }
    }
}
