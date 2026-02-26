import CoreGraphics
import Foundation

struct VirtualDisplayConfigStorePresentation: Equatable {
    var hasLoadFailure = false
    var loadErrorMessage: String?
    var diagnosticsSummary: String?
}

@MainActor
protocol VirtualDisplayServiceProtocol: AnyObject {
    var currentDisplays: [CGVirtualDisplay] { get }
    var currentDisplayConfigs: [VirtualDisplayConfig] { get }
    var currentRunningConfigIds: Set<UUID> { get }
    var currentRestoreFailures: [VirtualDisplayRestoreFailure] { get }
    var configStorePresentation: VirtualDisplayConfigStorePresentation { get }

    func loadPersistedConfigs()
    func restoreDesiredVirtualDisplays()
    func clearRestoreFailures()

    @discardableResult
    func resetAllVirtualDisplayData() -> Int

    func runtimeDisplay(for configId: UUID) -> CGVirtualDisplay?
    // Returns the best-known runtime display identifier for a config.
    // This may come from a live CGVirtualDisplay instance or a persisted runtime hint
    // during teardown/rebuild windows where the object reference is temporarily unavailable.
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
    func moveConfig(_ configId: UUID, direction: VirtualDisplayReorderDirection) -> Bool
    @discardableResult
    func moveConfigToFirstEnabledPosition(_ configId: UUID) -> Bool
    func applyModes(configId: UUID, modes: [ResolutionSelection])
    func rebuildVirtualDisplay(configId: UUID) async throws
    func reconcileMainDisplayPolicyIfNeeded() async throws
    func getConfig(for display: CGVirtualDisplay) -> VirtualDisplayConfig?
    func updateConfig(for display: CGVirtualDisplay, modes: [ResolutionSelection])
    func nextAvailableSerialNumber() -> UInt32
}

extension VirtualDisplayService: VirtualDisplayServiceProtocol {}
