@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
import Foundation
import Testing

struct DisplayShareIDStoreTests {

    @MainActor @Test func idsRemainStableAcrossStoreRecreation() throws {
        let root = try uniqueTempDirectory()
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
    }

    private func uniqueTempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("display-share-id-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
