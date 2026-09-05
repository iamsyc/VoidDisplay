@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayRuntime
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import CoreGraphics
import Foundation
import AppKit
import Testing

@MainActor
struct MenuBarQuickActionsTests {
    @Test
    func openPreviewReusesExistingSession() async {
        let displayID = CGDirectDisplayID(9_901)
        let previewID = UUID(uuidString: "00000000-0000-0000-0000-000000009901")!
        let config = makeConfig(desiredEnabled: true)
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = displayID
        let (controller, environment) = makeController(virtualDisplayFacade: facade)
        let now = Date.now
        let leaseID = DisplayRuntimeConsumerLeaseID(rawValue: previewID)
        environment.displayRuntime.consumerLeasesByID[leaseID] = DisplayRuntimeConsumerLease(
            id: leaseID,
            surfaceIdentity: .managedVirtualDisplay(configID: config.id),
            surfaceEpoch: .initial,
            resolvedDisplayID: displayID,
            kind: .preview,
            owner: .init(source: .localUI),
            createdAt: now,
            updatedAt: now,
            state: .attached,
            demand: .init(
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime
            )
        )
        let item = controller.presentation.items.first ?? makeItem(displayID: displayID, isRunning: true)
        var openedPreviewID: CapturePreviewID?

        controller.performMenuBarAction(
            .openPreview,
            for: item,
            openPreviewWindow: { openedPreviewID = $0 }
        )

        let didOpenPreview = await waitUntil { openedPreviewID != nil }

        #expect(didOpenPreview)
        #expect(openedPreviewID?.rawValue == previewID)
    }

    @Test
    func toggleUsesSharedVirtualDisplayRuntime() async throws {
        let config = makeConfig(desiredEnabled: false)
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.runtimeDisplayIDByConfigId[config.id] = 9_902
        let (controller, _) = makeController(virtualDisplayFacade: facade)
        let item = try #require(controller.presentation.items.first)

        controller.performMenuBarAction(
            .toggle,
            for: item,
            openPreviewWindow: { _ in }
        )

        #expect(controller.viewModel.isToggling(configId: config.id))
        let didRouteToggle = await waitUntil { facade.setDesiredEnabledCallCount == 1 }
        let didFinishToggle = await waitUntil { !controller.viewModel.isToggling(configId: config.id) }

        #expect(didRouteToggle)
        #expect(didFinishToggle)
        #expect(facade.setDesiredEnabledRequests.count == 1)
        #expect(facade.setDesiredEnabledRequests.first?.0 == config.id)
        #expect(facade.setDesiredEnabledRequests.first?.1 == true)
        #expect(facade.enableRuntimeDisplayConfigIDs == [config.id])
    }

    @Test
    func toggleFailureUsesExistingUserFacingErrorState() async throws {
        let config = makeConfig(desiredEnabled: false)
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.setDesiredEnabledError = VirtualDisplayOperationError.creationFailed
        let (controller, _) = makeController(virtualDisplayFacade: facade)
        let item = try #require(controller.presentation.items.first)

        controller.performMenuBarAction(
            .toggle,
            for: item,
            openPreviewWindow: { _ in }
        )

        let didPresentError = await waitUntil { controller.viewModel.userFacingAlert != nil }

        #expect(didPresentError)
        #expect(controller.viewModel.userFacingAlert != nil)
    }

    @Test
    func controllerUsesSavedSharingPort() {
        let (controller, environment) = makeController()

        environment.sharing.savePreferredWebServicePort(18_084)
        controller.handlePreferredSharingPortChanged(from: 8_081, to: 18_084)

        #expect(controller.preferredSharingPort == 18_084)
        #expect(controller.sharingPortInput == "18084")
    }

    @Test
    func copyShareAddressWritesExpectedURL() {
        let (controller, _) = makeController()
        let expectedAddress = "http://127.0.0.1:18084/display/9902"
        let item = makeItem(
            displayID: 9_902,
            isRunning: true,
            shareAddress: expectedAddress
        )

        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item in
            let savedItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    savedItem.setData(data, forType: type)
                }
            }
            return savedItem
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(previousItems)
        }
        pasteboard.clearContents()
        controller.performMenuBarAction(
            .copyShareAddress,
            for: item,
            openPreviewWindow: { _ in }
        )

        #expect(NSPasteboard.general.string(forType: .string) == expectedAddress)
    }

    @Test
    func stopWebViewReleasesExistingRuntimeLease() async {
        let displayID = CGDirectDisplayID(9_903)
        let config = makeConfig(desiredEnabled: true)
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = displayID
        let sharingService = MockSharingService()
        sharingService.activeSharingDisplayIDs = [displayID]
        sharingService.hasAnyActiveSharing = true
        let (controller, environment) = makeController(
            sharingService: sharingService,
            virtualDisplayFacade: facade
        )
        let leaseID = DisplayRuntimeConsumerLeaseID(rawValue: UUID())
        let now = Date.now
        environment.displayRuntime.consumerLeasesByID[leaseID] = DisplayRuntimeConsumerLease(
            id: leaseID,
            surfaceIdentity: .managedVirtualDisplay(configID: config.id),
            surfaceEpoch: .initial,
            resolvedDisplayID: displayID,
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: "lan"),
            createdAt: now,
            updatedAt: now,
            state: .attached,
            demand: .init(
                capturesCursor: false,
                powerProfile: .automatic,
                latencyPreference: .realtime
            )
        )
        let item = makeItem(displayID: displayID, isRunning: true, isSharing: true)

        controller.performMenuBarAction(
            .toggleWebView,
            for: item,
            openPreviewWindow: { _ in }
        )

        let didReleaseLease = await waitUntil {
            environment.displayRuntime.consumerLeasesByID[leaseID]?.state == .released
                || environment.displayRuntime.consumerLeasesByID[leaseID] == nil
        }

        #expect(didReleaseLease)
    }

    private func makeController(
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

    private func makeConfig(desiredEnabled: Bool) -> VirtualDisplayConfig {
        VirtualDisplayConfig(
            displayName: "Menu Display",
            serialNum: 9_902,
            physicalWidth: 300,
            physicalHeight: 190,
            modes: [
                .init(width: 1_920, height: 1_080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: desiredEnabled
        )
    }

    private func makeItem(
        displayID: CGDirectDisplayID,
        isRunning: Bool,
        shareAddress: String? = nil,
        isSharing: Bool = false
    ) -> HomeVirtualDisplayItemPresentation {
        HomeVirtualDisplayItemPresentation(
            id: UUID(),
            displayID: displayID,
            shareAddress: shareAddress,
            title: "Menu Display",
            subtitle: "1920 × 1080",
            desiredEnabled: true,
            isRunning: isRunning,
            isPreviewing: true,
            isSharing: isSharing,
            viewerCount: 0,
            statusLabel: "Enabled",
            statusTone: .success,
            hasIssue: false,
            compactStatusItems: [],
            operationalStatusItems: [],
            accessibilitySummary: "Menu Display, Enabled"
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<2_000 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
