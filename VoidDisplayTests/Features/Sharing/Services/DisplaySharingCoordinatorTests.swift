import CoreGraphics
import Foundation
import Testing
@testable import VoidDisplay

@Suite(.serialized)
struct DisplaySharingCoordinatorTests {
    @MainActor
    @Test func virtualDisplaysUseDenseShareIDsWithoutPhysicalOffset() throws {
        let storeURL = temporaryStoreURL()
        let store = DisplayShareIDStore(storeURL: storeURL)
        let coordinator = DisplaySharingCoordinator(idStore: store)

        // Simulate a pre-existing physical mapping that previously consumed share ID 1.
        _ = store.assignID(for: "physical:mock-main")

        let physicalMain: CGDirectDisplayID = 100
        let virtualA: CGDirectDisplayID = 200
        let virtualB: CGDirectDisplayID = 300

        coordinator.registerShareableDisplays([
            .init(displayID: physicalMain, isMain: true, virtualSerial: nil),
            .init(displayID: virtualA, isMain: false, virtualSerial: 1),
            .init(displayID: virtualB, isMain: false, virtualSerial: 3)
        ])

        #expect(coordinator.shareID(for: virtualA) == 1)
        #expect(coordinator.shareID(for: virtualB) == 3)

        let physicalShareID = try #require(coordinator.shareID(for: physicalMain))
        #expect(!Set([UInt32(1), UInt32(3)]).contains(physicalShareID))
    }

    private func temporaryStoreURL() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("display-sharing-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        return base.appendingPathComponent("shared-display-ids.json", isDirectory: false)
    }
}
