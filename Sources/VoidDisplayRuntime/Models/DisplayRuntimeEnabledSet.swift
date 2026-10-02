import Foundation

package nonisolated enum DisplayRuntimeEnabledSetError: Error, Equatable {
    case alreadyApplying
    case configurationUnavailable
    case missingConfiguration
    case stalePlan
}

package nonisolated struct DisplayRuntimeEnabledSetStep: Codable, Equatable, Sendable {
    package let configID: UUID
    package let enabled: Bool
}

nonisolated struct DisplayRuntimeEnabledSetConsumer: Equatable, Sendable {
    let id: DisplayRuntimeConsumerLeaseID
    let identity: DisplaySurfaceIdentity
    let displayID: DisplayRuntimeDisplayID?
    let epoch: DisplaySurfaceEpoch
}

package nonisolated struct DisplayRuntimeEnabledSetPlan: Sendable {
    package let operationID: DisplayRuntimeTransactionID
    package let targetConfigIDs: [UUID]
    package let previousConfigIDs: [UUID]
    package let steps: [DisplayRuntimeEnabledSetStep]
    package let interruptedConfigIDs: [UUID]
    let configs: [DisplayRuntimeVirtualDisplayConfig]
    let instances: [DisplayRuntimeManagedVirtualDisplay]
    let runningConfigIDs: [UUID]
    let consumers: [DisplayRuntimeEnabledSetConsumer]
}

package nonisolated struct DisplayRuntimeEnabledSetProgress: Codable, Equatable, Sendable {
    package let operationID: DisplayRuntimeTransactionID
    package var phase: DisplayRuntimeTransactionPhase
    package var completedStepCount: Int
    package let totalStepCount: Int
    package var currentConfigID: UUID?
    package var childTransactionIDs: [DisplayRuntimeTransactionID]
}

package nonisolated struct DisplayRuntimeEnabledSetStepResult: Codable, Equatable, Sendable {
    package let step: DisplayRuntimeEnabledSetStep
    package let result: DisplayRuntimeVirtualDisplayRebuildTransactionResult
}

package nonisolated struct DisplayRuntimeEnabledSetResult: Codable, Equatable, Sendable {
    package let operationID: DisplayRuntimeTransactionID
    package let status: DisplayRuntimeTransactionStatus
    package let previousConfigIDs: [UUID]
    package let targetConfigIDs: [UUID]
    package let steps: [DisplayRuntimeEnabledSetStepResult]
    package let skippedSteps: [DisplayRuntimeEnabledSetStep]
    package let finalState: DisplayRuntimeVirtualDisplaySnapshot
}
