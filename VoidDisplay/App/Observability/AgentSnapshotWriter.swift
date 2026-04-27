import Foundation

actor AgentSnapshotWriter {
    private let currentStateURL: URL
    private let healthSummaryURL: URL
    private let recentEventsURL: URL?
    private let debounceDuration: Duration

    private var scheduledWriteTask: Task<Void, Never>?

    init(
        currentStateURL: URL,
        healthSummaryURL: URL,
        recentEventsURL: URL? = nil,
        debounceDuration: Duration = .milliseconds(300)
    ) {
        self.currentStateURL = currentStateURL
        self.healthSummaryURL = healthSummaryURL
        self.recentEventsURL = recentEventsURL
        self.debounceDuration = debounceDuration
    }

    func scheduleWrite(
        state: ObservabilityStateSnapshot,
        health: ObservabilityHealthSummary,
        events: [ObservabilityEvent]
    ) async {
        scheduledWriteTask?.cancel()
        let currentStateURL = self.currentStateURL
        let healthSummaryURL = self.healthSummaryURL
        let recentEventsURL = self.recentEventsURL
        let debounceDuration = self.debounceDuration
        scheduledWriteTask = Task.detached {
            do {
                try await Task.sleep(for: debounceDuration)
                try Self.write(state, to: currentStateURL)
                try Self.write(health, to: healthSummaryURL)
                if let recentEventsURL {
                    try Self.writeRecentEvents(events, to: recentEventsURL)
                }
            } catch {
                return
            }
        }
    }

    func flush(
        state: ObservabilityStateSnapshot,
        health: ObservabilityHealthSummary,
        events: [ObservabilityEvent]
    ) async throws {
        scheduledWriteTask?.cancel()
        scheduledWriteTask = nil
        try Self.write(state, to: currentStateURL)
        try Self.write(health, to: healthSummaryURL)
        if let recentEventsURL {
            try Self.writeRecentEvents(events, to: recentEventsURL)
        }
    }

    private static func write<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ObservabilityCodec.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func writeRecentEvents(
        _ events: [ObservabilityEvent],
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try events.map {
            String(decoding: try ObservabilityCodec.encode($0), as: UTF8.self)
        }.joined(separator: "\n")
        let content = lines.isEmpty ? "" : lines + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
