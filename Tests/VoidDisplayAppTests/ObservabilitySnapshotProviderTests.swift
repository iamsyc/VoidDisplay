@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayRuntime
@testable import VoidDisplayTestingSupport
@testable import VoidDisplaySharingTestingSupport
import Foundation
import Testing

private final class SnapshotProviderMockSharingPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8089

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

private final class SnapshotProviderDummySession: DisplayCaptureSessioning, @unchecked Sendable {
    nonisolated let sessionHub = TestSignalSessionHub()
    nonisolated var shareFrameConsumer: any DisplayShareFrameConsumer { sessionHub }
    nonisolated let metricsSnapshot: DisplayCaptureMetricsSnapshot

    init(
        metricsSnapshot: DisplayCaptureMetricsSnapshot = .init(
            currentProfile: nil,
            currentFrameRateTier: nil,
            receivedFrameCount: 0,
            profileReconfigurationCount: 0,
            cursorOverrideReconfigurationCount: 0
        )
    ) {
        self.metricsSnapshot = metricsSnapshot
    }

    nonisolated func attachPreviewSink(_ _: any DisplayPreviewSink) {}
    nonisolated func detachPreviewSink(_ _: any DisplayPreviewSink) {}
    nonisolated func stopSharing() {}
    nonisolated func setDemand(_ _: DisplayCaptureDemandSnapshot) async throws {}
    nonisolated func captureMetricsSnapshot() -> DisplayCaptureMetricsSnapshot { metricsSnapshot }
    nonisolated func stop() async {}
}

@MainActor
struct ObservabilitySnapshotProviderTests {
    @Test func captureSnapshotProviderPublishesCurrentSessions() {
        let service = MockCaptureMonitoringService()
        let session = ScreenMonitoringSession(
            id: UUID(),
            displayID: 77,
            displayName: "Display 77",
            resolutionText: "2560 × 1440",
            isVirtualDisplay: false,
            previewSubscription: DisplayPreviewSubscription(
                displayID: 77,
                resolutionText: "2560 × 1440",
                session: SnapshotProviderDummySession(
                    metricsSnapshot: .init(
                        currentProfile: .mixed,
                        currentFrameRateTier: .fps60,
                        receivedFrameCount: 42,
                        profileReconfigurationCount: 3,
                        cursorOverrideReconfigurationCount: 1
                    )
                ),
                cancelClosure: {}
            ),
            capturesCursor: true,
            state: .active
        )
        service.currentSessions = [session]
        let controller = CaptureController(captureMonitoringService: service)
        controller.installStartingDisplayIDsForTesting([77])

        let snapshot = CaptureSnapshotProvider(controller: controller).makeSnapshot()

        #expect(snapshot.startingDisplayIDs == [77])
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions.first?.displayName == "Display 77")
        #expect(snapshot.sessions.first?.metrics.currentProfile == DisplayCaptureProfile.mixed.rawValue)
        #expect(snapshot.sessions.first?.metrics.currentFrameRateTier == "\(DisplayCaptureFrameRateTier.fps60.framesPerSecond)fps")
        #expect(snapshot.sessions.first?.metrics.receivedFrameCount == 42)
        #expect(snapshot.sessions.first?.metrics.profileReconfigurationCount == 3)
        #expect(snapshot.sessions.first?.metrics.cursorOverrideReconfigurationCount == 1)
    }

    @Test func sharingSnapshotProviderCapturesFailureLifecycle() {
        let service = MockSharingService()
        service.webServiceLifecycleState = .failed(.portInUse(port: 8080))
        service.isWebServiceRunning = false

        let controller = SharingController(
            sharingService: service,
            portPreferences: SnapshotProviderMockSharingPortPreferences()
        )

        let snapshot = SharingSnapshotProvider(controller: controller).makeSnapshot()

        #expect(snapshot.lifecycle.phase == "failed")
        #expect(snapshot.lifecycle.requestedPort == 8080)
        #expect(snapshot.lifecycle.failureReason == "port_in_use")
    }

    @Test func virtualDisplaySnapshotProviderCapturesRestoreAndRebuildFailures() throws {
        let facade = MockVirtualDisplayFacade()
        let configID = UUID()
        facade.currentDisplayConfigs = [
            VirtualDisplayConfig(
                id: configID,
                displayName: "Desk",
                serialNum: 123,
                physicalWidth: 600,
                physicalHeight: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)],
                desiredEnabled: true
            )
        ]
        facade.currentRestoreFailures = [
            .init(id: configID, name: "Desk", serialNum: 123, message: "Restore failed.")
        ]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .seconds(1)
        )
        controller.applyUITestPresentationState(scenario: .virtualDisplayRebuildFailed)

        let snapshot = VirtualDisplaySnapshotProvider(controller: controller).makeSnapshot()

        #expect(snapshot.restoreFailures.count == 1)
        let data = try ObservabilityCodec.encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("displayName"))
        #expect(!json.contains("Desk"))
        #expect(
            snapshot.rebuildFailureMessages[configID.uuidString] ==
                String(localized: "Failed to rebuild virtual display.")
        )
    }

    @Test func screenCatalogSnapshotProviderCapturesPermissionDeniedState() {
        let store = ScreenCaptureCatalogStore()
        store.hasScreenCapturePermission = false
        store.lastPreflightPermission = false
        store.lastRequestPermission = false
        store.loadErrorMessage = "Permission missing."
        store.lastLoadError = .init(
            domain: "ScreenCapture",
            code: 1,
            description: "Permission missing.",
            failureReason: nil,
            recoverySuggestion: nil
        )

        let snapshot = ScreenCatalogSnapshotProvider(store: store).makeSnapshot()

        #expect(snapshot.hasScreenCapturePermission == false)
        #expect(snapshot.loadErrorMessage == "Permission missing.")
        #expect(snapshot.lastLoadError?.domain == "ScreenCapture")
    }

    @Test func runtimeSnapshotProviderPublishesPhase4StateWithDefaultRedaction() async throws {
        let sensitiveInputs = [
            "share-id-raw-fixture-42",
            "viewer-client-secret-42",
            "https://10.0.0.8:8080/display/secret",
            "10.0.0.8",
            "\(NSHomeDirectory())/Desktop/capture.txt",
            "Confidential Window Caption",
            "typed user search text",
            "visible desktop pixels"
        ]
        let runtime = DisplayRuntime()
        let surfaceIdentity = DisplaySurfaceIdentity.physicalDisplay(displayID: 888)
        let lease = runtime.attachConsumer(
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: sensitiveInputs.joined(separator: " ")),
            demand: DisplayRuntimeConsumerDemand(
                sourcePixelSize: .init(width: 3840, height: 2160),
                preferredPixelSize: .init(width: 1920, height: 1080),
                sourceFramesPerSecond: 60,
                preferredFramesPerSecond: 30,
                capturesCursor: true,
                powerProfile: .smooth,
                latencyPreference: .realtime,
                activeViewerCount: 2
            )
        )
        let provider = AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: runtime))

        let section = try await provider.makeSnapshot()
        let snapshot = try section.decode(DisplayRuntimeSnapshot.self)
        let sectionJSON = String(
            decoding: try ObservabilityCodec.encode(section),
            as: UTF8.self
        )

        #expect(provider.key == "runtime")
        #expect(snapshot.consumerLeases.first?.id == lease.id)
        #expect(snapshot.consumerLeases.first?.kind == .lanWebView)
        #expect(snapshot.consumerLeases.first?.ownerSource == .sharingService)
        #expect(snapshot.aggregatedDemands.first?.activeViewerCount == 2)
        #expect(snapshot.aggregatedDemands.first?.capturesCursor == true)
        #expect(snapshot.effectiveCaptureIntents.first?.intent.kind == .capture)
        #expect(snapshot.consumerSummary.leaseCountsByKind == [
            .init(kind: .lanWebView, activeCount: 1, totalCount: 1)
        ])
        #expect(sectionJSON.contains("redactedLabel") == false)
        for sensitiveInput in sensitiveInputs {
            #expect(sectionJSON.contains(sensitiveInput) == false)
        }
    }

    @Test func snapshotProvidersReturnEmptySnapshotsAfterOwnersRelease() {
        var captureController: CaptureController? = CaptureController(
            captureMonitoringService: MockCaptureMonitoringService()
        )
        let captureProvider = CaptureSnapshotProvider(controller: captureController!)
        captureController = nil
        let captureSnapshot = captureProvider.makeSnapshot()
        #expect(captureSnapshot.startingDisplayIDs.isEmpty)
        #expect(captureSnapshot.sessions.isEmpty)

        var sharingController: SharingController? = SharingController(
            sharingService: MockSharingService(),
            portPreferences: SnapshotProviderMockSharingPortPreferences()
        )
        let sharingProvider = SharingSnapshotProvider(controller: sharingController!)
        sharingController = nil
        let sharingSnapshot = sharingProvider.makeSnapshot()
        #expect(sharingSnapshot.lifecycle.phase == "unavailable")
        #expect(sharingSnapshot.sharingClientCount == 0)

        var virtualDisplayController: VirtualDisplayController? = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .seconds(1)
        )
        let virtualDisplayProvider = VirtualDisplaySnapshotProvider(controller: virtualDisplayController!)
        virtualDisplayController = nil
        let virtualDisplaySnapshot = virtualDisplayProvider.makeSnapshot()
        #expect(virtualDisplaySnapshot.configs.isEmpty)
        #expect(virtualDisplaySnapshot.managedDisplays.isEmpty)

        var screenCatalogStore: ScreenCaptureCatalogStore? = ScreenCaptureCatalogStore()
        let screenCatalogProvider = ScreenCatalogSnapshotProvider(store: screenCatalogStore!)
        screenCatalogStore = nil
        let screenCatalogSnapshot = screenCatalogProvider.makeSnapshot()
        #expect(screenCatalogSnapshot.loadedDisplayIDs.isEmpty)
        #expect(screenCatalogSnapshot.topologySignature.isEmpty)
    }
}
