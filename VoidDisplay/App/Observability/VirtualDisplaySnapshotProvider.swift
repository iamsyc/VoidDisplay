import Foundation

struct VirtualDisplaySnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        nonisolated struct Config: Codable, Equatable, Sendable {
            nonisolated struct Mode: Codable, Equatable, Sendable {
                let width: Int
                let height: Int
                let refreshRate: Double
                let enableHiDPI: Bool
            }

            let id: UUID
            let displayName: String
            let serialNumber: UInt32
            let desiredEnabled: Bool
            let physicalWidthMillimeters: Int
            let physicalHeightMillimeters: Int
            let modes: [Mode]
        }

        nonisolated struct ManagedDisplay: Codable, Equatable, Sendable {
            let configID: UUID
            let serialNumber: UInt32
            let displayID: UInt32
            let isLiveRuntime: Bool
        }

        nonisolated struct RestoreFailure: Codable, Equatable, Sendable {
            let configID: UUID
            let displayName: String
            let message: String
        }

        let rebuildRequestCount: Int
        let rebuildingConfigIDs: [UUID]
        let runningConfigIDs: [UUID]
        let recentlyAppliedConfigIDs: [UUID]
        let rebuildFailureMessages: [String: String]
        let configStoreHasLoadFailure: Bool
        let configStoreLoadErrorMessage: String?
        let configStoreDiagnosticsSummary: String?
        let managedDisplays: [ManagedDisplay]
        let configs: [Config]
        let restoreFailures: [RestoreFailure]
    }

    let key = "virtualDisplay"
    private unowned let controller: VirtualDisplayController

    init(controller: VirtualDisplayController) {
        self.controller = controller
    }

    @MainActor
    func makeSnapshot() -> Snapshot {
        Snapshot(
            rebuildRequestCount: controller.rebuildRequestCount,
            rebuildingConfigIDs: controller.rebuildingConfigIds.sorted { $0.uuidString < $1.uuidString },
            runningConfigIDs: controller.runningConfigIds.sorted { $0.uuidString < $1.uuidString },
            recentlyAppliedConfigIDs: controller.recentlyAppliedConfigIds.sorted { $0.uuidString < $1.uuidString },
            rebuildFailureMessages: Dictionary(
                uniqueKeysWithValues: controller.rebuildFailureMessageByConfigId.map {
                    ($0.key.uuidString, $0.value)
                }
            ),
            configStoreHasLoadFailure: controller.configStorePresentation.hasLoadFailure,
            configStoreLoadErrorMessage: controller.configStorePresentation.loadErrorMessage,
            configStoreDiagnosticsSummary: controller.configStorePresentation.diagnosticsSummary,
            managedDisplays: controller.managedDisplays.map {
                .init(
                    configID: $0.configId,
                    serialNumber: $0.serialNum,
                    displayID: $0.displayID,
                    isLiveRuntime: $0.isLiveRuntime
                )
            },
            configs: controller.displayConfigs.map { config in
                .init(
                    id: config.id,
                    displayName: config.displayName,
                    serialNumber: config.serialNum,
                    desiredEnabled: config.desiredEnabled,
                    physicalWidthMillimeters: config.physicalWidth,
                    physicalHeightMillimeters: config.physicalHeight,
                    modes: config.modes.map {
                        .init(
                            width: Int($0.width),
                            height: Int($0.height),
                            refreshRate: $0.refreshRate,
                            enableHiDPI: $0.enableHiDPI
                        )
                    }
                )
            },
            restoreFailures: controller.restoreFailures.map {
                .init(
                    configID: $0.id,
                    displayName: $0.name,
                    message: $0.message
                )
            }
        )
    }
}
