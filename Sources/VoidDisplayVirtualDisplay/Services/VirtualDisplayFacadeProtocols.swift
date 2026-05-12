import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

package struct VirtualDisplayEnablePreflight: Equatable, Sendable {
    package enum ScopeEscalationReason: Equatable, Sendable {
        case enableMayPerformFleetRebuild
    }

    package let configID: UUID
    package let targetPreDisplayID: CGDirectDisplayID?
    package let mayPerformFleetRebuild: Bool
    package let requiresFleetQuiesce: Bool
    package let scopeEscalationReason: ScopeEscalationReason?

    package init(
        configID: UUID,
        targetPreDisplayID: CGDirectDisplayID?,
        mayPerformFleetRebuild: Bool,
        requiresFleetQuiesce: Bool,
        scopeEscalationReason: ScopeEscalationReason?
    ) {
        self.configID = configID
        self.targetPreDisplayID = targetPreDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
        self.scopeEscalationReason = scopeEscalationReason
    }
}

package struct VirtualDisplayLifecycleCommandResult: Equatable, Sendable {
    package let configID: UUID
    package let desiredEnabled: Bool
    package let preDisplayID: CGDirectDisplayID?
    package let postDisplayID: CGDirectDisplayID?
    package let mayPerformFleetRebuild: Bool
    package let requiresFleetQuiesce: Bool

    package init(
        configID: UUID,
        desiredEnabled: Bool,
        preDisplayID: CGDirectDisplayID?,
        postDisplayID: CGDirectDisplayID?,
        mayPerformFleetRebuild: Bool,
        requiresFleetQuiesce: Bool
    ) {
        self.configID = configID
        self.desiredEnabled = desiredEnabled
        self.preDisplayID = preDisplayID
        self.postDisplayID = postDisplayID
        self.mayPerformFleetRebuild = mayPerformFleetRebuild
        self.requiresFleetQuiesce = requiresFleetQuiesce
    }
}

@MainActor
package protocol VirtualDisplayQuerying: AnyObject {
    var snapshot: VirtualDisplaySnapshot { get }
    func nextAvailableSerialNumber() -> UInt32
}

@MainActor
package protocol VirtualDisplayCommanding: AnyObject {
    func loadPersistedConfigs()
    func restoreDesiredVirtualDisplays()
    func clearRestoreFailures()

    @discardableResult
    func resetAllVirtualDisplayData() throws -> Int

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> UUID

    func setDesiredEnabled(_ configId: UUID, enabled: Bool) throws
    func enableDisplayPreflight(_ configId: UUID) -> VirtualDisplayEnablePreflight
    func enableRuntimeDisplay(_ configId: UUID) async throws -> VirtualDisplayLifecycleCommandResult
    func disableRuntimeDisplayByConfig(_ configId: UUID) throws -> VirtualDisplayLifecycleCommandResult
    func disableDisplayByConfig(_ configId: UUID) throws
    func enableDisplay(_ configId: UUID) async throws
    func destroyDisplay(_ configId: UUID) throws
    func updateConfig(_ updated: VirtualDisplayConfig) throws
    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) throws -> Bool
    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) throws -> Bool
    func applyModes(configId: UUID, modes: [ResolutionSelection])
    func rebuildVirtualDisplay(configId: UUID) async throws
    func reconcileMainDisplayPolicyIfNeeded() async throws
}

@MainActor
package protocol VirtualDisplayFacade: VirtualDisplayCommanding, VirtualDisplayQuerying {}

extension VirtualDisplayOrchestrator: VirtualDisplayFacade {}
