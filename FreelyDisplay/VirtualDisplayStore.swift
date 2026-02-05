import Foundation

/// Persists virtual display configurations to disk.
struct VirtualDisplayStore {
    struct FileFormat: Codable {
        var schemaVersion: Int
        var configs: [VirtualDisplayConfig]

        init(schemaVersion: Int = 1, configs: [VirtualDisplayConfig]) {
            self.schemaVersion = schemaVersion
            self.configs = configs
        }
    }

    enum StoreError: Error {
        case missingContainerDirectory
    }

    private let fileName = "virtual-displays.json"

    func load() throws -> [VirtualDisplayConfig] {
        let url = try storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FileFormat.self, from: data)
        return decoded.configs
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        let url = try storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(configs: configs))
        try data.write(to: url, options: [.atomic])
    }

    private func storeURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "FreelyDisplay"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
