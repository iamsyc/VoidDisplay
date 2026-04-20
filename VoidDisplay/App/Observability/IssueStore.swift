import Foundation

actor IssueStore {
    private let fileURL: URL
    private let limit: Int
    private let fileManager: FileManager

    private var issuesByKey: [String: IssueRecord] = [:]
    private var hasLoaded = false

    init(
        fileURL: URL,
        limit: Int = 100,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.limit = limit
        self.fileManager = fileManager
    }

    func record(event: ObservabilityEvent) async {
        guard event.severity >= .error else { return }
        loadIfNeeded()

        let key = event.deduplicationKey ?? [
            event.subsystem.rawValue,
            event.operation,
            event.message
        ].joined(separator: "|")

        if let existing = issuesByKey[key] {
            issuesByKey[key] = IssueRecord(
                id: existing.id,
                deduplicationKey: key,
                subsystem: event.subsystem,
                operation: event.operation,
                message: event.message,
                firstSeenAt: existing.firstSeenAt,
                lastSeenAt: event.timestamp,
                occurrenceCount: existing.occurrenceCount + 1,
                latestMetadata: event.metadata
            )
        } else {
            issuesByKey[key] = IssueRecord(
                id: UUID(),
                deduplicationKey: key,
                subsystem: event.subsystem,
                operation: event.operation,
                message: event.message,
                firstSeenAt: event.timestamp,
                lastSeenAt: event.timestamp,
                occurrenceCount: 1,
                latestMetadata: event.metadata
            )
        }

        trimIfNeeded()
        try? persist()
    }

    func recentIssues(limit requestedLimit: Int = 50) async -> [IssueRecord] {
        loadIfNeeded()
        return issuesByKey.values
            .sorted { lhs, rhs in
                if lhs.lastSeenAt == rhs.lastSeenAt {
                    return lhs.occurrenceCount > rhs.occurrenceCount
                }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
            .prefix(requestedLimit)
            .map { $0 }
    }

    private func trimIfNeeded() {
        guard issuesByKey.count > limit else { return }
        let retainedKeys = Set(
            issuesByKey.values
                .sorted { lhs, rhs in lhs.lastSeenAt > rhs.lastSeenAt }
                .prefix(limit)
                .map(\.deduplicationKey)
        )
        issuesByKey = issuesByKey.filter { retainedKeys.contains($0.key) }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        defer { hasLoaded = true }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? ObservabilityCodec.decode([IssueRecord].self, from: data) else { return }
        issuesByKey = Dictionary(uniqueKeysWithValues: decoded.map { ($0.deduplicationKey, $0) })
    }

    private func persist() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try ObservabilityCodec.encode(recentIssuesSync())
        try data.write(to: fileURL, options: [.atomic])
    }

    private func recentIssuesSync() -> [IssueRecord] {
        issuesByKey.values.sorted { lhs, rhs in lhs.lastSeenAt > rhs.lastSeenAt }
    }
}
