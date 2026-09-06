import VoidDisplayVirtualDisplay

package final class TestVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    package nonisolated init() {}

    package func createRuntimeDisplay(
        descriptor: VirtualDisplayRuntimeDescriptor,
        onTermination: @escaping @MainActor () -> Void
    ) async throws -> any VirtualDisplayRuntimeHandling {
        throw VirtualDisplayOperationError.creationFailed
    }
}
