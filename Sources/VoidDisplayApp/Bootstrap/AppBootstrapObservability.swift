import VoidDisplayFoundation
import VoidDisplayObservability

extension AppBootstrap {
    static func installObservabilityFailureBridge(observability: ObservabilityCenter) {
        AppErrorMapper.installFailureBridge { [observability] error, subsystem, operation, context in
            Task { [weak observability] in
                guard let observability else { return }
                await observability.record(
                    error: error,
                    subsystem: subsystem,
                    operation: operation,
                    context: context
                )
            }
        }
    }
}
