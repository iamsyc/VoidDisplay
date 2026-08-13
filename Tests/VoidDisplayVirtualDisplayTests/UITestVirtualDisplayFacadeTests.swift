@testable import VoidDisplayVirtualDisplay
import Testing

@MainActor
struct UITestVirtualDisplayFacadeTests {
    @Test
    func runningFixtureUsesReservedDisplayIdentity() throws {
        let facade = UITestVirtualDisplayFacade()

        let managedDisplay = try #require(facade.snapshot.managedDisplays.first)

        #expect(managedDisplay.displayID == 0xF000_0001)
    }

    @Test
    func restoredFixturesUseEveryReservedDisplayIdentity() throws {
        let facade = UITestVirtualDisplayFacade()
        let configs = facade.snapshot.configs
        let runID = try #require(configs.first?.id)

        for config in configs {
            let result = facade.restoreVirtualDisplayForStartupCommand(
                VirtualDisplayStartupRestoreCommandRequest(
                    transactionID: config.id,
                    runID: runID,
                    configID: config.id
                )
            )
            #expect(result.restoreOutcome == .succeeded)
        }

        #expect(
            facade.snapshot.managedDisplays.map(\.displayID)
                == [0xF000_0001, 0xF000_0002]
        )
    }
}
