import CryptoKit
import Foundation

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
        self.init(
            id: snapshotConfig.id,
            serialNumber: snapshotConfig.serialNumber,
            desiredEnabled: snapshotConfig.desiredEnabled,
            physicalWidthMillimeters: UInt32(clamping: snapshotConfig.physicalWidthMillimeters),
            physicalHeightMillimeters: UInt32(clamping: snapshotConfig.physicalHeightMillimeters),
            modeCount: snapshotConfig.modes.count,
            maximumPixelWidth: snapshotConfig.maximumPixelWidth,
            maximumPixelHeight: snapshotConfig.maximumPixelHeight
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
