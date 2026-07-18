@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayRuntime
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplayTestingSupport
import Darwin
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct AppBootstrapTests {
    @Test func singleInstanceGuardBuildsStableSanitizedLockFileName() {
        #expect(
            AppSingleInstanceGuard.lockFileName(bundleIdentifier: "com.developerchen.voiddisplay")
                == "com.developerchen.voiddisplay.single-instance.lock"
        )
        #expect(
            AppSingleInstanceGuard.lockFileName(bundleIdentifier: "com developerchen/voiddisplay")
                == "com_developerchen_voiddisplay.single-instance.lock"
        )
        #expect(
            AppSingleInstanceGuard.lockFileName(bundleIdentifier: nil)
                == "voiddisplay.single-instance.lock"
        )
    }

    @Test func singleInstanceGuardClassifiesAcquiredLock() {
        #expect(
            AppSingleInstanceGuard.classifyLockAttempt(
                openedDescriptor: 42,
                flockResult: 0,
                errorCode: 0
            ) == .acquired
        )
    }

    @Test func singleInstanceGuardClassifiesOpenFailureWithoutTreatingItAsContention() {
        #expect(
            AppSingleInstanceGuard.classifyLockAttempt(
                openedDescriptor: -1,
                flockResult: nil,
                errorCode: EACCES
            ) == .failed(errorCode: EACCES)
        )
    }

    @Test func singleInstanceGuardClassifiesHeldLockSeparatelyFromFlockFailure() {
        #expect(
            AppSingleInstanceGuard.classifyLockAttempt(
                openedDescriptor: 42,
                flockResult: -1,
                errorCode: EWOULDBLOCK
            ) == .heldByOtherInstance
        )
        #expect(
            AppSingleInstanceGuard.classifyLockAttempt(
                openedDescriptor: 42,
                flockResult: -1,
                errorCode: EPERM
            ) == .failed(errorCode: EPERM)
        )
    }

    @Test func initRegistersRuntimeSnapshotProvider() async throws {
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            capturePreviewService: MockCapturePreviewService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: true
        )

        await env.waitForStartupTasks()
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let runtime = try runtimeSection.decode(DisplayRuntimeSnapshot.self)

        #expect(runtime.schemaVersion == 4)
        #expect(diagnostics.state.sections["system"] != nil)
        #expect(diagnostics.state.sections["persistence"] != nil)
        #expect(diagnostics.state.sections["capture"] == nil)
        #expect(diagnostics.state.sections["sharing"] == nil)
        #expect(diagnostics.state.sections["virtualDisplay"] == nil)
        #expect(diagnostics.state.sections["screenCatalog"] == nil)
    }

    @Test func previewEnvironmentDoesNotPersistPreferredPortToStandardDefaults() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let sharing = MockSharingService()
        let capture = MockCapturePreviewService()
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
            capturePreviewService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        let startResult = await env.sharing.startWebService(requestedPort: requestedPort)

        #expect(startResult == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
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

    @Test func initUITestModeAppliesFixtureAndSkipsServiceBoot() async {
        let sharing = MockSharingService()
        let capture = MockCapturePreviewService()
        let virtualDisplay = UITestVirtualDisplayFacade()

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            capturePreviewService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true
            ),
            isRunningUnderXCTestOverride: false
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.count == 2)
        #expect(sut.virtualDisplay.runningConfigIds.count == 1)
    }

    @Test func initNormalModeHydratesVirtualDisplayConfigsBeforeStartupTaskCompletes() async {
        let sharing = MockSharingService()
        let capture = MockCapturePreviewService()
        let virtualDisplay = MockVirtualDisplayFacade()
        let fixtureConfig = VirtualDisplayConfig(
            displayName: "Named Startup Display",
            serialNum: 13,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [fixtureConfig]
        virtualDisplay.runtimeDisplayIDByConfigId[fixtureConfig.id] = 10_013

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            capturePreviewService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(sut.virtualDisplay.displayConfigs.map(\.id) == [fixtureConfig.id])
        #expect(sut.virtualDisplay.displayConfigs.map(\.displayName) == ["Named Startup Display"])
        await sut.waitForStartupTasks()
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
    }

    @Test func initNormalModeKeepsObservabilityInTestIsolationWhenRunningUnderXCTest() async {
        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            capturePreviewService: MockCapturePreviewService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: false
        )

        let dataDirectoryURL = await sut.observability.dataDirectoryURL()
        #expect(dataDirectoryURL?.path.contains(".tests") == true)
    }

    @Test func initNormalModeRestoresStartupVirtualDisplaysThroughRuntimeWithoutStartingWebService() async throws {
        let sharing = MockSharingService()
        let capture = MockCapturePreviewService()
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
        virtualDisplay.runtimeDisplayIDByConfigId[fixtureConfig.id] = 10_001

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            capturePreviewService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )
        await sut.waitForStartupTasks()
        let startupTrace = try #require(
            sut.displayRuntime.makeSnapshot().transactions.recentTransactions.first {
                $0.kind == .virtualDisplayStartupRestore
            }
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(virtualDisplay.startupRestoreCommandRequests.map(\.configID) == [fixtureConfig.id])
        #expect(startupTrace.source == .startup)
        #expect(sut.virtualDisplay.displayConfigs.count == 1)
        #expect(sut.virtualDisplay.displayConfigs.first?.id == fixtureConfig.id)
        #expect(sut.virtualDisplay.displayConfigs.first?.serialNum == fixtureConfig.serialNum)
        #expect(sut.virtualDisplay.runningConfigIds == [fixtureConfig.id])
    }
}
