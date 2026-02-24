import CoreGraphics
import Foundation

@MainActor
protocol VirtualDisplayServiceProtocol: AnyObject {
    var currentDisplays: [CGVirtualDisplay] { get }
    var currentDisplayConfigs: [VirtualDisplayConfig] { get }
    var currentRunningConfigIds: Set<UUID> { get }
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] { get }

    func loadPersistedConfigs()
    func restoreDesiredVirtualDisplays()
    func clearRestoreFailures()

    @discardableResult
    func resetAllVirtualDisplayData() -> Int

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay?
    func runtimeDisplayID(for configId: UUID) -> CGDirectDisplayID?
    func isVirtualDisplayRunning(configId: UUID) -> Bool

    @discardableResult
    func createDisplay(
        name: String,
        serialNum: UInt32,
        physicalSize: CGSize,
        maxPixels: (width: UInt32, height: UInt32),
        modes: [ResolutionSelection]
    ) throws -> CGVirtualDisplay

    @discardableResult
    func createDisplayFromConfig(_ config: VirtualDisplayConfig) throws -> CGVirtualDisplay

    func disableDisplay(_ display: CGVirtualDisplay, modes: [ResolutionSelection])
    func disableDisplayByConfig(_ configId: UUID) throws
    func enableDisplay(_ configId: UUID) async throws
    func destroyDisplay(_ configId: UUID)
    func destroyDisplay(_ display: CGVirtualDisplay)
    func getConfig(_ configId: UUID) -> VirtualDisplayConfig?
    func updateConfig(_ updated: VirtualDisplayConfig)
    func moveConfig(_ configId: UUID, direction: VirtualDisplayService.ReorderDirection) -> Bool
    func applyModes(configId: UUID, modes: [ResolutionSelection])
    func rebuildVirtualDisplay(configId: UUID) async throws
    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig?
    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection])
    func nextAvailableSerialNumber() -> UInt32
}

extension VirtualDisplayService: VirtualDisplayServiceProtocol {}
