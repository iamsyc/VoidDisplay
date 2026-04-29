import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import CoreGraphics
import Foundation

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
