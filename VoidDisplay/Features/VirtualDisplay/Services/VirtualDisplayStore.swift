import Foundation

struct VirtualDisplayStoreDiagnostics {
    let primaryStoreURL: URL
    let isTestIsolatedPath: Bool

    var summary: String {
        [
            "primary=\(primaryStoreURL.path)",
            "testIsolated=\(isTestIsolatedPath)"
        ]
        .joined(separator: " | ")
    }
}

enum VirtualDisplayConfigStoreError: Error {
    case unsupportedSchemaVersion(expected: Int, actual: Int)
    case decodingFailed(underlying: Error)
    case ioFailed(operation: String, underlying: Error)
}

extension VirtualDisplayConfigStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let expected, let actual):
            return "Unsupported virtual display config schema version \(actual). Expected \(expected)."
        case .decodingFailed(let underlying):
            return "Failed to decode virtual display config file: \(underlying.localizedDescription)"
        case .ioFailed(let operation, let underlying):
            return "Virtual display config \(operation) failed: \(underlying.localizedDescription)"
        }
    }
}

extension VirtualDisplayConfigStoreError {
    var userFacingMessage: String {
        switch self {
        case .unsupportedSchemaVersion:
            return String(localized: "The virtual display config file format is not supported by this build. Reset the config file to continue.")
        case .decodingFailed:
            return String(localized: "The virtual display config file is corrupted or invalid. Reset the config file to continue.")
        case .ioFailed:
            return String(localized: "The virtual display config file could not be accessed. Check the file path/permissions, or reset the config file.")
        }
    }
}

/// Persists virtual display configurations to disk.
struct VirtualDisplayStore {
    struct FileFormat: Codable {
        static let currentSchemaVersion = 3

        var schemaVersion: Int
        var configs: [VirtualDisplayConfig]

        init(schemaVersion: Int = FileFormat.currentSchemaVersion, configs: [VirtualDisplayConfig]) {
            self.schemaVersion = schemaVersion
            self.configs = configs
        }
    }

    private let defaultPhysicalWidth = 310
    private let defaultPhysicalHeight = 174
    private let defaultMode = VirtualDisplayConfig.ModeConfig(
        width: 1920,
        height: 1080,
        refreshRate: 60,
        enableHiDPI: true
    )
    private let fileManager: FileManager
    private let storeURL: URL
    private let mode: PersistenceMode
    private let writeGuardContext: PersistenceContext

    init(
        fileManager: FileManager = .default,
        storeURL: URL,
        mode: PersistenceMode
    ) {
        self.fileManager = fileManager
        self.storeURL = storeURL
        self.mode = mode
        self.writeGuardContext = PersistenceContext.resolve(
            environment: ProcessInfo.processInfo.environment,
            fileManager: fileManager
        )
    }

    func load() throws -> [VirtualDisplayConfig] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "load", underlying: error)
        }
        return try decodeConfigs(from: data)
    }

    func save(_ configs: [VirtualDisplayConfig]) throws {
        try ensureWriteAllowed(operation: "save")
        do {
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "create directory", underlying: error)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(configs: sanitize(configs)))
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "save", underlying: error)
        }
    }

    func reset() throws {
        try ensureWriteAllowed(operation: "reset")
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            try fileManager.removeItem(at: storeURL)
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "reset", underlying: error)
        }
    }

    func diagnostics() throws -> VirtualDisplayStoreDiagnostics {
        return VirtualDisplayStoreDiagnostics(
            primaryStoreURL: storeURL,
            isTestIsolatedPath: mode == .testIsolatedWritable
        )
    }

    func decodeConfigs(from data: Data) throws -> [VirtualDisplayConfig] {
        let decoder = JSONDecoder()
        let wrapped: FileFormat
        do {
            wrapped = try decoder.decode(FileFormat.self, from: data)
        } catch let error as DecodingError {
            throw VirtualDisplayConfigStoreError.decodingFailed(underlying: error)
        } catch {
            throw VirtualDisplayConfigStoreError.decodingFailed(underlying: error)
        }
        guard wrapped.schemaVersion == FileFormat.currentSchemaVersion else {
            throw VirtualDisplayConfigStoreError.unsupportedSchemaVersion(
                expected: FileFormat.currentSchemaVersion,
                actual: wrapped.schemaVersion
            )
        }
        return sanitize(wrapped.configs)
    }

    private func ensureWriteAllowed(operation: String) throws {
        guard writeGuardContext.guardWriteAllowed(
            targetURL: storeURL,
            mode: mode,
            operation: operation
        ) else {
            throw PersistenceWriteViolation.blockedProductionWrite(
                path: storeURL.path,
                operation: operation
            )
        }
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
            let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Virtual Display \(serial)"
                : config.displayName
            let physicalWidth = config.physicalWidth > 0 ? config.physicalWidth : defaultPhysicalWidth
            let physicalHeight = config.physicalHeight > 0 ? config.physicalHeight : defaultPhysicalHeight

            result.append(
                VirtualDisplayConfig(
                    id: id,
                    displayName: displayName,
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
