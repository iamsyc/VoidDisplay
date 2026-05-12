@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayRuntime
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

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

    @Test func initRegistersRuntimeSnapshotProvider() async throws {
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: true
        )

        await env.waitForStartupObservability()
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let runtime = try runtimeSection.decode(DisplayRuntimeSnapshot.self)

        #expect(runtime.schemaVersion == 1)
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
}
