import VoidDisplayVirtualDisplay

package final class TestVirtualDisplayRuntimeDriver: VirtualDisplayRuntimeDriving {
    package nonisolated init() {}

    package func createRuntimeDisplay(
        from config: VirtualDisplayConfig,
        maxPixels: (width: UInt32, height: UInt32)?,
        onTermination: @escaping @MainActor () -> Void
    ) throws -> any VirtualDisplayRuntimeHandling {
        throw VirtualDisplayOperationError.creationFailed
    }
}
