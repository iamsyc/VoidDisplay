import Foundation

struct AnyObservabilitySnapshotProvider: Sendable {
    let key: String
    private let snapshotProducer: @Sendable () async throws -> JSONValue

    init<P: ObservabilitySnapshotProvider & Sendable>(_ provider: P) {
        self.key = provider.key
        self.snapshotProducer = {
            let snapshot = await MainActor.run {
                provider.makeSnapshot()
            }
            let data = try ObservabilityCodec.encode(snapshot)
            return try ObservabilityCodec.decode(JSONValue.self, from: data)
        }
    }

    func makeSnapshot() async throws -> JSONValue {
        try await snapshotProducer()
    }
}
