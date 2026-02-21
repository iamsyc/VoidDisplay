import Foundation

@MainActor
final class DisplayShareIDStore {
    private struct FileFormat: Codable {
        var schemaVersion: Int
        var mappings: [String: UInt32]

        init(schemaVersion: Int = 1, mappings: [String: UInt32]) {
            self.schemaVersion = schemaVersion
            self.mappings = mappings
        }
    }

    private let fileName = "shared-display-ids.json"
    private let fileManager: FileManager
    private let overrideStoreURL: URL?
    private var mappings: [String: UInt32] = [:]

    init(
        fileManager: FileManager = .default,
        storeURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.overrideStoreURL = storeURL

        do {
            let url = try resolvedStoreURL()
            guard fileManager.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(FileFormat.self, from: data)
            mappings = file.mappings
        } catch {
            AppErrorMapper.logFailure("Load shared display id store", error: error, logger: AppLog.persistence)
            mappings = [:]
        }
    }

    func assignID(for key: String) -> UInt32 {
        if let existing = mappings[key] {
            return existing
        }

        let next = nextAvailableID()
        mappings[key] = next
        persist()
        return next
    }

    private func nextAvailableID() -> UInt32 {
        let used = Set(mappings.values)
        var next: UInt32 = 1
        while used.contains(next) {
            next &+= 1
        }
        return next
    }

    private func persist() {
        do {
            let url = try resolvedStoreURL()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try JSONEncoder().encode(FileFormat(mappings: mappings))
            try data.write(to: url, options: [.atomic])
        } catch {
            AppErrorMapper.logFailure("Persist shared display id store", error: error, logger: AppLog.persistence)
        }
    }

    private func resolvedStoreURL() throws -> URL {
        if let overrideStoreURL {
            return overrideStoreURL
        }

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
