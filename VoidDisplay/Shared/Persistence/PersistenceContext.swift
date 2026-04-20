import Foundation
import OSLog

enum PersistenceMode: Equatable {
    case production
    case testIsolatedWritable
}

enum PersistenceWriteViolation: Error, Equatable {
    case blockedProductionWrite(path: String, operation: String)
}

struct PersistenceContext {
    static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"
    static let uiTestModeEnvironmentKey = "VOIDDISPLAY_UI_TEST_MODE"
    static let testIsolationIDEnvironmentKey = "VOIDDISPLAY_TEST_ISOLATION_ID"
    static let persistenceModeEnvironmentKey = "VOIDDISPLAY_PERSISTENCE_MODE"
    static let testIsolatedModeValue = "test_isolated"
    static let defaultBundleIdentifier = "com.developerchen.voiddisplay"

    let mode: PersistenceMode
    let bundleIdentifier: String
    let appSupportRootURL: URL
    let displayShareIDMappingsURL: URL
    let virtualDisplayConfigsURL: URL
    let userDefaults: UserDefaults

    private let productionAppSupportRootURL: URL

    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> PersistenceContext {
        let mode = resolveMode(environment: environment)
        let isolationID = resolveIsolationID(environment: environment, mode: mode)

        let runtimeBundleIdentifier = Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
        let productionBundleIdentifier = removeTestsSuffixOrIsolation(from: runtimeBundleIdentifier)
        let resolvedBundleIdentifier: String
        switch mode {
        case .production:
            resolvedBundleIdentifier = productionBundleIdentifier
        case .testIsolatedWritable:
            let testBundleIdentifier = ensureTestsSuffix(for: productionBundleIdentifier)
            if let isolationID {
                resolvedBundleIdentifier = "\(testBundleIdentifier).\(isolationID)"
            } else {
                resolvedBundleIdentifier = testBundleIdentifier
            }
        }

        let appSupportDirectory = resolveApplicationSupportDirectory(fileManager: fileManager)
        let appSupportRootURL = appSupportDirectory
            .appendingPathComponent(resolvedBundleIdentifier, isDirectory: true)
        let productionAppSupportRootURL = appSupportDirectory
            .appendingPathComponent(productionBundleIdentifier, isDirectory: true)

        return PersistenceContext(
            mode: mode,
            bundleIdentifier: resolvedBundleIdentifier,
            appSupportRootURL: appSupportRootURL,
            displayShareIDMappingsURL: appSupportRootURL
                .appendingPathComponent("display-share-id-mappings.json", isDirectory: false),
            virtualDisplayConfigsURL: appSupportRootURL
                .appendingPathComponent("virtual-displays.json", isDirectory: false),
            userDefaults: resolveUserDefaults(
                mode: mode,
                bundleIdentifier: resolvedBundleIdentifier
            ),
            productionAppSupportRootURL: productionAppSupportRootURL
        )
    }

    static func resolveMode(environment: [String: String]) -> PersistenceMode {
        if environment[persistenceModeEnvironmentKey] == testIsolatedModeValue {
            return .testIsolatedWritable
        }
        if environment[xCTestConfigurationEnvironmentKey] != nil {
            return .testIsolatedWritable
        }
        if normalizedIsolationID(from: environment[testIsolationIDEnvironmentKey]) != nil {
            return .testIsolatedWritable
        }
        if environment[uiTestModeEnvironmentKey] == "1" {
            return .testIsolatedWritable
        }
        return .production
    }

    private static func resolveIsolationID(
        environment: [String: String],
        mode: PersistenceMode
    ) -> String? {
        guard mode == .testIsolatedWritable else { return nil }

        if let explicit = normalizedIsolationID(from: environment[testIsolationIDEnvironmentKey]) {
            return explicit
        }

        if let xctestConfig = environment[xCTestConfigurationEnvironmentKey],
           !xctestConfig.isEmpty {
            let digest = fnv1a64Hex(xctestConfig)
            return "run-\(digest)"
        }

        if environment[uiTestModeEnvironmentKey] == "1" {
            return "ui-\(ProcessInfo.processInfo.processIdentifier)"
        }

        return nil
    }

    func guardWriteAllowed(
        targetURL: URL,
        mode: PersistenceMode? = nil,
        operation: String
    ) -> Bool {
        let resolvedMode = mode ?? self.mode
        guard resolvedMode == .testIsolatedWritable else { return true }

        let target = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let productionRoot = productionAppSupportRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let isProductionTarget = target == productionRoot || target.hasPrefix(productionRoot + "/")
        guard isProductionTarget else { return true }

        AppLog.persistence.error(
            "Blocked persistence write to production path during test isolation (operation: \(operation, privacy: .public), path: \(target, privacy: .public))."
        )
        return false
    }

    var diagnosticsDirectoryURL: URL {
        appSupportRootURL.appendingPathComponent("diagnostics", isDirectory: true)
    }

    var observabilityDirectoryURL: URL {
        diagnosticsDirectoryURL.appendingPathComponent("observability", isDirectory: true)
    }

    var observabilityEventsDirectoryURL: URL {
        observabilityDirectoryURL.appendingPathComponent("events", isDirectory: true)
    }

    var observabilityIssuesURL: URL {
        observabilityDirectoryURL.appendingPathComponent("recent-issues.json", isDirectory: false)
    }

    var observabilityCurrentStateURL: URL {
        observabilityDirectoryURL
            .appendingPathComponent("current-state.json", isDirectory: false)
    }

    var observabilityHealthSummaryURL: URL {
        observabilityDirectoryURL
            .appendingPathComponent("health-summary.json", isDirectory: false)
    }

    var observabilityRecentEventsURL: URL {
        observabilityDirectoryURL
            .appendingPathComponent("recent-events.ndjson", isDirectory: false)
    }

    var observabilityExportsDirectoryURL: URL {
        observabilityDirectoryURL.appendingPathComponent("exports", isDirectory: true)
    }

    private static func resolveApplicationSupportDirectory(fileManager: FileManager) -> URL {
        do {
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            preconditionFailure("Failed to resolve application support directory: \(error)")
        }
    }

    private static func resolveUserDefaults(
        mode: PersistenceMode,
        bundleIdentifier: String
    ) -> UserDefaults {
        switch mode {
        case .production:
            return .standard
        case .testIsolatedWritable:
            guard let isolated = UserDefaults(suiteName: bundleIdentifier) else {
                preconditionFailure("Failed to create isolated UserDefaults suite: \(bundleIdentifier)")
            }
            return isolated
        }
    }

    private static func removeTestsSuffixOrIsolation(from bundleIdentifier: String) -> String {
        guard let testsRange = bundleIdentifier.range(of: ".tests") else {
            return bundleIdentifier
        }
        return String(bundleIdentifier[..<testsRange.lowerBound])
    }

    private static func ensureTestsSuffix(for bundleIdentifier: String) -> String {
        guard !bundleIdentifier.hasSuffix(".tests") else { return bundleIdentifier }
        return "\(bundleIdentifier).tests"
    }

    private static func normalizedIsolationID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let normalizedScalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(normalizedScalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(48))
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16, uppercase: false)
    }
}
