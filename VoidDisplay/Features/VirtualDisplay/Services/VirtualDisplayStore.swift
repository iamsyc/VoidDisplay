import Foundation

/// Persists virtual display configurations to disk.
struct VirtualDisplayStore {
    struct FileFormat: Codable {
        static let currentSchemaVersion = 2

        var schemaVersion: Int
        var configs: [VirtualDisplayConfig]

        init(schemaVersion: Int = FileFormat.currentSchemaVersion, configs: [VirtualDisplayConfig]) {
            self.schemaVersion = schemaVersion
            self.configs = configs
        }
    }

    enum StoreError: Error {
        case missingContainerDirectory
    }

    private let fileName = "virtual-displays.json"
    private let defaultPhysicalWidth = 310
    private let defaultPhysicalHeight = 174
    private let defaultMode = VirtualDisplayConfig.ModeConfig(
        width: 1920,
        height: 1080,
        refreshRate: 60,
        enableHiDPI: true
    )

    func load() throws -> [VirtualDisplayConfig] {
        let url = try storeURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let data = try Data(contentsOf: url)
        return try decodeConfigs(from: data)
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        let url = try storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(configs: sanitize(configs)))
        try data.write(to: url, options: [.atomic])
    }

    func reset() throws {
        let url = try storeURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    func decodeConfigs(from data: Data) throws -> [VirtualDisplayConfig] {
        let decoder = JSONDecoder()
        let wrapped = try decoder.decode(FileFormat.self, from: data)
        return sanitize(wrapped.configs)
    }

    private func storeURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func sanitize(_ configs: [VirtualDisplayConfig]) -> [VirtualDisplayConfig] {
        var result: [VirtualDisplayConfig] = []
        var usedSerials: Set<UInt32> = []
        var usedIDs: Set<UUID> = []

        for config in configs {
            var serial = config.serialNum
            if serial == 0 || usedSerials.contains(serial) {
                serial = nextAvailableSerial(used: usedSerials)
            }
            usedSerials.insert(serial)

            var id = config.id
            if usedIDs.contains(id) {
                id = UUID()
            }
            usedIDs.insert(id)

            let filteredModes = config.modes.filter {
                $0.width > 0 && $0.height > 0 && $0.refreshRate > 0
            }
            let modes = filteredModes.isEmpty ? [defaultMode] : filteredModes
            let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Virtual Display \(serial)"
                : config.name
            let physicalWidth = config.physicalWidth > 0 ? config.physicalWidth : defaultPhysicalWidth
            let physicalHeight = config.physicalHeight > 0 ? config.physicalHeight : defaultPhysicalHeight

            result.append(
                VirtualDisplayConfig(
                    id: id,
                    name: name,
                    serialNum: serial,
                    physicalWidth: physicalWidth,
                    physicalHeight: physicalHeight,
                    modes: modes,
                    desiredEnabled: config.desiredEnabled
                )
            )
        }

        return result
    }

    private func nextAvailableSerial(used: Set<UInt32>) -> UInt32 {
        var next: UInt32 = 1
        while used.contains(next) {
            next += 1
        }
        return next
    }
}
