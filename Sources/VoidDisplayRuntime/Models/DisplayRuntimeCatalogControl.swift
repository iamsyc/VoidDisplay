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
    case superseded
    case failed
}

package nonisolated struct DisplayRuntimeCatalogRefreshOutcome: Equatable, Sendable {
    package let settlementID: UInt64?
    package let result: DisplayRuntimeCatalogRefreshResult
    package let catalog: DisplayRuntimeCatalogSnapshot

    package init(
        settlementID: UInt64?,
        result: DisplayRuntimeCatalogRefreshResult,
        catalog: DisplayRuntimeCatalogSnapshot
    ) {
        self.settlementID = settlementID
        self.result = result
        self.catalog = catalog
    }
}

package nonisolated struct DisplayRuntimeCatalogSurfaceRegistration: Hashable, Sendable {
    package let id: UUID
    package let source: DisplayRuntimeCatalogSource

    package init(
        id: UUID = UUID(),
        source: DisplayRuntimeCatalogSource
    ) {
        self.id = id
        self.source = source
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
    package let domain: DisplayRuntimeObservabilityDomain
    package let severity: DisplayRuntimeObservabilitySeverity
    package let operation: String
    package let message: String
    package let metadata: [String: String]
    package let deduplicationKey: String?

    package init(
        domain: DisplayRuntimeObservabilityDomain = .screenCatalog,
        severity: DisplayRuntimeObservabilitySeverity,
        operation: String,
        message: String,
        metadata: [String: String] = [:],
        deduplicationKey: String? = nil
    ) {
        self.domain = domain
        self.severity = severity
        self.operation = operation
        self.message = message
        self.metadata = metadata
        self.deduplicationKey = deduplicationKey
    }
}

package nonisolated enum DisplayRuntimeObservabilityDomain: String, Codable, Equatable, Sendable {
    case screenCatalog
    case displayRuntime
}

package nonisolated enum DisplayRuntimeObservabilitySeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
}

package nonisolated enum DisplayRuntimeObservabilityRefreshReason: String, Codable, Equatable, Sendable {
    case screenCatalogStateChanged
    case displayRuntimeTransactionChanged
}
