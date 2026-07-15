import VoidDisplayFoundation
import Dispatch
import Foundation
package nonisolated struct FeedbackBundleExporter {
    package typealias CommandRunner = (_ launchPath: String, _ arguments: [String], _ timeout: TimeInterval) -> String?

    private let exportsDirectoryURL: URL
    private let virtualDisplayConfigsURL: URL
    private let displayShareMappingsURL: URL
    private let sanitizer: ObservabilitySanitizer
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let commandRunner: CommandRunner

    package init(
        exportsDirectoryURL: URL,
        virtualDisplayConfigsURL: URL,
        displayShareMappingsURL: URL,
        sanitizer: ObservabilitySanitizer,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init,
        commandRunner: CommandRunner? = nil
    ) {
        self.exportsDirectoryURL = exportsDirectoryURL
        self.virtualDisplayConfigsURL = virtualDisplayConfigsURL
        self.displayShareMappingsURL = displayShareMappingsURL
        self.sanitizer = sanitizer
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.commandRunner = commandRunner ?? Self.runCommand
    }

    package func exportBundle(
        draft: FeedbackDraft,
        consent: FeedbackConsent,
        state: ObservabilityStateSnapshot,
        health: ObservabilityHealthSummary,
        events: [ObservabilityEvent],
        issues: [IssueRecord],
        transportCapability: FeedbackTransportCapability
    ) throws -> FeedbackBundleExportResult {
        try fileManager.createDirectory(at: exportsDirectoryURL, withIntermediateDirectories: true)

        let timestamp = Self.timestampFormatter.string(from: dateProvider())
        let bundleName = "support-bundle-\(timestamp)"
        let stagingURL = exportsDirectoryURL.appendingPathComponent(bundleName, isDirectory: true)
        let bundleURL = exportsDirectoryURL.appendingPathComponent("\(bundleName).zip", isDirectory: false)

        try? fileManager.removeItem(at: stagingURL)
        try? fileManager.removeItem(at: bundleURL)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        try writeJSON(draft.trimmedPayload(), to: stagingURL.appendingPathComponent("feedback.json"))
        try writeJSON(
            state,
            to: stagingURL.appendingPathComponent("state", isDirectory: true).appendingPathComponent("current-state.json")
        )
        try writeJSON(
            health,
            to: stagingURL.appendingPathComponent("state", isDirectory: true).appendingPathComponent("health-summary.json")
        )
        try writeRecentEvents(
            events,
            to: stagingURL.appendingPathComponent("events", isDirectory: true).appendingPathComponent("recent-events.ndjson")
        )
        try writeJSON(
            issues,
            to: stagingURL.appendingPathComponent("issues", isDirectory: true).appendingPathComponent("recent-issues.json")
        )

        let attachments = try writeAttachments(consent: consent, into: stagingURL)
        let manifest = SupportBundleManifest(
            reportID: UUID(),
            generatedAt: dateProvider(),
            transportCapability: transportCapability,
            app: .init(
                bundleIdentifier: state.app.bundleIdentifier,
                version: state.app.version,
                build: state.app.build
            ),
            eventCount: events.count,
            issueCount: issues.count,
            attachments: attachments.sorted(),
            consent: consent
        )
        try writeJSON(manifest, to: stagingURL.appendingPathComponent("manifest.json"))

        try zipDirectory(stagingURL, destinationURL: bundleURL)
        try? fileManager.removeItem(at: stagingURL)
        return FeedbackBundleExportResult(bundleURL: bundleURL, manifest: manifest)
    }

    package func latestExportedBundleURL() -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: exportsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter {
                $0.pathExtension == "zip" &&
                    $0.lastPathComponent.hasPrefix("support-bundle-")
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }?
            .resolvingSymlinksInPath()
    }

    private func writeAttachments(
        consent: FeedbackConsent,
        into stagingURL: URL
    ) throws -> [String] {
        guard consent.hasEnhancedCollection else { return [] }
        let attachmentsURL = stagingURL.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)

        var paths: [String] = []

        if consent.includeUnifiedLogSummary,
           let unifiedLog = readUnifiedLogSummary(),
           !unifiedLog.isEmpty {
            let url = attachmentsURL.appendingPathComponent("unified-log.txt")
            try writeText(unifiedLog, to: url)
            paths.append("attachments/unified-log.txt")
        }

        if consent.includeCrashReportExcerpt,
           let crashExcerpt = readCrashReportExcerpt(),
           !crashExcerpt.isEmpty {
            let url = attachmentsURL.appendingPathComponent("latest-crash-report.txt")
            try writeText(crashExcerpt, to: url)
            paths.append("attachments/latest-crash-report.txt")
        }

        if consent.includeRelatedConfigSnapshots {
            let configDirectoryURL = attachmentsURL.appendingPathComponent("config", isDirectory: true)
            try fileManager.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            if let configPaths = try writeConfigSnapshots(into: configDirectoryURL) {
                paths.append(contentsOf: configPaths.map { "attachments/config/\($0)" })
            }
        }

        return paths
    }

    private func writeConfigSnapshots(into directoryURL: URL) throws -> [String]? {
        var writtenFiles: [String] = []
        for sourceURL in [virtualDisplayConfigsURL, displayShareMappingsURL] where fileManager.fileExists(atPath: sourceURL.path) {
            let sanitizedName = sourceURL.lastPathComponent
            let destinationURL = directoryURL.appendingPathComponent(sanitizedName)
            let data = try Data(contentsOf: sourceURL)
            try writeText(sanitizedConfigSnapshot(data, sourceURL: sourceURL), to: destinationURL)
            writtenFiles.append(sanitizedName)
        }
        return writtenFiles.isEmpty ? nil : writtenFiles
    }

    private func sanitizedConfigSnapshot(_ data: Data, sourceURL: URL) -> String {
        guard let value = try? ObservabilityCodec.decode(JSONValue.self, from: data),
              let encoded = try? ObservabilityCodec.encode(redactedConfigSnapshot(value, sourceURL: sourceURL)) else {
            return redactedConfigPlaceholder(sourceURL: sourceURL, originalByteCount: data.count)
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func redactedConfigPlaceholder(sourceURL: URL, originalByteCount: Int) -> String {
        let placeholder: JSONValue = .object([
            "originalByteCount": .number(Double(originalByteCount)),
            "reason": .string("invalid_json"),
            "redacted": .bool(true),
            "sourceKind": .string(configSnapshotSourceKind(sourceURL))
        ])
        let encoded = try? ObservabilityCodec.encode(placeholder)
        return encoded.map { String(decoding: $0, as: UTF8.self) } ??
            "{\"originalByteCount\":\(originalByteCount),\"reason\":\"invalid_json\",\"redacted\":true,\"sourceKind\":\"\(configSnapshotSourceKind(sourceURL))\"}"
    }

    private func configSnapshotSourceKind(_ sourceURL: URL) -> String {
        if sourceURL == virtualDisplayConfigsURL {
            return "virtual_display_configs"
        }
        if sourceURL == displayShareMappingsURL {
            return "display_share_mappings"
        }
        return "unknown_config_snapshot"
    }

    private func redactedConfigSnapshot(_ value: JSONValue, sourceURL: URL) -> JSONValue {
        let sanitized = recursivelySanitizeConfigSnapshot(value)
        guard sourceURL == displayShareMappingsURL,
              case .object(var object) = sanitized else {
            return sanitized
        }
        if let mappings = object["mappings"] {
            object["mappingCount"] = .number(Double(mappingCount(in: mappings)))
            object["mappings"] = .string("<redacted>")
        }
        return .object(object)
    }

    private func recursivelySanitizeConfigSnapshot(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.reduce(into: [String: JSONValue]()) { result, entry in
                if entry.key == "displayName" {
                    result[entry.key] = .string("<redacted>")
                } else {
                    result[entry.key] = recursivelySanitizeConfigSnapshot(entry.value)
                }
            })
        case .array(let array):
            return .array(array.map(recursivelySanitizeConfigSnapshot))
        case .string(let string):
            return .string(sanitizer.sanitize(text: string) ?? string)
        case .number, .bool, .null:
            return value
        }
    }

    private func mappingCount(in value: JSONValue) -> Int {
        switch value {
        case .object(let object):
            object.count
        case .array(let array):
            array.count
        case .string, .number, .bool, .null:
            0
        }
    }

    private func readUnifiedLogSummary() -> String? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.developerchen.voiddisplay"
        let arguments = [
            "show",
            "--style", "compact",
            "--last", "15m",
            "--predicate", "subsystem == \"\(bundleIdentifier)\""
        ]
        return commandRunner("/usr/bin/log", arguments, 8)
            .map { String($0.split(whereSeparator: \.isNewline).suffix(300).joined(separator: "\n")) }
            .flatMap(sanitizer.sanitize(text:))
    }

    private func readCrashReportExcerpt() -> String? {
        let diagnosticReportsURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: diagnosticReportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let executableName = Bundle.main.executableURL?.deletingPathExtension().lastPathComponent ?? "VoidDisplay"
        let candidate = files
            .filter {
                $0.lastPathComponent.localizedCaseInsensitiveContains(executableName) &&
                    ["crash", "ips"].contains($0.pathExtension)
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }

        guard let candidate,
              let content = try? String(contentsOf: candidate, encoding: .utf8) else {
            return nil
        }
        let excerpt = content.split(whereSeparator: \.isNewline).prefix(220).joined(separator: "\n")
        return sanitizer.sanitize(text: excerpt)
    }

    private static func runCommand(
        _ launchPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
            let result = semaphore.wait(timeout: .now() + timeout)
            guard result == .success else {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func zipDirectory(_ sourceURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            sourceURL.path,
            destinationURL.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func writeRecentEvents(_ events: [ObservabilityEvent], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try events.map {
            String(decoding: try ObservabilityCodec.encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        let content = lines.isEmpty ? "" : lines + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ObservabilityCodec.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func writeText(_ value: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
