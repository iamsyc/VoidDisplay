import Foundation

package nonisolated enum DisplayRuntimeCatalogSource: String, Codable, Equatable, Sendable {
    case capturePage
    case sharingPage
}

package nonisolated enum DisplayRuntimeCatalogRefreshIntent: String, Codable, Equatable, Sendable {
    case permissionChanged
    case topologyChanged
    case serviceBecameRunning
    case userForcedRefresh
}

package nonisolated enum DisplayRuntimeCatalogRefreshResult: String, Codable, Equatable, Sendable {
    case reloadedSnapshot
    case reusedSnapshot
    case clearedSnapshot
    case failed
}

package nonisolated enum DisplayRuntimeCatalogRefreshOwnerScope: String, Codable, Equatable, Sendable {
    case capture
    case sharing
}

package nonisolated struct DisplayRuntimeVisibleDisplay: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let pixelWidth: Int?
    package let pixelHeight: Int?

    package init(
        displayID: DisplayRuntimeDisplayID,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

package nonisolated struct DisplayRuntimeShareableDisplayRegistration: Codable, Equatable, Sendable {
    package let displayID: DisplayRuntimeDisplayID
    package let virtualSerialNumber: UInt32?

    package init(
        displayID: DisplayRuntimeDisplayID,
        virtualSerialNumber: UInt32?
    ) {
        self.displayID = displayID
        self.virtualSerialNumber = virtualSerialNumber
    }
}

package nonisolated struct DisplayRuntimeObservabilityEvent: Codable, Equatable, Sendable {
    package let severity: DisplayRuntimeObservabilitySeverity
    package let operation: String
    package let message: String
    package let metadata: [String: String]
    package let deduplicationKey: String?

    package init(
        severity: DisplayRuntimeObservabilitySeverity,
        operation: String,
        message: String,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        self.severity = severity
        self.operation = operation
        self.message = message
        self.metadata = metadata
        self.deduplicationKey = deduplicationKey
    }
}

package nonisolated enum DisplayRuntimeObservabilitySeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
}

package nonisolated enum DisplayRuntimeObservabilityRefreshReason: String, Codable, Equatable, Sendable {
    case screenCatalogStateChanged
}
