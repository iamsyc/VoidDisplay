import Foundation
import VoidDisplayRuntime

package struct HomeDisplayDetectionState: Equatable {
    private struct Operation: Equatable {
        let id: UUID
        let previousCatalog: DisplayRuntimeCatalogSnapshot
    }

    private var operation: Operation?
    package private(set) var outcome = HomeDisplayDetectionPresentation.idle

    package var isScanning: Bool {
        operation != nil
    }

    package init() {}

    package mutating func begin(
        previousCatalog: DisplayRuntimeCatalogSnapshot
    ) -> UUID {
        let operationID = UUID()
        operation = Operation(
            id: operationID,
            previousCatalog: previousCatalog
        )
        outcome = .idle
        return operationID
    }

    package mutating func complete(
        operationID: UUID,
        refreshOutcome: DisplayRuntimeCatalogRefreshOutcome
    ) {
        guard operation?.id == operationID, let previousCatalog = operation?.previousCatalog else {
            return
        }
        operation = nil

        switch refreshOutcome.result {
        case .reloadedSnapshot, .reusedSnapshot:
            outcome = HomeDisplayDetectionPresentation.completion(
                previousCatalog: previousCatalog,
                currentCatalog: refreshOutcome.catalog
            )
        case .clearedSnapshot:
            outcome = .permissionRequired
        case .superseded:
            outcome = .failed
        case .failed:
            outcome = .failed
        }
    }

    package mutating func catalogRefreshDidStart() {
        outcome = .idle
    }

    package mutating func clearTransientOutcome(
        matching presentation: HomeDisplayDetectionPresentation
    ) {
        guard presentation.isTransient, outcome == presentation else { return }
        outcome = .idle
    }

    package mutating func invalidate() {
        operation = nil
        outcome = .idle
    }
}
