@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayRuntime
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import Foundation

@MainActor
func makeHomeController(
    captureService: MockCapturePreviewService = MockCapturePreviewService(),
    sharingService: MockSharingService = MockSharingService(),
    virtualDisplayFacade: MockVirtualDisplayFacade = MockVirtualDisplayFacade()
) -> (HomeVirtualDisplaySurfaceController, AppEnvironment) {
    let environment = AppBootstrap.makeEnvironment(
        preview: true,
        capturePreviewService: captureService,
        sharingService: sharingService,
        virtualDisplayFacade: virtualDisplayFacade,
        startupPlan: .init(shouldRestoreVirtualDisplays: false),
        isRunningUnderXCTestOverride: true
    )
    let controller = HomeVirtualDisplaySurfaceController(
        capture: environment.capture,
        sharing: environment.sharing,
        virtualDisplay: environment.virtualDisplay,
        capturePerformancePreferences: environment.capturePerformancePreferences,
        displayRuntime: environment.displayRuntime,
        sharingAdapter: environment.sharingAdapter
    )
    return (controller, environment)
}

func makeHomeConsumerLease(
    surfaceIdentity: DisplaySurfaceIdentity,
    displayID: DisplayRuntimeDisplayID,
    kind: DisplaySurfaceConsumerKind,
    state: DisplayRuntimeConsumerLeaseState,
    activeViewerCount: Int = 0,
    lastFailureCode: String? = nil
) -> DisplayRuntimeConsumerLease {
    DisplayRuntimeConsumerLease(
        surfaceIdentity: surfaceIdentity,
        surfaceEpoch: .initial,
        resolvedDisplayID: displayID,
        kind: kind,
        owner: .init(source: .localUI, redactedLabel: nil),
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        state: state,
        demand: DisplayRuntimeConsumerDemand(
            sourcePixelSize: DisplayRuntimePixelSize(width: 1920, height: 1080),
            preferredPixelSize: nil,
            maximumPixelSize: nil,
            sourceFramesPerSecond: 60,
            preferredFramesPerSecond: nil,
            capturesCursor: false,
            powerProfile: .automatic,
            latencyPreference: .realtime,
            activeViewerCount: activeViewerCount
        ),
        lastFailureCode: lastFailureCode
    )
}

func makeHomeRuntimeSnapshot(
    surfaces: [DisplaySurface],
    catalog: DisplayRuntimeCatalogSnapshot = .empty,
    capture: DisplayRuntimeCaptureSnapshot = .empty,
    sharing: DisplayRuntimeSharingSnapshot = .empty,
    virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot = .empty,
    transactions: DisplayRuntimeTransactionSnapshot = .empty,
    consumerLeases: [DisplayRuntimeConsumerLeaseSnapshot] = [],
    aggregatedDemands: [DisplayRuntimeAggregatedDemand] = [],
    effectiveCaptureIntents: [DisplayRuntimeEffectiveCaptureIntent] = []
) -> DisplayRuntimeSnapshot {
    DisplayRuntimeSnapshot(
        surfaces: surfaces,
        catalog: catalog,
        capture: capture,
        sharing: sharing,
        virtualDisplay: virtualDisplay,
        transactions: transactions,
        consumerLeases: consumerLeases,
        aggregatedDemands: aggregatedDemands,
        effectiveCaptureIntents: effectiveCaptureIntents
    )
}
