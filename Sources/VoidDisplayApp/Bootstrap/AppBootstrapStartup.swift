import VoidDisplayObservability
import VoidDisplayRuntime

extension AppBootstrap {
    static func makeStartupTask(
        configuration: AppBootstrapConfiguration,
        persistence: AppBootstrapPersistenceBundle,
        controllers: AppBootstrapControllerBundle,
        runtime: AppBootstrapRuntimeBundle
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await persistence.observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(
                    DisplayRuntimeSnapshotProvider(runtime: runtime.displayRuntime)
                )
            )
            await persistence.observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(
                    SystemSnapshotProvider(environment: persistence.environment)
                )
            )
            await persistence.observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(
                    PersistenceSnapshotProvider(context: persistence.context)
                )
            )
            if configuration.preview == false,
               configuration.startupPlan.shouldRestoreVirtualDisplays {
                _ = await runtime.displayRuntime.restoreStartupVirtualDisplays(source: .startup)
                controllers.virtualDisplay.refreshVirtualDisplayState()
            }
            await persistence.observability.refreshSnapshot(reason: .startup)
        }
    }
}
