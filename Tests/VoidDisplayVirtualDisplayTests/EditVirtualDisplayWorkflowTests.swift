@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
@testable import VoidDisplayFoundation
import Foundation
import Testing

@Suite(.serialized)
@MainActor
struct EditVirtualDisplayWorkflowTests {
    @Test func loadReturnsMissingConfigAlertWhenConfigDoesNotExist() {
        let controller = makeController()

        let result = EditVirtualDisplayWorkflow.load(
            configId: UUID(),
            virtualDisplay: controller
        )

        guard case .missingConfig(let alert) = result else {
            Issue.record("Expected missing config alert.")
            return
        }
        #expect(alert.title == String(localized: "Error"))
        #expect(alert.message == String(localized: "Display configuration not found."))
    }

    @Test func actionLayoutMatchesRunningState() {
        #expect(EditVirtualDisplayWorkflow.actionLayout(isRunning: false) == .stopped)
        #expect(EditVirtualDisplayWorkflow.actionLayout(isRunning: true) == .running)
    }

    @Test func updateFailureLeavesPersistenceAlertForEditFlow() {
        let facade = MockVirtualDisplayFacade()
        let config = VirtualDisplayConfig(
            displayName: "Display",
            serialNum: 7,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        facade.currentDisplayConfigs = [config]
        facade.updateConfigError = VirtualDisplayOperationError.creationFailed
        let controller = makeController(facade: facade)

        #expect(throws: Error.self) {
            try controller.updateConfig(config)
        }
        #expect(controller.persistenceAlert?.title == String(localized: "Save Failed"))
        #expect(controller.persistenceAlert?.message.isEmpty == false)
    }

    private func makeController(
        facade: MockVirtualDisplayFacade = MockVirtualDisplayFacade()
    ) -> VirtualDisplayController {
        VirtualDisplayController(
            virtualDisplayFacade: facade,
            runtimeExecutors: testVirtualDisplayRuntimeExecutors(facade: facade),
            appliedBadgeDisplayDuration: .seconds(0.1)
        )
    }
}
