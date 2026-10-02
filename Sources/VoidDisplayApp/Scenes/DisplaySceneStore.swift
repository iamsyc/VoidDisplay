import Foundation
import Observation
import VoidDisplayFoundation

package struct DisplayScene: Codable, Equatable, Identifiable {
    package let id: UUID
    package var name: String
    package var enabledConfigIDs: [UUID]
}

package enum DisplaySceneStoreError: Error, LocalizedError {
    case invalidName, duplicateName, emptySelection, duplicateSelection, invalidFile, loadFailed, writeBlocked
    package var errorDescription: String? {
        switch self {
        case .invalidName: String(localized: "Use a scene name with 1 to 64 characters.")
        case .duplicateName: String(localized: "A scene already uses this name.")
        case .emptySelection: String(localized: "Select at least one display.")
        case .duplicateSelection: String(localized: "This display combination is already saved.")
        case .invalidFile, .loadFailed: String(localized: "Scenes could not be loaded. Reload or reset the scenes file before saving.")
        case .writeBlocked: String(localized: "The scenes file could not be saved.")
        }
    }
}

@MainActor @Observable
package final class DisplaySceneStore {
    private struct Document: Codable { var schemaVersion = 1; var scenes: [DisplayScene] }
    package private(set) var scenes: [DisplayScene] = []
    package private(set) var hasLoadFailure = false
    package private(set) var errorCategory: String?
    @ObservationIgnored private let context: PersistenceContext
    package let fileURL: URL

    package init(context: PersistenceContext, fileURL: URL? = nil) {
        self.context = context
        self.fileURL = fileURL ?? context.appSupportRootURL.appendingPathComponent("display-scenes.json")
        reload()
    }

    package func reload() {
        do {
            let values: [DisplayScene]
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
                guard document.schemaVersion == 1 else { throw DisplaySceneStoreError.invalidFile }
                try validate(document.scenes)
                values = document.scenes
            } else {
                values = []
            }
            scenes = values
            hasLoadFailure = false
            errorCategory = nil
        } catch {
            hasLoadFailure = true
            errorCategory = "load_failed"
        }
    }

    @discardableResult
    package func save(id: UUID? = nil, name: String, enabledConfigIDs: [UUID]) throws -> UUID {
        guard !hasLoadFailure else { throw DisplaySceneStoreError.loadFailed }
        let scene = DisplayScene(
            id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabledConfigIDs: enabledConfigIDs.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        )
        var values = scenes
        if let index = values.firstIndex(where: { $0.id == scene.id }) { values[index] = scene }
        else { values.append(scene) }
        try persist(values)
        return scene.id
    }

    package func delete(id: UUID) throws {
        guard !hasLoadFailure else { throw DisplaySceneStoreError.loadFailed }
        try persist(scenes.filter { $0.id != id })
    }

    package func reset() throws {
        try persist([])
        hasLoadFailure = false
    }

    private func persist(_ values: [DisplayScene]) throws {
        try validate(values)
        guard context.guardWriteAllowed(targetURL: fileURL, operation: "saveDisplayScenes") else {
            throw DisplaySceneStoreError.writeBlocked
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Document(scenes: values))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            scenes = values
            errorCategory = nil
        } catch {
            errorCategory = "write_failed"
            throw DisplaySceneStoreError.writeBlocked
        }
    }

    private func validate(_ values: [DisplayScene]) throws {
        var ids = Set<UUID>()
        var names = Set<String>()
        var selections = Set<Set<UUID>>()
        for scene in values {
            guard ids.insert(scene.id).inserted else { throw DisplaySceneStoreError.invalidFile }
            guard (1...64).contains(scene.name.count), scene.name == scene.name.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw DisplaySceneStoreError.invalidName
            }
            guard names.insert(scene.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))).inserted else {
                throw DisplaySceneStoreError.duplicateName
            }
            guard !scene.enabledConfigIDs.isEmpty else { throw DisplaySceneStoreError.emptySelection }
            guard Set(scene.enabledConfigIDs).count == scene.enabledConfigIDs.count else { throw DisplaySceneStoreError.invalidFile }
            guard selections.insert(Set(scene.enabledConfigIDs)).inserted else { throw DisplaySceneStoreError.duplicateSelection }
        }
    }
}
