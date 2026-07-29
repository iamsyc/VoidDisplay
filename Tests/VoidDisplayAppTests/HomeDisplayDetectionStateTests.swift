@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import Foundation
import Testing

@Suite
struct HomeDisplayDetectionStateTests {
    @Test func failedRefreshReportsRecoverableFailure() {
        let catalog = catalog(displayIDs: [1001])
        var state = HomeDisplayDetectionState()
        let operationID = state.begin(previousCatalog: catalog)

        state.complete(
            operationID: operationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .failed,
                catalog: catalog
            )
        )

        #expect(!state.isScanning)
        #expect(state.outcome == .failed)
    }

    @Test func staleCompletionCannotOverwriteNewerOperation() {
        let initialCatalog = catalog(displayIDs: [1001])
        var state = HomeDisplayDetectionState()
        let staleOperationID = state.begin(previousCatalog: initialCatalog)
        let currentOperationID = state.begin(previousCatalog: initialCatalog)

        state.complete(
            operationID: staleOperationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .reloadedSnapshot,
                catalog: catalog(displayIDs: [1001, 1002])
            )
        )

        #expect(state.isScanning)
        #expect(state.outcome == .idle)

        state.complete(
            operationID: currentOperationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .reusedSnapshot,
                catalog: initialCatalog
            )
        )

        #expect(!state.isScanning)
        #expect(state.outcome == .upToDate(displayCount: 1))
    }

    @Test func unresolvedSupersededRefreshReportsRecoverableFailure() {
        let initialCatalog = catalog(displayIDs: [1001])
        var state = HomeDisplayDetectionState()
        let operationID = state.begin(previousCatalog: initialCatalog)

        state.complete(
            operationID: operationID,
            refreshOutcome: .init(
                settlementID: nil,
                result: .superseded,
                catalog: initialCatalog
            )
        )

        #expect(!state.isScanning)
        #expect(state.outcome == .failed)
    }

    @Test func invalidationRejectsLateCompletion() {
        let initialCatalog = catalog(displayIDs: [1001])
        var state = HomeDisplayDetectionState()
        let operationID = state.begin(previousCatalog: initialCatalog)

        state.invalidate()
        state.complete(
            operationID: operationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .reloadedSnapshot,
                catalog: catalog(displayIDs: [1001, 1002])
            )
        )

        #expect(!state.isScanning)
        #expect(state.outcome == .idle)
    }

    @Test func externalCatalogRefreshClearsTransientCompletion() {
        let initialCatalog = catalog(displayIDs: [1001])
        var state = HomeDisplayDetectionState()
        let operationID = state.begin(previousCatalog: initialCatalog)
        state.complete(
            operationID: operationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .reusedSnapshot,
                catalog: initialCatalog
            )
        )
        #expect(state.outcome == .upToDate(displayCount: 1))

        state.catalogRefreshDidStart()

        #expect(state.outcome == .idle)
    }

    @Test func permissionClearReportsRequiredPermission() {
        let initialCatalog = catalog(displayIDs: [1001])
        let deniedCatalog = catalog(permissionGranted: false, displayIDs: [])
        var state = HomeDisplayDetectionState()
        let operationID = state.begin(previousCatalog: initialCatalog)

        state.complete(
            operationID: operationID,
            refreshOutcome: .init(
                settlementID: 1,
                result: .clearedSnapshot,
                catalog: deniedCatalog
            )
        )

        #expect(!state.isScanning)
        #expect(state.outcome == .permissionRequired)
    }

    private func catalog(
        permissionGranted: Bool? = true,
        displayIDs: [DisplayRuntimeDisplayID]
    ) -> DisplayRuntimeCatalogSnapshot {
        DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: permissionGranted,
            lastPreflightPermission: permissionGranted,
            lastRequestPermission: nil,
            isLoadingDisplays: false,
            hasLoadError: false,
            lastLoadError: nil,
            loadedDisplays: displayIDs.map {
                DisplayRuntimeCatalogDisplay(
                    displayID: $0,
                    pixelWidth: 1920,
                    pixelHeight: 1080
                )
            },
            topologySignature: []
        )
    }
}
