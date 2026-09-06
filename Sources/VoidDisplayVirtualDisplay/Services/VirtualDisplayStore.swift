import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package struct VirtualDisplayStoreDiagnostics {
    package let primaryStoreURL: URL
    package let isTestIsolatedPath: Bool

    package init(primaryStoreURL: URL, isTestIsolatedPath: Bool) {
        self.primaryStoreURL = primaryStoreURL
        self.isTestIsolatedPath = isTestIsolatedPath
    }

    package var summary: String {
        [
            "primary=\(primaryStoreURL.path)",
            "testIsolated=\(isTestIsolatedPath)"
        ]
        .joined(separator: " | ")
    }
}
package enum VirtualDisplayConfigStoreError: Error {
    case unsupportedSchemaVersion(expected: Int, actual: Int)
    case decodingFailed(underlying: Error)
    case invalidConfiguration(index: Int, reason: String)
    case ioFailed(operation: String, underlying: Error)
}

extension VirtualDisplayConfigStoreError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let expected, let actual):
            return "Unsupported virtual display config schema version \(actual). Expected \(expected)."
        case .decodingFailed(let underlying):
            return "Failed to decode virtual display config file: \(underlying.localizedDescription)"
        case .invalidConfiguration(let index, let reason):
            return "Invalid virtual display config at index \(index): \(reason)"
        case .ioFailed(let operation, let underlying):
            return "Virtual display config \(operation) failed: \(underlying.localizedDescription)"
        }
    }
}

package extension VirtualDisplayConfigStoreError {
    var userFacingMessage: String {
        switch self {
        case .unsupportedSchemaVersion:
            return String(localized: "The virtual display config file format is not supported by this build. Reset the config file to continue.")
        case .decodingFailed, .invalidConfiguration:
            return String(localized: "The virtual display config file is corrupted or invalid. Reset the config file to continue.")
        case .ioFailed:
            return String(localized: "The virtual display config file could not be accessed. Check the file path/permissions, or reset the config file.")
        }
    }
}

/// Persists virtual display configurations to disk.
package struct VirtualDisplayStore {
    package struct FileFormat: Codable {
        static let currentSchemaVersion = 3

        var schemaVersion: Int
        var configs: [VirtualDisplayConfig]

        init(schemaVersion: Int = FileFormat.currentSchemaVersion, configs: [VirtualDisplayConfig]) {
            self.schemaVersion = schemaVersion
            self.configs = configs
        }
    }

    private let fileManager: FileManager
    private let storeURL: URL
    private let mode: PersistenceMode
    private let writeGuardContext: PersistenceContext

    package init(
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

    package func load() throws -> [VirtualDisplayConfig] {
        guard fileManager.fileExists(atPath: storeURL.path) else { return [] }

        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "load", underlying: error)
        }
        return try decodeConfigs(from: data)
    }

    package func save(_ configs: [VirtualDisplayConfig]) throws {
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
        let validatedConfigs = try validate(configs)
        let data = try encoder.encode(FileFormat(configs: validatedConfigs))
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "save", underlying: error)
        }
    }

    package func reset() throws {
        try ensureWriteAllowed(operation: "reset")
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        do {
            try fileManager.removeItem(at: storeURL)
        } catch {
            throw VirtualDisplayConfigStoreError.ioFailed(operation: "reset", underlying: error)
        }
    }

    package func diagnostics() -> VirtualDisplayStoreDiagnostics {
        return VirtualDisplayStoreDiagnostics(
            primaryStoreURL: storeURL,
            isTestIsolatedPath: mode == .testIsolatedWritable
        )
    }

    package func decodeConfigs(from data: Data) throws -> [VirtualDisplayConfig] {
        let decoder = JSONDecoder()
        let wrapped: FileFormat
        do {
            wrapped = try decoder.decode(FileFormat.self, from: data)
        } catch {
            throw VirtualDisplayConfigStoreError.decodingFailed(underlying: error)
        }
        guard wrapped.schemaVersion == FileFormat.currentSchemaVersion else {
            throw VirtualDisplayConfigStoreError.unsupportedSchemaVersion(
                expected: FileFormat.currentSchemaVersion,
                actual: wrapped.schemaVersion
            )
        }
        return try validate(wrapped.configs)
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

    private func validate(_ configs: [VirtualDisplayConfig]) throws -> [VirtualDisplayConfig] {
        var usedSerials: Set<UInt32> = []
        var usedIDs: Set<UUID> = []

        for (index, config) in configs.enumerated() {
            guard config.serialNum > 0 else {
                throw invalidConfig(index, "serial number must be greater than 0")
            }
            guard usedSerials.insert(config.serialNum).inserted else {
                throw invalidConfig(index, "serial number must be unique")
            }
            guard usedIDs.insert(config.id).inserted else {
                throw invalidConfig(index, "id must be unique")
            }
            guard !config.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidConfig(index, "display name cannot be empty")
            }
            guard config.physicalWidth > 0, config.physicalHeight > 0 else {
                throw invalidConfig(index, "physical size must be greater than 0")
            }
            guard !config.modes.isEmpty else {
                throw invalidConfig(index, "at least one resolution mode is required")
            }

            try validateModes(config.modes, configIndex: index)
        }

        return configs
    }

    private func validateModes(_ modes: [VirtualDisplayConfig.ModeConfig], configIndex: Int) throws {
        for mode in modes {
            guard mode.width > 0, mode.height > 0 else {
                throw invalidConfig(configIndex, "resolution dimensions must be greater than 0")
            }
            guard mode.refreshRate.isFinite, mode.refreshRate > 0 else {
                throw invalidConfig(configIndex, "refresh rate must be finite and greater than 0")
            }
        }

        let maxPixels = try maxPixelDimensions(for: modes, configIndex: configIndex)

        guard maxPixels.width <= CreateVirtualDisplayInputValidator.maxPixelWidthLimit,
              maxPixels.height <= CreateVirtualDisplayInputValidator.maxPixelHeightLimit else {
            throw invalidConfig(configIndex, "maximum pixel dimensions exceed the supported limit")
        }
        let pixelCount = UInt64(maxPixels.width) * UInt64(maxPixels.height)
        guard pixelCount <= CreateVirtualDisplayInputValidator.maxPixelCountLimit else {
            throw invalidConfig(configIndex, "maximum pixel count exceeds the supported limit")
        }
    }

    private func maxPixelDimensions(
        for modes: [VirtualDisplayConfig.ModeConfig],
        configIndex: Int
    ) throws -> (width: UInt32, height: UInt32) {
        let maxMode = modes.max { lhs, rhs in
            pixelArea(of: lhs) < pixelArea(of: rhs)
        }!
        let scale: UInt64 = modes.contains { $0.enableHiDPI } ? 2 : 1
        let (scaledWidth, widthOverflow) = UInt64(maxMode.width).multipliedReportingOverflow(by: scale)
        let (scaledHeight, heightOverflow) = UInt64(maxMode.height).multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow,
              let width = UInt32(exactly: scaledWidth),
              let height = UInt32(exactly: scaledHeight) else {
            throw invalidConfig(configIndex, "maximum pixel dimensions exceed the supported limit")
        }
        return (width, height)
    }

    private func pixelArea(of mode: VirtualDisplayConfig.ModeConfig) -> UInt64 {
        let (area, overflow) = UInt64(mode.width).multipliedReportingOverflow(by: UInt64(mode.height))
        return overflow ? UInt64.max : area
    }

    private func invalidConfig(_ index: Int, _ reason: String) -> VirtualDisplayConfigStoreError {
        .invalidConfiguration(index: index, reason: reason)
    }
}
