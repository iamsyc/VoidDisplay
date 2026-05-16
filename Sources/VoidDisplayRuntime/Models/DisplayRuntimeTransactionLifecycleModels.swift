import Foundation

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
    package let mayPerformFleetRebuild: Bool?
    package let requiresFleetQuiesce: Bool?

    package init(
        configID: UUID,
        desiredEnabled: Bool,
        preDisplayID: DisplayRuntimeDisplayID?,
        postDisplayID: DisplayRuntimeDisplayID?,
        mayPerformFleetRebuild: Bool?,
        requiresFleetQuiesce: Bool?
    ) {
        self.configID = configID
        self.desiredEnabled = desiredEnabled
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
    }
}
