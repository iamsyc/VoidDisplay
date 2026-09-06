@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

struct DisplayShareIDStoreTests {

    @MainActor @Test func idsRemainStableAcrossStoreRecreation() throws {
        let root = try makeTemporaryDirectory(prefix: "display-share-id-store-tests")
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("display-share-id-mappings.json", isDirectory: false)

        let firstStore = DisplayShareIDStore(storeURL: storeURL)
        let mainID = firstStore.assignID(for: "physical:main", excluding: [])
        let virtualID = firstStore.assignID(for: "virtual:42", excluding: [])

        let secondStore = DisplayShareIDStore(storeURL: storeURL)
        let mainIDReloaded = secondStore.assignID(for: "physical:main", excluding: [])
        let virtualIDReloaded = secondStore.assignID(for: "virtual:42", excluding: [])
        let newDisplayID = secondStore.assignID(for: "physical:new", excluding: [])

        #expect(mainIDReloaded == mainID)
        #expect(virtualIDReloaded == virtualID)
        #expect(newDisplayID != mainID)
        #expect(newDisplayID != virtualID)
        #expect(newDisplayID == max(mainID, virtualID) + 1)

        let reassignedMainID = secondStore.assignID(for: "physical:main", excluding: [mainID])
        #expect(reassignedMainID == newDisplayID + 1)
        let thirdStore = DisplayShareIDStore(storeURL: storeURL)
        #expect(thirdStore.assignID(for: "physical:main", excluding: [mainID]) == reassignedMainID)
    }
}
