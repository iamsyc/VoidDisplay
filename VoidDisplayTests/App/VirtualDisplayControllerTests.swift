import Foundation
import Testing
import CoreGraphics
@testable import VoidDisplay

@MainActor
@Suite(.serialized)
struct AppBootstrapTests {
    @Test func initUsesDefaultCaptureMonitoringServiceWhenInjectionIsOmitted() async {
        let sharing = MockSharingService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.capture.screenCaptureSessions.isEmpty)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
    }

    @Test func initCapturePreviewDiagnosticsScenarioBuildsMonitoringSessionFromRuntimeConfiguration() async throws {
        let overrides = [
            (UITestRuntime.modeEnvironmentKey, "1"),
            (UITestRuntime.scenarioEnvironmentKey, UITestScenario.capturePreviewDiagnostics.rawValue),
            (CapturePreviewDiagnosticsRuntime.sourceSizeEnvironmentKey, "3008x1692")
        ]
        let previousValues = overrides.map { ($0.0, ProcessInfo.processInfo.environment[$0.0]) }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let env = AppBootstrap.makeEnvironment()

        let session = try #require(env.capture.screenCaptureSessions.first)
        #expect(env.capture.screenCaptureSessions.count == 1)
        #expect(session.displayName == "Preview Diagnostics")
        #expect(session.resolutionText == "3008 × 1692")
        #expect(session.capturesCursor == false)
        #expect(env.virtualDisplay.displayConfigs.count == 2)
    }

    @Test func previewEnvironmentDoesNotPersistPreferredPortToStandardDefaults() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        sharing.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))

        let defaults = UserDefaults.standard
        let key = "sharing.preferredPort"
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        _ = await env.sharing.startWebService(requestedPort: requestedPort)

        let currentValue = defaults.object(forKey: key)
        let valuesMatch: Bool
        if let previousObject = previousValue as? NSObject,
           let currentObject = currentValue as? NSObject {
            valuesMatch = previousObject.isEqual(currentObject)
        } else {
            valuesMatch = previousValue == nil && currentValue == nil
        }
        #expect(valuesMatch)
    }

    @Test func initPreviewModeSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        _ = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
    }

    @Test func initUITestModeAppliesFixtureAndSkipsServiceBoot() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = UITestVirtualDisplayFacade(scenario: .baseline)

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true,
                postRestoreConfiguration: nil
            ),
            isRunningUnderXCTestOverride: false
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.count == 2)
        #expect(sut.virtualDisplay.runningConfigIds.count == 1)
    }

    @Test func initRunningUnderXCTestSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 0)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.isEmpty)
    }

    @Test func initNormalModeLoadsPersistedDataWithoutStartingWebService() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let fixtureConfig = VirtualDisplayConfig(
            displayName: "Fixture",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [fixtureConfig]

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(virtualDisplay.restoreDesiredVirtualDisplaysCallCount == 1)
        #expect(sut.virtualDisplay.displayConfigs.count == 1)
        #expect(sut.virtualDisplay.displayConfigs.first?.id == fixtureConfig.id)
        #expect(sut.virtualDisplay.displayConfigs.first?.serialNum == fixtureConfig.serialNum)
    }

    @Test func controllerExposesConfigStoreLoadFailureState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.configStoreState = .loadFailed(
            error: .unsupportedSchemaVersion(expected: 3, actual: 2),
            diagnostics: .init(
                primaryStoreURL: URL(fileURLWithPath: "/tmp/virtual-displays.json"),
                isTestIsolatedPath: true
            )
        )

        let env = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        env.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        #expect(env.virtualDisplay.configStorePresentation.hasLoadFailure)
        #expect(
            env.virtualDisplay.configStorePresentation.loadErrorMessage
                == VirtualDisplayConfigStoreError
                .unsupportedSchemaVersion(expected: 3, actual: 2)
                .userFacingMessage
        )
        #expect(env.virtualDisplay.configStorePresentation.diagnosticsSummary?.contains("primary=/tmp/virtual-displays.json") == true)
    }

    @Test func rebuildFromSavedConfigDoesNotApplyModesAgainAfterRebuild() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Running",
            serialNum: 7,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }
        let rebuildPresentationSettled = await waitUntil {
            !sut.virtualDisplay.isRebuilding(configId: config.id)
        }

        #expect(rebuildTriggered)
        #expect(rebuildPresentationSettled)
        #expect(virtualDisplay.rebuildVirtualDisplayConfigIds == [config.id])
        #expect(virtualDisplay.applyModesCallCount == 0)
    }

    @Test func startRebuildStopsDependentSharingAndMonitoringForRuntimeDisplay() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Main Candidate",
            serialNum: 9,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let displayID: CGDirectDisplayID = 4321

        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]
        virtualDisplay.runtimeDisplayIDByConfigId[config.id] = displayID
        sharing.activeSharingDisplayIDs = [displayID]

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuildTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }

        #expect(rebuildTriggered)
        #expect(sharing.stopSharingCallCount == 1)
        #expect(capture.removeByDisplayCallCount == 1)
        #expect(capture.removedDisplayIDs == [displayID])
    }

    @Test func startRebuildIgnoresConcurrentDuplicateRequests() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.rebuildDelayNanoseconds = 150_000_000

        let config = VirtualDisplayConfig(
            displayName: "Concurrent",
            serialNum: 10,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)
        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let onlyOnceTriggered = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 1
        }
        #expect(onlyOnceTriggered)

        let settled = await waitUntil {
            !sut.virtualDisplay.isRebuilding(configId: config.id)
        }
        #expect(settled)
    }

    @Test func rebuildFailureRetryAndAppliedBadgeLifecycle() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let config = VirtualDisplayConfig(
            displayName: "Retry",
            serialNum: 11,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]
        virtualDisplay.rebuildVirtualDisplayError = NSError(domain: "test", code: 33)

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            appliedBadgeDisplayDuration: .milliseconds(50),
            isRunningUnderXCTestOverride: true
        )

        sut.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let failed = await waitUntil {
            sut.virtualDisplay.rebuildFailureMessage(configId: config.id) != nil
        }
        #expect(failed)
        #expect(sut.virtualDisplay.hasRecentApplySuccess(configId: config.id) == false)

        virtualDisplay.rebuildVirtualDisplayError = nil
        sut.virtualDisplay.retryRebuild(configId: config.id)

        let retried = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayCallCount == 2
        }
        #expect(retried)

        let successPresented = await waitUntil {
            sut.virtualDisplay.hasRecentApplySuccess(configId: config.id)
        }
        #expect(successPresented)
        #expect(sut.virtualDisplay.rebuildFailureMessage(configId: config.id) == nil)

        let successCleared = await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !sut.virtualDisplay.hasRecentApplySuccess(configId: config.id)
        }
        #expect(successCleared)
    }

    @Test func moveDisplayConfigTriggersMainDisplayPolicyReconcile() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        virtualDisplay.currentDisplayConfigs = [
            VirtualDisplayConfig(
                displayName: "A",
                serialNum: 1,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            ),
            VirtualDisplayConfig(
                displayName: "B",
                serialNum: 2,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        ]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let moved = try sut.virtualDisplay.moveDisplayConfig(
            virtualDisplay.currentDisplayConfigs[1].id,
            direction: .up
        )
        #expect(moved)

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func moveDisplayConfigSkipsReconcileWhenFirstEnabledConfigDoesNotChange() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var configC = VirtualDisplayConfig(
            displayName: "C",
            serialNum: 3,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        configA.desiredEnabled = true
        configB.desiredEnabled = true
        configC.desiredEnabled = true
        virtualDisplay.currentDisplayConfigs = [configA, configB, configC]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )
        sut.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let moved = try sut.virtualDisplay.moveDisplayConfig(configC.id, direction: .up)
        #expect(moved)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingMovesTargetToFirstEnabledAndReconciles() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 9,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, configA, configB]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configB.id)
        #expect(changed)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, configB.id, configA.id])
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionIDs == [configB.id])

        let reconciled = await waitUntil {
            virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 1
        }
        #expect(reconciled)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenAlreadyFirstEnabled() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [configA, configB]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(configA.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func setPrimaryVirtualDisplayByReorderingNoOpsWhenTargetDisabled() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.moveConfigResult = true
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let enabled = VirtualDisplayConfig(
            displayName: "Enabled",
            serialNum: 2,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, enabled]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let changed = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(disabled.id)
        #expect(changed == false)
        #expect(virtualDisplay.moveConfigToFirstEnabledPositionCallCount == 1)
        #expect(virtualDisplay.currentDisplayConfigs.map(\.id) == [disabled.id, enabled.id])

        await drainMainActorTasks()
        #expect(virtualDisplay.reconcileMainDisplayPolicyIfNeededCallCount == 0)
    }

    @Test func sharingFacadeMethodsDelegateAndExposeState() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let displayID: CGDirectDisplayID = 7101
        let target = ShareTarget.id(99)
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        sharing.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))
        sharing.activeStreamClientCount = 3
        sharing.activeSharingDisplayIDs = [displayID]
        sharing.hasAnyActiveSharing = true
        sharing.shareIDByDisplayID[displayID] = 99
        sharing.shareTargetByDisplayID[displayID] = target
        sharing.streamClientCountsByTarget[target] = 3

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let started = await sut.sharing.startWebService(requestedPort: requestedPort)
        #expect(started == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        #expect(sut.sharing.isWebServiceRunning)
        #expect(sut.sharing.isSharing)
        #expect(sut.sharing.isDisplaySharing(displayID: displayID))
        #expect(sut.sharing.sharePagePath(for: displayID) == "/display/99")

        sut.sharing.refreshSharingClientCount()
        #expect(sut.sharing.sharingClientCount == 3)
        #expect(sut.sharing.sharingClientCounts[displayID] == 3)

        // Uses facade path that should fail early when service is down.
        sut.sharing.stopWebService()
        let shareURLResult = sut.sharing.sharePageURLResolution(for: displayID)
        #expect(shareURLResult == .failure(.serviceNotRunning))
    }

    @Test func virtualDisplayFacadeResetDelegatesToOrchestrator() throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        virtualDisplay.currentDisplayConfigs = [
            VirtualDisplayConfig(
                displayName: "Cleanup",
                serialNum: 123,
                physicalWidth: 300,
                physicalHeight: 200,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                desiredEnabled: true
            )
        ]

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let removed = try sut.virtualDisplay.resetVirtualDisplayData()
        #expect(removed == 1)
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
    }

    @Test func virtualDisplayFacadeResetPropagatesFailureWithoutClearingControllerState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Keep State",
            serialNum: 124,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.resetAllVirtualDisplayDataError = NSError(domain: "VirtualDisplayControllerTests", code: 70)

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.resetVirtualDisplayData()
        }
        #expect(virtualDisplay.resetAllVirtualDisplayDataCallCount == 1)
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [config.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func updateConfigPropagatesFacadeFailureWithoutMutatingControllerState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Original",
            serialNum: 125,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.updateConfigError = NSError(domain: "VirtualDisplayControllerTests", code: 71)

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        var updated = config
        updated.displayName = "Updated"

        #expect(throws: Error.self) {
            try sut.virtualDisplay.updateConfig(updated)
        }
        #expect(sut.virtualDisplay.displayConfigs.first?.displayName == "Original")
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func createDisplayPropagatesFailureAndSetsPersistencePresentation() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let existing = VirtualDisplayConfig(
            displayName: "Existing",
            serialNum: 126,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [existing]
        virtualDisplay.createDisplayResult = .failure(
            NSError(domain: "VirtualDisplayControllerTests", code: 72)
        )

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.createDisplay(
                name: "New",
                serialNum: 127,
                physicalSize: CGSize(width: 300, height: 200),
                maxPixels: (width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [existing.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func createDisplayRollbackFailureUsesLocalizedPersistenceRecoveryErrorMessage() {
        let store = FakeVirtualDisplayStore()
        store.scriptedSaveErrors = [
            nil,
            VirtualDisplayConfigStoreError.ioFailed(
                operation: "save",
                underlying: NSError(domain: "VirtualDisplayControllerTests", code: 76)
            )
        ]
        let orchestrator = VirtualDisplayOrchestrator(
            configRepository: VirtualDisplayConfigRepository(store: store, reportFailure: nil),
            displayReconfigurationMonitor: FakeDisplayReconfigurationMonitor(),
            managedDisplayOnlineChecker: { _ in false },
            runtimeDriver: ControllerTestRuntimeDriver(
                scriptedResults: [.failure(VirtualDisplayOperationError.creationFailed)]
            ),
            clock: nil
        )

        let sut = VirtualDisplayController(
            virtualDisplayFacade: orchestrator,
            appliedBadgeDisplayDuration: .nanoseconds(1),
            stopDependentStreamsBeforeRebuild: { _ in }
        )

        #expect(throws: Error.self) {
            _ = try sut.createDisplay(
                name: "New",
                serialNum: 200,
                physicalSize: CGSize(width: 300, height: 200),
                maxPixels: (width: 1920, height: 1080),
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        }
        #expect(sut.persistenceAlert != nil)
        #expect(
            sut.persistenceAlert?.message ==
                String(
                    localized: "Create failed and the config rollback could not be saved. Check config file permissions or reset the config file."
                )
        )
        #expect(sut.displayConfigs.count == 1)
    }

    @Test func moveDisplayConfigPropagatesFailureAndSetsPersistencePresentation() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let configA = VirtualDisplayConfig(
            displayName: "A",
            serialNum: 127,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let configB = VirtualDisplayConfig(
            displayName: "B",
            serialNum: 128,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [configA, configB]
        virtualDisplay.moveConfigError = NSError(domain: "VirtualDisplayControllerTests", code: 73)

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.moveDisplayConfig(configB.id, direction: .up)
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [configA.id, configB.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func setPrimaryVirtualDisplayByReorderingPropagatesFailureAndSetsPersistencePresentation() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        var disabled = VirtualDisplayConfig(
            displayName: "Disabled",
            serialNum: 129,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let enabled = VirtualDisplayConfig(
            displayName: "Enabled",
            serialNum: 130,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        disabled.desiredEnabled = false
        virtualDisplay.currentDisplayConfigs = [disabled, enabled]
        virtualDisplay.moveConfigToFirstEnabledPositionError = NSError(
            domain: "VirtualDisplayControllerTests",
            code: 74
        )

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.setPrimaryVirtualDisplayByReordering(enabled.id)
        }
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [disabled.id, enabled.id])
        #expect(sut.virtualDisplay.persistenceAlert != nil)
        #expect(sut.virtualDisplay.persistenceAlert?.message.isEmpty == false)
    }

    @Test func dismissPersistenceAlertResetsControllerPresentationState() {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.resetAllVirtualDisplayDataError = NSError(domain: "VirtualDisplayControllerTests", code: 75)

        let sut = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(throws: Error.self) {
            _ = try sut.virtualDisplay.resetVirtualDisplayData()
        }
        #expect(sut.virtualDisplay.persistenceAlert != nil)

        sut.virtualDisplay.dismissPersistenceAlert()

        #expect(sut.virtualDisplay.persistenceAlert == nil)
    }
}

@MainActor
private final class FakeDisplayReconfigurationMonitor: DisplayReconfigurationMonitoring {
    @discardableResult
    func start(handler: @escaping @MainActor () -> Void) -> Bool {
        handler()
        return true
    }

    func stop() {}
}

@MainActor
private final class ControllerTestRuntimeDriver: VirtualDisplayRuntimeDriving {
    enum CreateResult {
        case success(serialNum: UInt32, displayID: CGDirectDisplayID)
        case failure(Error)
    }

    private let scriptedResults: [CreateResult]
    private var nextIndex = 0

    init(scriptedResults: [CreateResult]) {
        self.scriptedResults = scriptedResults
    }

    func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        _ = maxPixels
        _ = onTermination
        let result: CreateResult
        if scriptedResults.indices.contains(nextIndex) {
            result = scriptedResults[nextIndex]
        } else {
            result = .success(serialNum: config.serialNum, displayID: 20_000)
        }
        nextIndex += 1

        switch result {
        case .success(let serialNum, let displayID):
            return ControllerTestRuntimeHandle(serialNum: serialNum, displayID: displayID)
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
private final class ControllerTestRuntimeHandle: VirtualDisplayRuntimeHandling {
    let serialNum: UInt32
    let displayID: CGDirectDisplayID

    init(serialNum: UInt32, displayID: CGDirectDisplayID) {
        self.serialNum = serialNum
        self.displayID = displayID
    }

    func applyModes(_ modes: [ResolutionSelection]) -> Bool {
        !modes.isEmpty
    }
}
