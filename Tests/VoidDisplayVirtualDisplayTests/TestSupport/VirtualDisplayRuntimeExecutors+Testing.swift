@testable import VoidDisplayVirtualDisplay
import Foundation

private struct UnimplementedVirtualDisplayRuntimeExecutor: Error {}

@MainActor
func testVirtualDisplayRuntimeExecutors(
    facade: any VirtualDisplayFacade,
    rebuild: VirtualDisplayRebuildExecutor? = nil,
    setDesiredEnabled: VirtualDisplayDesiredEnabledExecutor? = nil,
    editAndRebuild: VirtualDisplayEditRebuildExecutor? = nil,
    create: VirtualDisplayCreateExecutor? = nil,
    delete: VirtualDisplayDeleteExecutor? = nil
) -> VirtualDisplayRuntimeExecutors {
    VirtualDisplayRuntimeExecutors(
        rebuild: rebuild ?? { configID, _ in
            try await facade.rebuildVirtualDisplay(configId: configID)
        },
        setDesiredEnabled: setDesiredEnabled ?? { configID, enabled, _ in
            try facade.setDesiredEnabled(configID, enabled: enabled)
        },
        editAndRebuild: editAndRebuild ?? { _, _, _ in
            throw UnimplementedVirtualDisplayRuntimeExecutor()
        },
        create: create ?? { _ in
            throw UnimplementedVirtualDisplayRuntimeExecutor()
        },
        delete: delete ?? { configID in
            let result = try facade.deleteDisplayCommand(configID)
            return VirtualDisplayDeleteTransactionResult(
                transactionID: UUID(),
                status: .completed,
                configID: result.configID,
                virtualDisplayCommandSucceeded: result.virtualDisplayCommandOutcome == .succeeded
            )
        }
    )
}
