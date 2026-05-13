@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
import CoreGraphics
import Foundation
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

    @Test func virtualDisplayAdapterEnableUsesCommandOnlyPath() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Enable Adapter",
            serialNum: 9302,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: false
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.runtimeDisplayIDByConfigId[config.id] = 8303
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: true))
        let result = try await sut.enableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: nil)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.enableRuntimeDisplayConfigIDs == [config.id])
        #expect(facade.enableRuntimeDisplayCallCount == 1)
        #expect(result.desiredEnabled == true)
    }

    @Test func virtualDisplayAdapterDisableUsesCommandOnlyPath() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Disable Adapter",
            serialNum: 9303,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8304
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        _ = try await sut.setVirtualDisplayDesiredEnabled(request: .init(configID: config.id, enabled: false))
        let result = try await sut.disableVirtualDisplay(
            request: .init(configID: config.id, targetPreDisplayID: 8304)
        )

        #expect(facade.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigIDs == [config.id])
        #expect(facade.disableRuntimeDisplayByConfigCallCount == 1)
        #expect(result.desiredEnabled == false)
    }

    @Test func virtualDisplayAdapterSaveConfigForRebuildUsesCommandOnlyPathAndReturnsPreviousConfig() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Old Adapter Name",
            serialNum: 9304,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var edited = config
        edited.displayName = "New Adapter Name"
        edited.serialNum = 9305
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.saveConfigForRebuild(
            request: .init(
                editedConfig: editDTO(config: edited),
                expectedConfigFingerprint: config.editRebuildFingerprint,
                source: .editSaveAndRebuild
            )
        )

        #expect(facade.configForEditRebuildIDs == [config.id])
        #expect(facade.saveConfigForRebuildCallCount == 1)
        #expect(facade.savedConfigForRebuildIDs == [config.id])
        #expect(facade.updateConfigCallCount == 0)
        #expect(facade.currentDisplayConfigs.first?.displayName == "New Adapter Name")
        #expect(result.persistenceOutcome == .saved)
        #expect(result.previousConfigForCompensation.displayName == "Old Adapter Name")
        #expect(result.savedConfigEvidence.serialNumber == 9305)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterSaveConfigForRebuildDetectsStaleFingerprintBeforeSaving() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Stale Adapter Name",
            serialNum: 9306,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.self) {
            _ = try await sut.saveConfigForRebuild(
                request: .init(
                    editedConfig: editDTO(config: config),
                    expectedConfigFingerprint: "stale",
                    source: .editSaveAndRebuild
                )
            )
        }

        #expect(facade.configForEditRebuildIDs == [config.id])
        #expect(facade.saveConfigForRebuildCallCount == 0)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterCommandOnlySaveFailureDoesNotSetPersistenceAlert() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Save Failure",
            serialNum: 9307,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.saveConfigForRebuildError = NSError(domain: "CommandOnlySave", code: 7)
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        await #expect(throws: (any Error).self) {
            _ = try await sut.saveConfigForRebuild(
                request: .init(
                    editedConfig: editDTO(config: config),
                    expectedConfigFingerprint: config.editRebuildFingerprint,
                    source: .editSaveAndRebuild
                )
            )
        }

        #expect(facade.saveConfigForRebuildCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterRestoreConfigAfterFailedEditUsesPreviousConfigCommandPath() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Edited",
            serialNum: 9308,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var previous = config
        previous.displayName = "Previous"
        previous.serialNum = 9309
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.restoreConfigAfterFailedEdit(
            request: .init(
                transactionID: DisplayRuntimeTransactionID(),
                previousConfigForCompensation: editDTO(config: previous)
            )
        )

        #expect(result.persistenceOutcome == .rolledBack)
        #expect(facade.restoreConfigAfterFailedEditCallCount == 1)
        #expect(facade.restoredConfigAfterFailedEditIDs == [config.id])
        #expect(facade.updateConfigCallCount == 0)
        #expect(facade.currentDisplayConfigs.first?.displayName == "Previous")
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterCreateUsesCommandOnlyPathAndMapsFacts() async throws {
        let createdID = UUID()
        let facade = MockVirtualDisplayFacade()
        facade.createDisplayResult = .success(createdID)
        facade.runtimeDisplayIDByConfigId[createdID] = 8310
        facade.currentRunningConfigIds = [createdID]
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.createVirtualDisplay(
            request: runtimeCreateRequest(displayName: "Adapter Secret", serialNumber: 9310)
        )

        #expect(facade.createDisplayCommandCallCount == 1)
        #expect(facade.createDisplayCommandSerialNumbers == [9310])
        #expect(result.createdConfigID == createdID)
        #expect(result.persistenceOutcome == .saved)
        #expect(result.runtimeCreationOutcome == .succeeded)
        #expect(result.rollbackOutcome == .notAttempted)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterCreateReportsRollbackFailureWithoutSnapshotDiffGuessing() async throws {
        let createdID = UUID()
        let facade = MockVirtualDisplayFacade()
        facade.createDisplayResult = .failure(
            VirtualDisplayCreateCommandFailure(
                reason: "persistenceRecoveryFailed",
                result: VirtualDisplayCreateCommandResult(
                    createdConfigID: createdID,
                    serialNumber: 9311,
                    targetWasRunningAfterCommand: false,
                    preDisplayID: nil,
                    postDisplayID: nil,
                    persistenceOutcome: .rollbackFailed,
                    runtimeCreationOutcome: .failed,
                    rollbackOutcome: .rollbackFailed,
                    createdConfigEvidence: .init(
                        id: createdID,
                        serialNumber: 9311,
                        desiredEnabled: true,
                        physicalWidthMillimeters: 600,
                        physicalHeightMillimeters: 340,
                        modeCount: 1,
                        maximumPixelWidth: 1920,
                        maximumPixelHeight: 1080
                    ),
                    runningConfigIDsAfterCommand: [],
                    managedDisplaysAfterCommand: []
                ),
                underlyingError: NSError(domain: "Create", code: 11)
            )
        )
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        await #expect(throws: DisplayRuntimeVirtualDisplayCreateCommandError.self) {
            _ = try await sut.createVirtualDisplay(
                request: runtimeCreateRequest(displayName: "Adapter Rollback", serialNumber: 9311)
            )
        }
        #expect(facade.createDisplayCommandCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterDeleteUsesCommandOnlyPathAndMapsFacts() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Delete Adapter",
            serialNum: 9312,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8312
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        let result = try await sut.deleteVirtualDisplay(
            request: .init(
                transactionID: DisplayRuntimeTransactionID(),
                configID: config.id,
                targetPreDisplayID: 8312,
                targetWasRunning: true
            )
        )

        #expect(facade.destroyDisplayByConfigCallCount == 1)
        #expect(facade.destroyedConfigIDs == [config.id])
        #expect(result.targetWasRunning)
        #expect(result.preDisplayID == 8312)
        #expect(result.runtimeTrackingClearOutcome == .cleared)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterDeleteDoesNotMapMissingConfigToSuccess() async throws {
        let configID = UUID()
        let facade = MockVirtualDisplayFacade()
        facade.destroyDisplayError = VirtualDisplayDeleteCommandFailure(
            reason: "config_not_found",
            result: VirtualDisplayDeleteCommandResult(
                configID: configID,
                targetWasRunning: false,
                preDisplayID: nil,
                postDisplayID: nil,
                persistenceOutcome: .notAttempted,
                virtualDisplayCommandOutcome: .failed,
                runtimeTrackingClearOutcome: .notAttempted,
                runningConfigIDsAfterCommand: [],
                managedDisplaysAfterCommand: []
            ),
            underlyingError: NSError(domain: "Delete", code: 12)
        )
        let controller = VirtualDisplayController(
            virtualDisplayFacade: facade,
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller)

        await #expect(throws: DisplayRuntimeVirtualDisplayDeleteCommandError.self) {
            _ = try await sut.deleteVirtualDisplay(
                request: .init(
                    transactionID: DisplayRuntimeTransactionID(),
                    configID: configID,
                    targetPreDisplayID: nil,
                    targetWasRunning: false
                )
            )
        }
        #expect(facade.destroyDisplayByConfigCallCount == 1)
        #expect(controller.persistenceAlert == nil)
    }

    @Test func virtualDisplayAdapterUnavailableFailsExplicitly() async throws {
        var controller: VirtualDisplayController? = VirtualDisplayController(
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            appliedBadgeDisplayDuration: .nanoseconds(1)
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(controller: controller!)
        controller = nil

        await #expect(throws: (any Error).self) {
            _ = try await sut.enableVirtualDisplay(
                request: .init(configID: UUID(), targetPreDisplayID: nil)
            )
        }
    }
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

private func editDTO(config: VirtualDisplayConfig) -> DisplayRuntimeVirtualDisplayConfigEditDTO {
    let maxPixels = config.maxPixelDimensions
    return DisplayRuntimeVirtualDisplayConfigEditDTO(
        id: config.id,
        displayName: config.displayName,
        serialNumber: config.serialNum,
        desiredEnabled: config.desiredEnabled,
        physicalWidthMillimeters: UInt32(clamping: config.physicalWidth),
        physicalHeightMillimeters: UInt32(clamping: config.physicalHeight),
        modes: config.modes.map {
            .init(
                width: $0.width,
                height: $0.height,
                refreshRate: $0.refreshRate,
                enableHiDPI: $0.enableHiDPI
            )
        },
        maximumPixelWidth: maxPixels.width,
        maximumPixelHeight: maxPixels.height
    )
}

private func runtimeCreateRequest(
    displayName: String,
    serialNumber: UInt32
) -> DisplayRuntimeVirtualDisplayCreateRequest {
    .init(
        displayName: displayName,
        serialNumber: serialNumber,
        physicalWidthMillimeters: 600,
        physicalHeightMillimeters: 340,
        maximumPixelWidth: 1920,
        maximumPixelHeight: 1080,
        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
        source: .createVirtualDisplaySheet
    )
}
