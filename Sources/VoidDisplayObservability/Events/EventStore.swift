import VoidDisplayFoundation
import Foundation

package struct ObservabilityEventWindowSummary: Equatable, Sendable {
    package let eventCount: Int
    package let highestSeverity: ObservabilitySeverity?
}

package struct ObservabilityEventSnapshot: Equatable, Sendable {
    package let recentEvents: [ObservabilityEvent]
    package let windowSummary: ObservabilityEventWindowSummary
}

package actor EventStore {
    private let directoryURL: URL
    private let retentionDays: Int
    private let inMemoryLimit: Int
    private let deduplicationWindow: TimeInterval
    private let fileManager: FileManager
    private let dateProvider: () -> Date

    private var inMemoryEvents: [ObservabilityEvent] = []
    private var lastEventByDeduplicationKey: [String: ObservabilityEvent] = [:]

    package init(
        directoryURL: URL,
        retentionDays: Int = 7,
        inMemoryLimit: Int = 2_000,
        deduplicationWindow: TimeInterval = 5,
        fileManager: FileManager = .default,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL
        self.retentionDays = retentionDays
        self.inMemoryLimit = inMemoryLimit
        self.deduplicationWindow = deduplicationWindow
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    package func append(_ event: ObservabilityEvent) async throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try pruneExpiredFilesLocked()
        if isDuplicate(event) {
            return
        }
        inMemoryEvents.append(event)
        if inMemoryEvents.count > inMemoryLimit {
            inMemoryEvents.removeFirst(inMemoryEvents.count - inMemoryLimit)
        }
        if let deduplicationKey = event.deduplicationKey {
            lastEventByDeduplicationKey[deduplicationKey] = event
        }

        let lineData = try Self.encodeEventLine(event) + Data([0x0A])
        let fileURL = directoryURL.appendingPathComponent(Self.filename(for: event.timestamp))
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } else {
            try lineData.write(to: fileURL, options: [.atomic])
        }
    }

    package func recentEvents(
        limit: Int = 2_000,
        since earliestDate: Date? = nil,
        excludingSubsystems: Set<ObservabilityDomain> = []
    ) async throws -> [ObservabilityEvent] {
        let persisted = try loadPersistedEventsLocked()
        let source = persisted.isEmpty ? inMemoryEvents : persisted
        return filteredRecentEvents(
            source,
            limit: limit,
            since: earliestDate,
            excludingSubsystems: excludingSubsystems
        )
    }

    package func recentInMemoryEvents(
        limit: Int = 2_000,
        since earliestDate: Date? = nil,
        excludingSubsystems: Set<ObservabilityDomain> = []
    ) async -> [ObservabilityEvent] {
        filteredRecentEvents(
            inMemoryEvents,
            limit: limit,
            since: earliestDate,
            excludingSubsystems: excludingSubsystems
        )
    }

    package func snapshot(
        recentLimit: Int,
        summarySince earliestDate: Date,
        summaryExcludingSubsystems: Set<ObservabilityDomain> = []
    ) async throws -> ObservabilityEventSnapshot {
        let persisted = try loadPersistedEventsLocked()
        let source = persisted.isEmpty ? inMemoryEvents : persisted
        return makeSnapshot(
            source,
            recentLimit: recentLimit,
            summarySince: earliestDate,
            summaryExcludingSubsystems: summaryExcludingSubsystems
        )
    }

    package func inMemorySnapshot(
        recentLimit: Int,
        summarySince earliestDate: Date,
        summaryExcludingSubsystems: Set<ObservabilityDomain> = []
    ) async -> ObservabilityEventSnapshot {
        makeSnapshot(
            inMemoryEvents,
            recentLimit: recentLimit,
            summarySince: earliestDate,
            summaryExcludingSubsystems: summaryExcludingSubsystems
        )
    }

    package func pruneExpiredFiles() async throws {
        try pruneExpiredFilesLocked()
    }

    private func loadPersistedEventsLocked() throws -> [ObservabilityEvent] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension == "ndjson" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var events: [ObservabilityEvent] = []
        for fileURL in files {
            let data = try Data(contentsOf: fileURL)
            guard let content = String(data: data, encoding: .utf8) else { continue }
            events.append(contentsOf: Self.decodeEvents(from: content))
        }
        return events.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp != rhs.element.timestamp {
                    return lhs.element.timestamp < rhs.element.timestamp
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func decodeEvents(from content: String) -> [ObservabilityEvent] {
        var events: [ObservabilityEvent] = []
        var legacyDocument = ""

        for rawLine in content.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.isEmpty == false else { continue }

            if let event = decodeEvent(from: trimmedLine) {
                events.append(event)
                legacyDocument.removeAll(keepingCapacity: true)
                continue
            }

            if trimmedLine.hasPrefix("{") {
                legacyDocument = line + "\n"
            } else if legacyDocument.isEmpty == false {
                legacyDocument.append(line)
                legacyDocument.append("\n")
            }

            if let event = decodeEvent(from: legacyDocument) {
                events.append(event)
                legacyDocument.removeAll(keepingCapacity: true)
            }
        }

        return events
    }

    private static func decodeEvent(from document: String) -> ObservabilityEvent? {
        guard document.isEmpty == false else { return nil }
        return try? makeEventDecoder().decode(
            ObservabilityEvent.self,
            from: Data(document.utf8)
        )
    }

    private static func encodeEventLine(_ event: ObservabilityEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(preciseTimestampStyle))
        }
        return try encoder.encode(event)
    }

    private static func makeEventDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let timestamp = try container.decode(String.self)
            if let preciseDate = try? Date(timestamp, strategy: preciseTimestampStyle) {
                return preciseDate
            }
            if let legacyDate = try? Date(timestamp, strategy: legacyTimestampStyle) {
                return legacyDate
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 timestamp."
            )
        }
        return decoder
    }

    private func filteredRecentEvents(
        _ events: [ObservabilityEvent],
        limit: Int,
        since earliestDate: Date?,
        excludingSubsystems: Set<ObservabilityDomain>
    ) -> [ObservabilityEvent] {
        let filtered = events.filter { event in
            if let earliestDate, event.timestamp < earliestDate {
                return false
            }
            return excludingSubsystems.contains(event.subsystem) == false
        }
        return Array(filtered.suffix(limit))
    }

    private func summarize(
        _ events: [ObservabilityEvent],
        since earliestDate: Date,
        excludingSubsystems: Set<ObservabilityDomain>
    ) -> ObservabilityEventWindowSummary {
        var eventCount = 0
        var highestSeverity: ObservabilitySeverity?
        for event in events where
            event.timestamp >= earliestDate &&
            excludingSubsystems.contains(event.subsystem) == false
        {
            eventCount += 1
            highestSeverity = max(highestSeverity ?? event.severity, event.severity)
        }
        return ObservabilityEventWindowSummary(
            eventCount: eventCount,
            highestSeverity: highestSeverity
        )
    }

    private func makeSnapshot(
        _ events: [ObservabilityEvent],
        recentLimit: Int,
        summarySince earliestDate: Date,
        summaryExcludingSubsystems: Set<ObservabilityDomain>
    ) -> ObservabilityEventSnapshot {
        ObservabilityEventSnapshot(
            recentEvents: Array(events.suffix(recentLimit)),
            windowSummary: summarize(
                events,
                since: earliestDate,
                excludingSubsystems: summaryExcludingSubsystems
            )
        )
    }

    private func pruneExpiredFilesLocked() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let expirationDate = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: dateProvider()
        ) ?? .distantPast
        let files = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in files where fileURL.pathExtension == "ndjson" {
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if modifiedAt < expirationDate {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func isDuplicate(_ event: ObservabilityEvent) -> Bool {
        guard let deduplicationKey = event.deduplicationKey,
              let previous = lastEventByDeduplicationKey[deduplicationKey] else {
            return false
        }
        let interval = event.timestamp.timeIntervalSince(previous.timestamp)
        guard interval >= 0, interval <= deduplicationWindow else { return false }
        return previous.operation == event.operation &&
            previous.message == event.message &&
            previous.subsystem == event.subsystem &&
            previous.severity == event.severity
    }

    private static func filename(for date: Date) -> String {
        "events-\(fileFormatter.string(from: date)).ndjson"
    }

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let preciseTimestampStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let legacyTimestampStyle = Date.ISO8601FormatStyle()
}
