import VoidDisplayFoundation
import Dispatch
import Foundation
package nonisolated struct FeedbackBundleExporter {
    package typealias CommandRunner = (_ launchPath: String, _ arguments: [String], _ timeout: TimeInterval) -> String?
    package typealias ArchiveWriter = (_ sourceURL: URL, _ destinationURL: URL) throws -> Void

    private let exportsDirectoryURL: URL
    private let virtualDisplayConfigsURL: URL
    private let displayShareMappingsURL: URL
    private let sanitizer: ObservabilitySanitizer
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let reportIDProvider: () -> UUID
    private let commandRunner: CommandRunner
    private let archiveWriter: ArchiveWriter

    package init(
        exportsDirectoryURL: URL,
        virtualDisplayConfigsURL: URL,
        displayShareMappingsURL: URL,
        sanitizer: ObservabilitySanitizer,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init,
        reportIDProvider: @escaping () -> UUID = UUID.init,
        commandRunner: CommandRunner? = nil,
        archiveWriter: ArchiveWriter? = nil
    ) {
        self.exportsDirectoryURL = exportsDirectoryURL
        self.virtualDisplayConfigsURL = virtualDisplayConfigsURL
        self.displayShareMappingsURL = displayShareMappingsURL
        self.sanitizer = sanitizer
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.reportIDProvider = reportIDProvider
        self.commandRunner = commandRunner ?? Self.runCommand
        self.archiveWriter = archiveWriter ?? Self.zipDirectory
    }

    package func exportBundle(
        draft: FeedbackDraft,
        consent: FeedbackConsent,
        state: ObservabilityStateSnapshot,
        health: ObservabilityHealthSummary,
        events: [ObservabilityEvent],
        issues: [IssueRecord]
    ) throws -> URL {
        try createPrivateDirectory(at: exportsDirectoryURL)

        let generatedAt = dateProvider()
        let timestamp = Self.timestampFormatter.string(from: generatedAt)
        let reportID = reportIDProvider()
        let bundleName = "support-bundle-\(timestamp)-\(reportID.uuidString.lowercased())"
        let stagingURL = exportsDirectoryURL.appendingPathComponent(bundleName, isDirectory: true)
        let bundleURL = exportsDirectoryURL.appendingPathComponent("\(bundleName).zip", isDirectory: false)

        guard fileManager.fileExists(atPath: stagingURL.path) == false,
              fileManager.fileExists(atPath: bundleURL.path) == false else {
            throw CocoaError(.fileWriteFileExists)
        }

        var completed = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            if completed == false {
                try? fileManager.removeItem(at: bundleURL)
            }
        }

        try createPrivateDirectory(at: stagingURL)

        let safeDraft = sanitizer.sanitize(draft.trimmedPayload())
        let safeState = sanitizer.sanitize(state)
        let safeHealth = sanitizer.sanitize(health)
        let safeEvents = events.map(sanitizer.sanitize)
        let safeIssues = issues.map(sanitizer.sanitize)

        try writeJSON(safeDraft, to: stagingURL.appendingPathComponent("feedback.json"))
        try writeJSON(
            safeState,
            to: stagingURL.appendingPathComponent("state", isDirectory: true).appendingPathComponent("current-state.json")
        )
        try writeJSON(
            safeHealth,
            to: stagingURL.appendingPathComponent("state", isDirectory: true).appendingPathComponent("health-summary.json")
        )
        try writeRecentEvents(
            safeEvents,
            to: stagingURL.appendingPathComponent("events", isDirectory: true).appendingPathComponent("recent-events.ndjson")
        )
        try writeJSON(
            safeIssues,
            to: stagingURL.appendingPathComponent("issues", isDirectory: true).appendingPathComponent("recent-issues.json")
        )

        let attachments = try writeAttachments(consent: consent, into: stagingURL)
        let manifest = SupportBundleManifest(
            reportID: reportID,
            generatedAt: generatedAt,
            app: .init(
                bundleIdentifier: state.app.bundleIdentifier,
                version: state.app.version,
                build: state.app.build
            ),
            eventCount: safeEvents.count,
            issueCount: safeIssues.count,
            attachments: attachments.sorted(),
            consent: consent
        )
        try writeJSON(manifest, to: stagingURL.appendingPathComponent("manifest.json"))

        try archiveWriter(stagingURL, bundleURL)
        try validateArchive(at: bundleURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
        completed = true
        return bundleURL
    }

    package func latestExportedBundleURL() -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: exportsDirectoryURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls
            .filter {
                guard $0.pathExtension == "zip",
                      $0.lastPathComponent.hasPrefix("support-bundle-"),
                      let values = try? $0.resourceValues(forKeys: [
                          .fileSizeKey,
                          .isRegularFileKey,
                          .isSymbolicLinkKey
                      ]) else {
                    return false
                }
                return values.isRegularFile == true &&
                    values.isSymbolicLink != true &&
                    (values.fileSize ?? 0) > 0
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }?
            .standardizedFileURL
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
            let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize <= Self.maximumConfigSnapshotByteCount else {
                try writeText(
                    redactedConfigPlaceholder(
                        sourceURL: sourceURL,
                        originalByteCount: fileSize,
                        reason: "size_limit_exceeded"
                    ),
                    to: destinationURL
                )
                writtenFiles.append(sanitizedName)
                continue
            }
            let data = try Data(contentsOf: sourceURL)
            try writeText(sanitizedConfigSnapshot(data, sourceURL: sourceURL), to: destinationURL)
            writtenFiles.append(sanitizedName)
        }
        return writtenFiles.isEmpty ? nil : writtenFiles
    }

    private func sanitizedConfigSnapshot(_ data: Data, sourceURL: URL) -> String {
        guard let value = try? ObservabilityCodec.decode(JSONValue.self, from: data),
              let encoded = try? ObservabilityCodec.encode(redactedConfigSnapshot(value, sourceURL: sourceURL)) else {
            return redactedConfigPlaceholder(
                sourceURL: sourceURL,
                originalByteCount: data.count,
                reason: "invalid_json"
            )
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func redactedConfigPlaceholder(
        sourceURL: URL,
        originalByteCount: Int,
        reason: String
    ) -> String {
        let placeholder: JSONValue = .object([
            "originalByteCount": .number(Double(originalByteCount)),
            "reason": .string(reason),
            "redacted": .bool(true),
            "sourceKind": .string(configSnapshotSourceKind(sourceURL))
        ])
        let encoded = try? ObservabilityCodec.encode(placeholder)
        return encoded.map { String(decoding: $0, as: UTF8.self) } ??
            "{\"originalByteCount\":\(originalByteCount),\"reason\":\"\(reason)\",\"redacted\":true,\"sourceKind\":\"\(configSnapshotSourceKind(sourceURL))\"}"
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
                let key = sanitizer.sanitize(text: entry.key) ?? entry.key
                if sanitizer.shouldRedactValue(forKey: entry.key) {
                    result[key] = .string("<redacted>")
                } else {
                    result[key] = recursivelySanitizeConfigSnapshot(entry.value)
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
              let data = try? readPrefix(
                  from: candidate,
                  maximumByteCount: Self.maximumCrashReportExcerptByteCount
              ) else {
            return nil
        }
        let content = String(decoding: data, as: UTF8.self)
        let excerpt = content.split(whereSeparator: \.isNewline).prefix(220).joined(separator: "\n")
        return sanitizer.sanitize(text: excerpt)
    }

    private func readPrefix(from url: URL, maximumByteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumByteCount) ?? Data()
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

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validateArchive(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func zipDirectory(_ sourceURL: URL, _ destinationURL: URL) throws {
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

    private static let maximumConfigSnapshotByteCount = 2 * 1_024 * 1_024
    private static let maximumCrashReportExcerptByteCount = 512 * 1_024
}
