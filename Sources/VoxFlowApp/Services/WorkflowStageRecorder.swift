import Foundation

typealias WorkflowStageRecorder = @MainActor (
    _ name: String,
    _ startedAt: ContinuousClock.Instant,
    _ detail: String?
) -> Void
