@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation

func catalogSnapshot(displayID: DisplayRuntimeDisplayID, isMain: Bool) -> DisplayRuntimeCatalogSnapshot {
    .init(
        hasScreenCapturePermission: true,
        lastPreflightPermission: true,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: [.init(displayID: displayID, pixelWidth: 1920, pixelHeight: 1080)],
        topologySignature: [
            .init(
                displayID: displayID,
                isMain: isMain,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRateMilliHertz: 60_000,
                mirrorsDisplayID: nil
            )
        ]
    )
}

func catalogSnapshot(
    displayIDs: [DisplayRuntimeDisplayID],
    mainDisplayID: DisplayRuntimeDisplayID?
) -> DisplayRuntimeCatalogSnapshot {
    .init(
        hasScreenCapturePermission: true,
        lastPreflightPermission: true,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: displayIDs.map {
            .init(displayID: $0, pixelWidth: 1920, pixelHeight: 1080)
        },
        topologySignature: displayIDs.map {
            .init(
                displayID: $0,
                isMain: $0 == mainDisplayID,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRateMilliHertz: 60_000,
                mirrorsDisplayID: nil
            )
        }
    )
}

func activeSharingSnapshot(displayID: DisplayRuntimeDisplayID) -> DisplayRuntimeSharingSnapshot {
    .init(
        activeSharingDisplayIDs: [displayID],
        startingDisplayIDs: [],
        isSharing: true,
        isWebServiceRunning: true,
        preferredPort: 8089,
        sharingClientCount: 1,
        sharingClientCounts: [.init(displayID: displayID, count: 1)],
        lifecycle: .init(
            phase: .running,
            requestedPort: 8089,
            boundPort: 8089,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: [.init(displayID: displayID, hasConcreteRoute: true)]
    )
}

func sharingSnapshot(
    isWebServiceRunning: Bool,
    activeDisplayIDs: [DisplayRuntimeDisplayID]
) -> DisplayRuntimeSharingSnapshot {
    DisplayRuntimeSharingSnapshot(
        activeSharingDisplayIDs: activeDisplayIDs,
        startingDisplayIDs: [],
        isSharing: !activeDisplayIDs.isEmpty,
        isWebServiceRunning: isWebServiceRunning,
        preferredPort: 8081,
        sharingClientCount: 0,
        sharingClientCounts: [],
        lifecycle: .init(
            phase: isWebServiceRunning ? .running : .stopped,
            requestedPort: isWebServiceRunning ? 8081 : nil,
            boundPort: isWebServiceRunning ? 8081 : nil,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: []
    )
}

func stoppedSharingSnapshot(previousDisplayID: DisplayRuntimeDisplayID) -> DisplayRuntimeSharingSnapshot {
    .init(
        activeSharingDisplayIDs: [],
        startingDisplayIDs: [],
        isSharing: false,
        isWebServiceRunning: false,
        preferredPort: 8089,
        sharingClientCount: 0,
        sharingClientCounts: [],
        lifecycle: .init(
            phase: .stopped,
            requestedPort: nil,
            boundPort: nil,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: [.init(displayID: previousDisplayID, hasConcreteRoute: false)]
    )
}

func captureSnapshot(
    displayIDs: [DisplayRuntimeDisplayID],
    isVirtualDisplay: Bool = false,
    capturesCursor: Bool = false
) -> DisplayRuntimeCaptureSnapshot {
    DisplayRuntimeCaptureSnapshot(
        startingDisplayIDs: [],
        sessions: displayIDs.enumerated().map { index, displayID in
            DisplayRuntimeCaptureSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))")!,
                displayID: displayID,
                isVirtualDisplay: isVirtualDisplay,
                capturesCursor: capturesCursor,
                state: .active,
                metrics: .empty
            )
        }
    )
}

func previewCaptureSnapshot(
    displayID: DisplayRuntimeDisplayID,
    capturesCursor: Bool
) -> DisplayRuntimeCaptureSnapshot {
    captureSnapshot(
        displayIDs: [displayID],
        isVirtualDisplay: true,
        capturesCursor: capturesCursor
    )
}

func virtualDisplaySnapshot(
    configID: UUID,
    displayID: DisplayRuntimeDisplayID
) -> DisplayRuntimeVirtualDisplaySnapshot {
    virtualDisplaySnapshot(configs: [(configID, 9001, displayID)])
}

func virtualDisplaySnapshot(
    configs: [(UUID, UInt32, DisplayRuntimeDisplayID)]
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        runningConfigIDs: configs.map(\.0),
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: configs.map {
            .init(configID: $0.0, serialNumber: $0.1, displayID: $0.2, isLiveRuntime: true)
        },
        configs: configs.map {
            .init(
                id: $0.0,
                serialNumber: $0.1,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        },
        restoreFailureConfigIDs: []
    )
}

func disabledVirtualDisplaySnapshot(
    configID: UUID,
    serial: UInt32,
    desiredEnabled: Bool = false
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        runningConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [],
        configs: [
            .init(
                id: configID,
                serialNumber: serial,
                desiredEnabled: desiredEnabled,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ],
        restoreFailureConfigIDs: []
    )
}

func runningVirtualDisplaySnapshot(
    configID: UUID,
    serial: UInt32,
    displayID: DisplayRuntimeDisplayID,
    desiredEnabled: Bool
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        runningConfigIDs: [configID],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [
            .init(configID: configID, serialNumber: serial, displayID: displayID, isLiveRuntime: true)
        ],
        configs: [
            .init(
                id: configID,
                serialNumber: serial,
                desiredEnabled: desiredEnabled,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ],
        restoreFailureConfigIDs: []
    )
}

func mixedVirtualDisplaySnapshot(
    disabled: (UUID, UInt32),
    running: [(UUID, UInt32, DisplayRuntimeDisplayID)]
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        runningConfigIDs: running.map(\.0),
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: running.map {
            .init(configID: $0.0, serialNumber: $0.1, displayID: $0.2, isLiveRuntime: true)
        },
        configs: [
            .init(
                id: disabled.0,
                serialNumber: disabled.1,
                desiredEnabled: false,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ] + running.map {
            .init(
                id: $0.0,
                serialNumber: $0.1,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        },
        restoreFailureConfigIDs: []
    )
}
