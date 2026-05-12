import CryptoKit
import Foundation

package nonisolated struct DisplayRuntimeTransactionID: Codable, Equatable, Hashable, Sendable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package nonisolated enum DisplayRuntimeTransactionKind: String, Codable, Equatable, Hashable, Sendable {
    case virtualDisplayRebuild
    case virtualDisplayEnable
    case virtualDisplayDisable
    case virtualDisplayEditRebuild
}

package nonisolated enum DisplayRuntimeTransactionSource: String, Codable, Equatable, Sendable {
    case virtualDisplayRowRetry
    case virtualDisplayRowToggle
    case editSaveAndRebuild
    case diagnostics
    case unknown
}

package nonisolated enum DisplayRuntimeTransactionPhase: String, Codable, Equatable, Sendable {
    case queued
    case preparing
    case persistingConfig
    case compensatingPersistence
    case quiescingSessions
    case executingVirtualDisplayCommand
    case waitingForTopology
    case restoringSessions
    case completed
    case failed
    case cancelled
}

package nonisolated enum DisplayRuntimeTransactionStatus: String, Codable, Equatable, Sendable {
    case active
    case completed
    case completedWithRecoveryFailures
    case failed
    case cancelled
}

package nonisolated struct DisplayRuntimeTransactionPhaseRecord: Codable, Equatable, Sendable {
    package let phase: DisplayRuntimeTransactionPhase
    package let note: String?

    package init(phase: DisplayRuntimeTransactionPhase, note: String? = nil) {
        self.phase = phase
        self.note = note
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let source: DisplayRuntimeTransactionSource

    package init(
        transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
        configID: UUID,
        source: DisplayRuntimeTransactionSource
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.source = source
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayModeDTO: Codable, Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let refreshRate: Double
    package let enableHiDPI: Bool

    package init(width: Int, height: Int, refreshRate: Double, enableHiDPI: Bool) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.enableHiDPI = enableHiDPI
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayConfigEditDTO: Codable, Equatable, Sendable {
    package let id: UUID
    package let displayName: String
    package let serialNumber: UInt32
    package let desiredEnabled: Bool
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let modes: [DisplayRuntimeVirtualDisplayModeDTO]
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32

    package init(
        id: UUID,
        displayName: String,
        serialNumber: UInt32,
        desiredEnabled: Bool,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        modes: [DisplayRuntimeVirtualDisplayModeDTO],
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32
    ) {
        self.id = id
        self.displayName = displayName
        self.serialNumber = serialNumber
        self.desiredEnabled = desiredEnabled
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.modes = modes
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
    }

    package var fingerprint: String {
        Self.fingerprint(for: self)
    }

    package static func fingerprint(for config: Self) -> String {
        let canonical = [
            "v1",
            "id=\(config.id.uuidString.lowercased())",
            "displayName=\(lengthPrefixed(config.displayName))",
            "serialNumber=\(config.serialNumber)",
            "desiredEnabled=\(config.desiredEnabled ? 1 : 0)",
            "physicalWidthMillimeters=\(config.physicalWidthMillimeters)",
            "physicalHeightMillimeters=\(config.physicalHeightMillimeters)",
            "maximumPixelWidth=\(config.maximumPixelWidth)",
            "maximumPixelHeight=\(config.maximumPixelHeight)",
            "modes=\(config.modes.map(modeFingerprintComponent).joined(separator: ";"))"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func modeFingerprintComponent(_ mode: DisplayRuntimeVirtualDisplayModeDTO) -> String {
        [
            "\(mode.width)",
            "\(mode.height)",
            "\(mode.refreshRate.bitPattern)",
            mode.enableHiDPI ? "1" : "0"
        ].joined(separator: ",")
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayConfigEvidence: Codable, Equatable, Sendable {
    package let id: UUID
    package let serialNumber: UInt32
    package let desiredEnabled: Bool
    package let physicalWidthMillimeters: UInt32
    package let physicalHeightMillimeters: UInt32
    package let modeCount: Int
    package let maximumPixelWidth: UInt32
    package let maximumPixelHeight: UInt32

    package init(
        id: UUID,
        serialNumber: UInt32,
        desiredEnabled: Bool,
        physicalWidthMillimeters: UInt32,
        physicalHeightMillimeters: UInt32,
        modeCount: Int,
        maximumPixelWidth: UInt32,
        maximumPixelHeight: UInt32
    ) {
        self.id = id
        self.serialNumber = serialNumber
        self.desiredEnabled = desiredEnabled
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.modeCount = modeCount
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
    }

    package init(config: DisplayRuntimeVirtualDisplayConfigEditDTO) {
        self.init(
            id: config.id,
            serialNumber: config.serialNumber,
            desiredEnabled: config.desiredEnabled,
            physicalWidthMillimeters: config.physicalWidthMillimeters,
            physicalHeightMillimeters: config.physicalHeightMillimeters,
            modeCount: config.modes.count,
            maximumPixelWidth: config.maximumPixelWidth,
            maximumPixelHeight: config.maximumPixelHeight
        )
    }

    package init(snapshotConfig: DisplayRuntimeVirtualDisplayConfig) {
        let maximumPixelDimensions = snapshotConfig.maximumPixelDimensions
        self.init(
            id: snapshotConfig.id,
            serialNumber: snapshotConfig.serialNumber,
            desiredEnabled: snapshotConfig.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: snapshotConfig.physicalWidthMillimeters),
            physicalHeightMillimeters: UInt32(clamping: snapshotConfig.physicalHeightMillimeters),
            modeCount: snapshotConfig.modes.count,
            maximumPixelWidth: maximumPixelDimensions.width,
            maximumPixelHeight: maximumPixelDimensions.height
        )
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayEditRebuildRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO
    package let expectedConfigFingerprint: String
    package let source: DisplayRuntimeTransactionSource

    package init(
        transactionID: DisplayRuntimeTransactionID = DisplayRuntimeTransactionID(),
        editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO,
        expectedConfigFingerprint: String,
        source: DisplayRuntimeTransactionSource
    ) {
        self.transactionID = transactionID
        self.editedConfig = editedConfig
        self.expectedConfigFingerprint = expectedConfigFingerprint
        self.source = source
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let configID: UUID
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence

    package init(
        transactionID: DisplayRuntimeTransactionID,
        configID: UUID,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence
    ) {
        self.transactionID = transactionID
        self.configID = configID
        self.persistenceOutcome = persistenceOutcome
        self.savedConfigEvidence = savedConfigEvidence
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO
    package let savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence

    package init(
        configID: UUID,
        persistenceOutcome: DisplayRuntimePersistenceOutcome,
        previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence
    ) {
        self.configID = configID
        self.persistenceOutcome = persistenceOutcome
        self.previousConfigForCompensation = previousConfigForCompensation
        self.savedConfigEvidence = savedConfigEvidence
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO

    package init(
        transactionID: DisplayRuntimeTransactionID,
        previousConfigForCompensation: DisplayRuntimeVirtualDisplayConfigEditDTO
    ) {
        self.transactionID = transactionID
        self.previousConfigForCompensation = previousConfigForCompensation
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayPersistenceCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome

    package init(configID: UUID, persistenceOutcome: DisplayRuntimePersistenceOutcome) {
        self.configID = configID
        self.persistenceOutcome = persistenceOutcome
    }
}

package nonisolated enum DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError: Error, Equatable, Sendable {
    case editRequestStale
}

package nonisolated struct DisplayRuntimeVirtualDisplayEditRebuildFailure: LocalizedError, Equatable, Sendable {
    package let reason: String

    package init(reason: String) {
        self.reason = reason
    }

    package var errorDescription: String? {
        nil
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildTransactionResult: Codable, Equatable, Sendable {
    package let transactionID: DisplayRuntimeTransactionID
    package let kind: DisplayRuntimeTransactionKind
    package let status: DisplayRuntimeTransactionStatus
    package let virtualDisplayCommandSucceeded: Bool
    package let hasSessionRecoveryFailures: Bool
    package let desiredEnabled: Bool?

    package init(
        transactionID: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind = .virtualDisplayRebuild,
        status: DisplayRuntimeTransactionStatus,
        virtualDisplayCommandSucceeded: Bool,
        hasSessionRecoveryFailures: Bool,
        desiredEnabled: Bool? = nil
    ) {
        self.transactionID = transactionID
        self.kind = kind
        self.status = status
        self.virtualDisplayCommandSucceeded = virtualDisplayCommandSucceeded
        self.hasSessionRecoveryFailures = hasSessionRecoveryFailures
        self.desiredEnabled = desiredEnabled
    }
}

@MainActor
package final class DisplayRuntimeAsyncGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    package init() {}

    package func wait() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    package func succeed(_ value: Value) {
        complete(.success(value))
    }

    package func fail(_ error: any Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Value, any Error>) {
        guard self.result == nil else { return }
        let completion = result
        self.result = completion
        continuation?.resume(with: completion)
        continuation = nil
    }
}

@MainActor
package struct DisplayRuntimeVirtualDisplayEditRebuildTransactionHandle {
    package let transactionID: DisplayRuntimeTransactionID
    private let saveGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>
    private let terminalResultGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayRebuildTransactionResult>

    package init(
        transactionID: DisplayRuntimeTransactionID,
        saveGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult>,
        terminalResultGate: DisplayRuntimeAsyncGate<DisplayRuntimeVirtualDisplayRebuildTransactionResult>
    ) {
        self.transactionID = transactionID
        self.saveGate = saveGate
        self.terminalResultGate = terminalResultGate
    }

    package func waitForSaveGate() async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveGateResult {
        try await saveGate.wait()
    }

    package func waitForTerminalResult() async throws -> DisplayRuntimeVirtualDisplayRebuildTransactionResult {
        try await terminalResultGate.wait()
    }
}

package nonisolated enum DisplayRuntimeAffectedSurfaceReason: String, Codable, Equatable, Sendable {
    case requestedConfig
    case managedMainFleetPeer
    case enableFleetRiskPeer
}

package nonisolated enum DisplayRuntimeScopeEscalationReason: String, Codable, Equatable, Sendable {
    case targetDisabled
    case managedMainPolicyRisk
    case enableMayPerformFleetRebuild
    case scopeEscalatedEnableMayPerformFleetRebuild
}

package nonisolated enum DisplayRuntimePersistenceOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case saved
    case failed
    case rolledBack
    case rollbackFailed
}

package nonisolated enum DisplayRuntimeVirtualDisplayCommandOutcome: String, Codable, Equatable, Sendable {
    case notAttempted
    case succeeded
    case failed
    case invalidated
    case partiallySucceeded
}

package nonisolated struct DisplayRuntimeAffectedSurface: Codable, Equatable, Sendable {
    package let identity: DisplaySurfaceIdentity
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let serialNumber: UInt32?
    package let reason: DisplayRuntimeAffectedSurfaceReason

    package init(
        identity: DisplaySurfaceIdentity,
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        serialNumber: UInt32?,
        reason: DisplayRuntimeAffectedSurfaceReason
    ) {
        self.identity = identity
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.serialNumber = serialNumber
        self.reason = reason
    }
}

package nonisolated struct DisplayRuntimeSessionPauseIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let displayID: DisplayRuntimeDisplayID
    package let pauseSharing: Bool
    package let pauseMonitoring: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        displayID: DisplayRuntimeDisplayID,
        pauseSharing: Bool,
        pauseMonitoring: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.displayID = displayID
        self.pauseSharing = pauseSharing
        self.pauseMonitoring = pauseMonitoring
    }
}

package nonisolated struct DisplayRuntimeSessionRestoreIntent: Codable, Equatable, Sendable {
    package let surfaceIdentity: DisplaySurfaceIdentity
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let restoreSharing: Bool
    package let restoreMonitoring: Bool
    package let monitoringCapturesCursor: Bool

    package init(
        surfaceIdentity: DisplaySurfaceIdentity,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        restoreSharing: Bool,
        restoreMonitoring: Bool,
        monitoringCapturesCursor: Bool
    ) {
        self.surfaceIdentity = surfaceIdentity
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.restoreSharing = restoreSharing
        self.restoreMonitoring = restoreMonitoring
        self.monitoringCapturesCursor = monitoringCapturesCursor
    }
}

package nonisolated enum DisplayRuntimeSessionRestoreKind: String, Codable, Equatable, Sendable {
    case sharing
    case monitoring
}

package nonisolated enum DisplayRuntimeSessionRestoreStatus: String, Codable, Equatable, Sendable {
    case skipped
    case restored
    case failed
    case invalidated
}

package nonisolated struct DisplayRuntimeSessionRestoreResult: Codable, Equatable, Sendable {
    package let kind: DisplayRuntimeSessionRestoreKind
    package let status: DisplayRuntimeSessionRestoreStatus
    package let previousDisplayID: DisplayRuntimeDisplayID?
    package let resolvedDisplayID: DisplayRuntimeDisplayID?
    package let failureReason: String?

    package init(
        kind: DisplayRuntimeSessionRestoreKind,
        status: DisplayRuntimeSessionRestoreStatus,
        previousDisplayID: DisplayRuntimeDisplayID?,
        resolvedDisplayID: DisplayRuntimeDisplayID?,
        failureReason: String?
    ) {
        self.kind = kind
        self.status = status
        self.previousDisplayID = previousDisplayID
        self.resolvedDisplayID = resolvedDisplayID
        self.failureReason = failureReason
    }
}

package nonisolated struct DisplayRuntimeSharingRestoreCommandResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeSessionRestoreStatus
    package let failureReason: String?

    package init(
        status: DisplayRuntimeSessionRestoreStatus,
        failureReason: String?
    ) {
        self.status = status
        self.failureReason = failureReason
    }

    package static let restored = Self(status: .restored, failureReason: nil)

    package static func failed(_ reason: String) -> Self {
        Self(status: .failed, failureReason: reason)
    }

    package static func invalidated(_ reason: String) -> Self {
        Self(status: .invalidated, failureReason: reason)
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayRebuildCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]

    package init(
        configID: UUID,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    ) {
        self.configID = configID
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayLifecycleCommandRequest: Codable, Equatable, Sendable {
    package let configID: UUID
    package let targetPreDisplayID: DisplayRuntimeDisplayID?

    package init(
        configID: UUID,
        targetPreDisplayID: DisplayRuntimeDisplayID?
    ) {
        self.configID = configID
        self.targetPreDisplayID = targetPreDisplayID
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest: Codable, Equatable, Sendable {
    package let configID: UUID
    package let enabled: Bool

    package init(configID: UUID, enabled: Bool) {
        self.configID = configID
        self.enabled = enabled
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let desiredEnabled: Bool
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome

    package init(
        configID: UUID,
        desiredEnabled: Bool,
        persistenceOutcome: DisplayRuntimePersistenceOutcome
    ) {
        self.configID = configID
        self.desiredEnabled = desiredEnabled
        self.persistenceOutcome = persistenceOutcome
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayEnablePreflight: Codable, Equatable, Sendable {
    package let configID: UUID
    package let targetPreDisplayID: DisplayRuntimeDisplayID?
    package let mayPerformFleetRebuild: Bool?
    package let requiresFleetQuiesce: Bool?
    package let scopeEscalationReason: DisplayRuntimeScopeEscalationReason?

    package init(
        configID: UUID,
        targetPreDisplayID: DisplayRuntimeDisplayID?,
        mayPerformFleetRebuild: Bool?,
        requiresFleetQuiesce: Bool?,
        scopeEscalationReason: DisplayRuntimeScopeEscalationReason?
    ) {
        self.configID = configID
        self.targetPreDisplayID = targetPreDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
        self.scopeEscalationReason = scopeEscalationReason
    }
}

package nonisolated struct DisplayRuntimeVirtualDisplayLifecycleCommandResult: Codable, Equatable, Sendable {
    package let configID: UUID
    package let desiredEnabled: Bool
    package let preDisplayID: DisplayRuntimeDisplayID?
    package let postDisplayID: DisplayRuntimeDisplayID?
    package let runningConfigIDsAfterCommand: [UUID]
    package let managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay]
    package let mayPerformFleetRebuild: Bool?
    package let requiresFleetQuiesce: Bool?

    package init(
        configID: UUID,
        desiredEnabled: Bool,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        runningConfigIDsAfterCommand: [UUID],
        managedDisplaysAfterCommand: [DisplayRuntimeManagedVirtualDisplay],
        mayPerformFleetRebuild: Bool?,
        requiresFleetQuiesce: Bool?
    ) {
        self.configID = configID
        self.desiredEnabled = desiredEnabled
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.runningConfigIDsAfterCommand = runningConfigIDsAfterCommand.sorted { $0.uuidString < $1.uuidString }
        self.managedDisplaysAfterCommand = managedDisplaysAfterCommand.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
    }
}

package nonisolated struct DisplayRuntimeTransactionSnapshotEvidence: Codable, Equatable, Sendable {
    package let surfaces: [DisplaySurface]
    package let catalogTopologySignature: [DisplayRuntimeCatalogTopologyEntry]
    package let visibleDisplayIDs: [DisplayRuntimeDisplayID]
    package let captureSessions: [DisplayRuntimeCaptureSession]
    package let sharingDisplayIDs: [DisplayRuntimeDisplayID]
    package let managedVirtualDisplays: [DisplayRuntimeManagedVirtualDisplay]
    package let runningConfigIDs: [UUID]

    package init(
        surfaces: [DisplaySurface],
        catalogTopologySignature: [DisplayRuntimeCatalogTopologyEntry],
        visibleDisplayIDs: [DisplayRuntimeDisplayID],
        captureSessions: [DisplayRuntimeCaptureSession],
        sharingDisplayIDs: [DisplayRuntimeDisplayID],
        managedVirtualDisplays: [DisplayRuntimeManagedVirtualDisplay],
        runningConfigIDs: [UUID]
    ) {
        self.surfaces = surfaces.sorted {
            ($0.kind.rawValue, $0.identity.stableID) < ($1.kind.rawValue, $1.identity.stableID)
        }
        self.catalogTopologySignature = catalogTopologySignature.sorted { $0.displayID < $1.displayID }
        self.visibleDisplayIDs = visibleDisplayIDs.sorted()
        self.captureSessions = captureSessions.sorted { $0.id.uuidString < $1.id.uuidString }
        self.sharingDisplayIDs = sharingDisplayIDs.sorted()
        self.managedVirtualDisplays = managedVirtualDisplays.sorted {
            ($0.configID.uuidString, $0.displayID) < ($1.configID.uuidString, $1.displayID)
        }
        self.runningConfigIDs = runningConfigIDs.sorted { $0.uuidString < $1.uuidString }
    }

    package init(snapshot: DisplayRuntimeSnapshot) {
        self.init(
            surfaces: snapshot.surfaces,
            catalogTopologySignature: snapshot.catalog.topologySignature,
            visibleDisplayIDs: snapshot.catalog.loadedDisplays.map(\.displayID),
            captureSessions: snapshot.capture.sessions,
            sharingDisplayIDs: snapshot.sharing.activeSharingDisplayIDs,
            managedVirtualDisplays: snapshot.virtualDisplay.managedDisplays,
            runningConfigIDs: snapshot.virtualDisplay.runningConfigIDs
        )
    }
}

package nonisolated struct DisplayRuntimeTopologyStabilitySample: Codable, Equatable, Sendable {
    package let topologySignature: [DisplayRuntimeCatalogTopologyEntry]
    package let visibleDisplayIDs: [DisplayRuntimeDisplayID]
    package let managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]

    package init(
        topologySignature: [DisplayRuntimeCatalogTopologyEntry],
        visibleDisplayIDs: [DisplayRuntimeDisplayID],
        managedVirtualDisplays: [DisplayRuntimeTopologyManagedVirtualDisplaySample]
    ) {
        self.topologySignature = topologySignature.sorted { $0.displayID < $1.displayID }
        self.visibleDisplayIDs = visibleDisplayIDs.sorted()
        self.managedVirtualDisplays = managedVirtualDisplays.sorted {
            ($0.configID.uuidString, $0.displayID, $0.isLiveRuntime ? 1 : 0)
                < ($1.configID.uuidString, $1.displayID, $1.isLiveRuntime ? 1 : 0)
        }
    }

    package init(snapshot: DisplayRuntimeSnapshot) {
        self.init(
            topologySignature: snapshot.catalog.topologySignature,
            visibleDisplayIDs: snapshot.catalog.loadedDisplays.map(\.displayID),
            managedVirtualDisplays: snapshot.virtualDisplay.managedDisplays.map {
                .init(
                    configID: $0.configID,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            }
        )
    }
}

package nonisolated struct DisplayRuntimeTopologyManagedVirtualDisplaySample: Codable, Equatable, Sendable {
    package let configID: UUID
    package let displayID: DisplayRuntimeDisplayID
    package let isLiveRuntime: Bool

    package init(
        configID: UUID,
        displayID: DisplayRuntimeDisplayID,
        isLiveRuntime: Bool
    ) {
        self.configID = configID
        self.displayID = displayID
        self.isLiveRuntime = isLiveRuntime
    }
}

package nonisolated enum DisplayRuntimeTopologyStabilityStatus: String, Codable, Equatable, Sendable {
    case stable
    case unprovableDueToPermission
    case failed
    case timedOut
}

package nonisolated struct DisplayRuntimeTopologyStabilityResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeTopologyStabilityStatus
    package let sampleCount: Int
    package let failureReason: String?
    package let lastSample: DisplayRuntimeTopologyStabilitySample?

    package init(
        status: DisplayRuntimeTopologyStabilityStatus,
        sampleCount: Int,
        failureReason: String?,
        lastSample: DisplayRuntimeTopologyStabilitySample?
    ) {
        self.status = status
        self.sampleCount = sampleCount
        self.failureReason = failureReason
        self.lastSample = lastSample
    }
}

package nonisolated enum DisplayRuntimeTransactionRecoverability: String, Codable, Equatable, Sendable {
    case retryable
    case degraded
    case unrecoverable
}

package nonisolated struct DisplayRuntimeTransactionFailure: Codable, Equatable, Sendable {
    package let phase: DisplayRuntimeTransactionPhase
    package let reason: String
    package let underlyingDomain: String?
    package let underlyingCode: Int?
    package let recoverability: DisplayRuntimeTransactionRecoverability

    package init(
        phase: DisplayRuntimeTransactionPhase,
        reason: String,
        underlyingDomain: String? = nil,
        underlyingCode: Int? = nil,
        recoverability: DisplayRuntimeTransactionRecoverability
    ) {
        self.phase = phase
        self.reason = reason
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.recoverability = recoverability
    }
}

package nonisolated enum DisplayRuntimeCompensationStatus: String, Codable, Equatable, Sendable {
    case notRequired
    case skipped
    case completed
    case degraded
}

package nonisolated struct DisplayRuntimeCompensationResult: Codable, Equatable, Sendable {
    package let status: DisplayRuntimeCompensationStatus
    package let restoredSharingCount: Int
    package let restoredMonitoringCount: Int
    package let failedRestoreCount: Int
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome?
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome?
    package let failureReason: String?

    package init(
        status: DisplayRuntimeCompensationStatus,
        restoredSharingCount: Int,
        restoredMonitoringCount: Int,
        failedRestoreCount: Int,
        persistenceOutcome: DisplayRuntimePersistenceOutcome? = nil,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        failureReason: String? = nil
    ) {
        self.status = status
        self.restoredSharingCount = restoredSharingCount
        self.restoredMonitoringCount = restoredMonitoringCount
        self.failedRestoreCount = failedRestoreCount
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.failureReason = failureReason
    }

    package static let notRequired = Self(
        status: .notRequired,
        restoredSharingCount: 0,
        restoredMonitoringCount: 0,
        failedRestoreCount: 0
    )
}

package nonisolated struct DisplayRuntimeTransactionTrace: Codable, Equatable, Sendable {
    package let id: DisplayRuntimeTransactionID
    package let kind: DisplayRuntimeTransactionKind
    package let source: DisplayRuntimeTransactionSource
    package let status: DisplayRuntimeTransactionStatus
    package let phases: [DisplayRuntimeTransactionPhaseRecord]
    package let affectedSurfaces: [DisplayRuntimeAffectedSurface]
    package let preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?
    package let postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?
    package let pauseIntents: [DisplayRuntimeSessionPauseIntent]
    package let restoreIntents: [DisplayRuntimeSessionRestoreIntent]
    package let restoreResults: [DisplayRuntimeSessionRestoreResult]
    package let topologyStabilityResult: DisplayRuntimeTopologyStabilityResult?
    package let failure: DisplayRuntimeTransactionFailure?
    package let compensation: DisplayRuntimeCompensationResult
    package let coalescedRequestCount: Int
    package let persistenceOutcome: DisplayRuntimePersistenceOutcome
    package let virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome
    package let scopeEscalationReason: DisplayRuntimeScopeEscalationReason?
    package let enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    package let oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?
    package let editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?
    package let savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence?

    package init(
        id: DisplayRuntimeTransactionID,
        kind: DisplayRuntimeTransactionKind,
        source: DisplayRuntimeTransactionSource,
        status: DisplayRuntimeTransactionStatus,
        phases: [DisplayRuntimeTransactionPhaseRecord],
        affectedSurfaces: [DisplayRuntimeAffectedSurface],
        preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?,
        postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence?,
        pauseIntents: [DisplayRuntimeSessionPauseIntent],
        restoreIntents: [DisplayRuntimeSessionRestoreIntent],
        restoreResults: [DisplayRuntimeSessionRestoreResult],
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult? = nil,
        failure: DisplayRuntimeTransactionFailure?,
        compensation: DisplayRuntimeCompensationResult,
        coalescedRequestCount: Int,
        persistenceOutcome: DisplayRuntimePersistenceOutcome = .notAttempted,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome = .notAttempted,
        scopeEscalationReason: DisplayRuntimeScopeEscalationReason? = nil,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight? = nil,
        oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.status = status
        self.phases = phases
        self.affectedSurfaces = affectedSurfaces.sorted {
            ($0.reason.rawValue, $0.identity.stableID) < ($1.reason.rawValue, $1.identity.stableID)
        }
        self.preSnapshotEvidence = preSnapshotEvidence
        self.postSnapshotEvidence = postSnapshotEvidence
        self.pauseIntents = pauseIntents.sorted { $0.displayID < $1.displayID }
        self.restoreIntents = restoreIntents.sorted {
            ($0.previousDisplayID ?? 0, $0.surfaceIdentity.stableID) < ($1.previousDisplayID ?? 0, $1.surfaceIdentity.stableID)
        }
        self.restoreResults = restoreResults
        self.topologyStabilityResult = topologyStabilityResult
        self.failure = failure
        self.compensation = compensation
        self.coalescedRequestCount = coalescedRequestCount
        self.persistenceOutcome = persistenceOutcome
        self.virtualDisplayCommandOutcome = virtualDisplayCommandOutcome
        self.scopeEscalationReason = scopeEscalationReason
        self.enablePreflight = enablePreflight
        self.oldConfigEvidence = oldConfigEvidence
        self.editedConfigEvidence = editedConfigEvidence
        self.savedConfigEvidence = savedConfigEvidence
    }

    package func replacing(
        status: DisplayRuntimeTransactionStatus? = nil,
        phases: [DisplayRuntimeTransactionPhaseRecord]? = nil,
        affectedSurfaces: [DisplayRuntimeAffectedSurface]? = nil,
        preSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence? = nil,
        postSnapshotEvidence: DisplayRuntimeTransactionSnapshotEvidence? = nil,
        pauseIntents: [DisplayRuntimeSessionPauseIntent]? = nil,
        restoreIntents: [DisplayRuntimeSessionRestoreIntent]? = nil,
        restoreResults: [DisplayRuntimeSessionRestoreResult]? = nil,
        topologyStabilityResult: DisplayRuntimeTopologyStabilityResult? = nil,
        failure: DisplayRuntimeTransactionFailure? = nil,
        compensation: DisplayRuntimeCompensationResult? = nil,
        coalescedRequestCount: Int? = nil,
        persistenceOutcome: DisplayRuntimePersistenceOutcome? = nil,
        virtualDisplayCommandOutcome: DisplayRuntimeVirtualDisplayCommandOutcome? = nil,
        scopeEscalationReason: DisplayRuntimeScopeEscalationReason? = nil,
        enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight? = nil,
        oldConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        editedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil,
        savedConfigEvidence: DisplayRuntimeVirtualDisplayConfigEvidence? = nil
    ) -> Self {
        Self(
            id: id,
            kind: kind,
            source: source,
            status: status ?? self.status,
            phases: phases ?? self.phases,
            affectedSurfaces: affectedSurfaces ?? self.affectedSurfaces,
            preSnapshotEvidence: preSnapshotEvidence ?? self.preSnapshotEvidence,
            postSnapshotEvidence: postSnapshotEvidence ?? self.postSnapshotEvidence,
            pauseIntents: pauseIntents ?? self.pauseIntents,
            restoreIntents: restoreIntents ?? self.restoreIntents,
            restoreResults: restoreResults ?? self.restoreResults,
            topologyStabilityResult: topologyStabilityResult ?? self.topologyStabilityResult,
            failure: failure ?? self.failure,
            compensation: compensation ?? self.compensation,
            coalescedRequestCount: coalescedRequestCount ?? self.coalescedRequestCount,
            persistenceOutcome: persistenceOutcome ?? self.persistenceOutcome,
            virtualDisplayCommandOutcome: virtualDisplayCommandOutcome ?? self.virtualDisplayCommandOutcome,
            scopeEscalationReason: scopeEscalationReason ?? self.scopeEscalationReason,
            enablePreflight: enablePreflight ?? self.enablePreflight,
            oldConfigEvidence: oldConfigEvidence ?? self.oldConfigEvidence,
            editedConfigEvidence: editedConfigEvidence ?? self.editedConfigEvidence,
            savedConfigEvidence: savedConfigEvidence ?? self.savedConfigEvidence
        )
    }
}

package nonisolated struct DisplayRuntimeTransactionSnapshot: Codable, Equatable, Sendable {
    package let activeTransactions: [DisplayRuntimeTransactionTrace]
    package let recentTransactions: [DisplayRuntimeTransactionTrace]

    package init(
        activeTransactions: [DisplayRuntimeTransactionTrace],
        recentTransactions: [DisplayRuntimeTransactionTrace]
    ) {
        self.activeTransactions = activeTransactions.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        self.recentTransactions = recentTransactions
    }

    package static let empty = Self(activeTransactions: [], recentTransactions: [])
}
