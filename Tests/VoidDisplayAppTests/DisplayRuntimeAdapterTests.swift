@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
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
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}
