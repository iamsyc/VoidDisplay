import Foundation

@MainActor
final class SnapshotMutationRunner {
    private let sync: @MainActor () -> Void

    init(sync: @escaping @MainActor () -> Void) {
        self.sync = sync
    }

    func run(_ mutation: () -> Void) {
        mutation()
        sync()
    }

    func run<T>(_ mutation: () async -> T) async -> T {
        defer { sync() }
        return await mutation()
    }

    func run<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { sync() }
        return try await mutation()
    }
}
