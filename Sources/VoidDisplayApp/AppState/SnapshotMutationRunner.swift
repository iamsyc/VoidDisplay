@MainActor
package final class SnapshotMutationRunner {
    private let sync: @MainActor () -> Void

    package init(sync: @escaping @MainActor () -> Void) {
        self.sync = sync
    }

    package func run(_ mutation: () -> Void) {
        mutation()
        sync()
    }

    package func run<T>(_ mutation: () async -> T) async -> T {
        defer { sync() }
        return await mutation()
    }

    package func run<T>(_ mutation: () async throws -> T) async rethrows -> T {
        defer { sync() }
        return try await mutation()
    }
}
