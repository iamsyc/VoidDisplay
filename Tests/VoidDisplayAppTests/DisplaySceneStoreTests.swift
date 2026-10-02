@testable import VoidDisplayApp
@testable import VoidDisplayFoundation
import Foundation
import Testing

@MainActor
struct DisplaySceneStoreTests {
    @Test func saveRoundTripsAndRetainsMissingDisplayReferences() throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        let saved = try fixture.store.save(name: "  Demo  ", enabledConfigIDs: [id, id])
        let loaded = DisplaySceneStore(context: fixture.context, fileURL: fixture.fileURL)
        #expect(loaded.scenes.first?.id == saved)
        #expect(loaded.scenes.first?.name == "Demo")
        #expect(loaded.scenes.first?.enabledConfigIDs == [id])
        #expect(!loaded.hasLoadFailure)
    }
    @Test func invalidFileBlocksSavingUntilExplicitReset() throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        try Data("broken file".utf8).write(to: fixture.fileURL)
        fixture.store.reload()
        #expect(fixture.store.hasLoadFailure)
        #expect(throws: (any Error).self) { try fixture.store.save(name: "Demo", enabledConfigIDs: [UUID()]) }
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8) == "broken file")
        try fixture.store.reset()
        #expect(!fixture.store.hasLoadFailure)
        #expect(fixture.store.scenes.isEmpty)
    }
    @Test func failedSaveKeepsLastPublishedAndPersistedValues() throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(name: "Original", enabledConfigIDs: [UUID()])
        let original = fixture.store.scenes
        let data = try Data(contentsOf: fixture.fileURL)
        let moved = fixture.root.appendingPathComponent("preserved")
        try FileManager.default.moveItem(at: fixture.fileURL.deletingLastPathComponent(), to: moved)
        try Data().write(to: fixture.fileURL.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try fixture.store.save(name: "Another", enabledConfigIDs: [UUID()]) }
        #expect(fixture.store.scenes == original)
        #expect(try Data(contentsOf: moved.appendingPathComponent("display-scenes.json")) == data)
        #expect(fixture.store.errorCategory == "write_failed")
    }
    @Test func rejectsDuplicateNamesCombinationsAndEmptySelection() throws {
        let fixture = try SceneStoreFixture()
        defer { fixture.remove() }
        let config = UUID()
        try fixture.store.save(name: "Demo", enabledConfigIDs: [config])
        #expect(throws: (any Error).self) { try fixture.store.save(name: "demo", enabledConfigIDs: [UUID()]) }
        #expect(throws: (any Error).self) { try fixture.store.save(name: "Other", enabledConfigIDs: [config]) }
        #expect(throws: (any Error).self) { try fixture.store.save(name: "Empty", enabledConfigIDs: []) }
        #expect(fixture.store.scenes.count == 1)
    }
}

@MainActor
struct SceneStoreFixture {
    let root: URL
    let context: PersistenceContext
    let fileURL: URL
    let store: DisplaySceneStore
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".ai-tmp/scene-store-tests/\(UUID().uuidString)")
        fileURL = root.appendingPathComponent("data/display-scenes.json")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        context = PersistenceContext.resolve(environment: [PersistenceContext.testIsolationIDEnvironmentKey: UUID().uuidString])
        store = DisplaySceneStore(context: context, fileURL: fileURL)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
