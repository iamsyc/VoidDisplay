import VoidDisplayObservability
import VoidDisplayRuntime

package struct DisplayRuntimeSnapshotProvider: ObservabilitySnapshotProvider, @unchecked Sendable {
    package let key = "runtime"
    private let runtime: DisplayRuntime

    package init(runtime: DisplayRuntime) {
        self.runtime = runtime
    }

    @MainActor
    package func makeSnapshot() -> DisplayRuntimeSnapshot {
        runtime.makeSnapshot()
    }
}
