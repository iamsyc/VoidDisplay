import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation

@MainActor
package final class DisplayShareIDStore {
    private struct FileFormat: Codable {
        var schemaVersion: Int
        var mappings: [String: UInt32]

        init(schemaVersion: Int = 1, mappings: [String: UInt32]) {
            self.schemaVersion = schemaVersion
            self.mappings = mappings
        }
    }

    private let fileManager: FileManager
    private let storeURL: URL
    private let persistenceContext: PersistenceContext
    private var mappings: [String: UInt32] = [:]

    package init(
        fileManager: FileManager = .default,
        storeURL: URL
    ) {
        self.fileManager = fileManager
        self.storeURL = storeURL
        self.persistenceContext = PersistenceContext.resolve(
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager
        )

        do {
            guard fileManager.fileExists(atPath: storeURL.path) else { return }
            let data = try Data(contentsOf: storeURL)
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            mappings = file.mappings
        } catch {
            AppErrorMapper.logFailure("Load shared display id store", error: error, logger: AppLog.persistence)
            mappings = [:]
        }
    }

    package func assignID(for key: String, excluding excludedIDs: Set<UInt32>) -> UInt32 {
        if let existing = mappings[key], !excludedIDs.contains(existing) {
            return existing
        }

        let next = nextAvailableID(excluding: excludedIDs)
        mappings[key] = next
        persist()
        return next
    }

    private func nextAvailableID(excluding excludedIDs: Set<UInt32>) -> UInt32 {
        let used = Set(mappings.values).union(excludedIDs)
        var next: UInt32 = 1
        while used.contains(next) {
            next &+= 1
        }
        return next
    }

    private func persist() {
        guard persistenceContext.guardWriteAllowed(
            targetURL: storeURL,
            operation: "Persist display share id mappings"
        ) else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(FileFormat(mappings: mappings))
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            AppErrorMapper.logFailure("Persist shared display id store", error: error, logger: AppLog.persistence)
        }
    }
}
