import VoidDisplayObservability
import VoidDisplayRuntime

extension AppBootstrap {
    static func makeStartupTask(
        configuration: AppBootstrapConfiguration,
        persistence: AppBootstrapPersistenceBundle,
        controllers: AppBootstrapControllerBundle,
        runtime: AppBootstrapRuntimeBundle,
        displayScenes: DisplaySceneController
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await persistence.observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(DisplaySceneSnapshotProvider(controller: displayScenes))
            )
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
            guard !Task.isCancelled else { return }
            if configuration.preview == false,
               configuration.startupPlan.shouldRestoreVirtualDisplays {
                _ = await runtime.displayRuntime.restoreStartupVirtualDisplays(source: .startup)
                guard !Task.isCancelled else { return }
                controllers.virtualDisplay.refreshVirtualDisplayState()
            }
            await persistence.observability.refreshSnapshot(reason: .startup)
        }
    }
}
