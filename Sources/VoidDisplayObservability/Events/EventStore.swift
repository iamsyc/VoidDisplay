import VoidDisplayFoundation
import Foundation
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

        let lineData = try ObservabilityCodec.encode(event) + Data([0x0A])
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

    package func recentEvents(limit: Int = 2_000) async throws -> [ObservabilityEvent] {
        let persisted = try loadPersistedEventsLocked()
        guard !persisted.isEmpty else {
            return Array(inMemoryEvents.suffix(limit))
        }
        return Array(persisted.suffix(limit))
    }

    package func recentInMemoryEvents(limit: Int = 2_000) async -> [ObservabilityEvent] {
        Array(inMemoryEvents.suffix(limit))
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
            for line in content.split(whereSeparator: \.isNewline) {
                guard let eventData = line.data(using: .utf8) else { continue }
                if let event = try? ObservabilityCodec.decode(ObservabilityEvent.self, from: eventData) {
                    events.append(event)
                }
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
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
}
