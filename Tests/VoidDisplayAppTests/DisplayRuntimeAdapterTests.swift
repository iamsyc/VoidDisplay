@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
import CoreGraphics
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeAdapterTests {
    @Test func catalogAdapterReturnsOnlyCurrentVisibleDisplayDTOs() {
        let hiddenDisplay = SharedMockSCDisplay.make(displayID: 8101, width: 1920, height: 1080)
        let visibleDisplay = SharedMockSCDisplay.make(displayID: 8102, width: 2560, height: 1440)
        let service = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [hiddenDisplay, visibleDisplay] },
            activeDisplayIDsProvider: { [visibleDisplay.displayID] }
        )
        service.store.displays = [hiddenDisplay, visibleDisplay]
        let sut = DisplayRuntimeCatalogAdapter(service: service)

        let displays = sut.currentVisibleDisplays()

        #expect(displays == [
            .init(displayID: visibleDisplay.displayID, pixelWidth: 2560, pixelHeight: 1440)
        ])
    }

    @Test func catalogAdapterRetainsScreenCaptureCatalogService() {
        let display = SharedMockSCDisplay.make(displayID: 8301, width: 1440, height: 900)
        var service: ScreenCaptureCatalogService? = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        service?.store.hasScreenCapturePermission = true
        service?.store.lastPreflightPermission = true
        service?.store.displays = [display]
        let sut = DisplayRuntimeCatalogAdapter(service: service!)

        service = nil

        let snapshot = sut.makeCatalogSnapshot()
        let visibleDisplays = sut.currentVisibleDisplays()

        #expect(snapshot.hasScreenCapturePermission == true)
        #expect(snapshot.lastPreflightPermission == true)
        #expect(snapshot.loadedDisplays == [
            .init(displayID: display.displayID, pixelWidth: 1440, pixelHeight: 900)
        ])
        #expect(visibleDisplays == [
            .init(displayID: display.displayID, pixelWidth: 1440, pixelHeight: 900)
        ])
    }

    @Test func sharingAdapterResolvesSCDisplayAndVirtualSerialInAppLayer() {
        let skippedDisplay = SharedMockSCDisplay.make(displayID: 8201, width: 1920, height: 1080)
        let registeredDisplay = SharedMockSCDisplay.make(displayID: 8202, width: 3840, height: 2160)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [skippedDisplay, registeredDisplay] },
            activeDisplayIDsProvider: { [registeredDisplay.displayID] }
        )
        catalogService.store.displays = [skippedDisplay, registeredDisplay]
        let sharingService = MockSharingService()
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        sut.registerShareableDisplays([
            .init(displayID: registeredDisplay.displayID, virtualSerialNumber: 9202)
        ])

        #expect(sharingService.registerShareableDisplaysCallCount == 1)
        #expect(sharingService.registeredShareableDisplays.map(\.displayID) == [registeredDisplay.displayID])
        #expect(sharingService.registeredVirtualSerialsByDisplayID[registeredDisplay.displayID] == 9202)
        #expect(sharingService.registeredVirtualSerialsByDisplayID[skippedDisplay.displayID] == nil)
    }

    @Test func sharingAdapterRestoreResolvesCatalogDisplayAndStartsSharing() async {
        let display = SharedMockSCDisplay.make(displayID: 8211, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[display.displayID] = 9211
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result == .restored)
        #expect(sharingService.startSharingCallCount == 1)
        #expect(sharingService.startedSharingDisplayIDs == [display.displayID])
    }

    @Test func sharingAdapterRestoreFailsWhenCatalogDisplayIsMissing() async {
        let display = SharedMockSCDisplay.make(displayID: 8212, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = []
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[display.displayID] = 9212
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .failed)
        #expect(result.failureReason == "display_not_found")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreSkipsWhenWebServiceIsStopped() async {
        let display = SharedMockSCDisplay.make(displayID: 8216, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = false
        sharingService.shareIDByDisplayID[display.displayID] = 9216
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .skipped)
        #expect(result.failureReason == "web_service_not_running")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreFailsWhenShareableRegistrationIsMissing() async {
        let display = SharedMockSCDisplay.make(displayID: 8213, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [display] },
            activeDisplayIDsProvider: { [display.displayID] }
        )
        catalogService.store.displays = [display]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let result = await sut.restoreSharing(displayID: display.displayID)

        #expect(result.status == .failed)
        #expect(result.failureReason == "shareable_display_not_registered")
        #expect(sharingService.startSharingCallCount == 0)
    }

    @Test func sharingAdapterRestoreMapsBeginSharingInvalidationAndFailure() async {
        struct ControlledError: Error {}

        let invalidatedDisplay = SharedMockSCDisplay.make(displayID: 8214, width: 2560, height: 1440)
        let failedDisplay = SharedMockSCDisplay.make(displayID: 8215, width: 2560, height: 1440)
        let catalogService = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [invalidatedDisplay, failedDisplay] },
            activeDisplayIDsProvider: { [invalidatedDisplay.displayID, failedDisplay.displayID] }
        )
        catalogService.store.displays = [invalidatedDisplay, failedDisplay]
        let sharingService = MockSharingService()
        sharingService.isWebServiceRunning = true
        sharingService.shareIDByDisplayID[invalidatedDisplay.displayID] = 9214
        sharingService.shareIDByDisplayID[failedDisplay.displayID] = 9215
        sharingService.startSharingHandler = { display in
            if display.displayID == invalidatedDisplay.displayID {
                return .invalidated
            }
            throw ControlledError()
        }
        let sharingController = SharingController(
            sharingService: sharingService,
            portPreferences: AdapterTestPortPreferences(),
            catalogService: catalogService
        )
        let sut = DisplayRuntimeSharingAdapter(controller: sharingController)

        let invalidatedResult = await sut.restoreSharing(displayID: invalidatedDisplay.displayID)
        let failedResult = await sut.restoreSharing(displayID: failedDisplay.displayID)

        #expect(invalidatedResult.status == .invalidated)
        #expect(invalidatedResult.failureReason == "sharing_start_invalidated")
        #expect(failedResult.status == .failed)
        #expect(sharingService.startedSharingDisplayIDs == [invalidatedDisplay.displayID, failedDisplay.displayID])
    }

    @Test func virtualDisplayAdapterRebuildCallsControllerCommandPath() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Adapter",
            serialNum: 9301,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8302
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.rebuildVirtualDisplay(configID: config.id)

        #expect(facade.rebuildVirtualDisplayCallCount == 1)
        #expect(facade.rebuildVirtualDisplayConfigIds == [config.id])
        #expect(result.configID == config.id)
        #expect(result.preDisplayID == 8302)
        #expect(result.postDisplayID == 8302)
    }
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}
