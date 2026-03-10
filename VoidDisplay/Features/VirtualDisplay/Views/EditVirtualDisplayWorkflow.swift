import Foundation

enum EditVirtualDisplayActionLayout: Equatable {
    case stopped
    case running
}

enum EditVirtualDisplayLoadState: Equatable {
    case loaded(VirtualDisplayConfig)
    case missingConfig(UserFacingAlertState)
}

@MainActor
enum EditVirtualDisplayWorkflow {
    static func load(
        configId: UUID,
        virtualDisplay: VirtualDisplayController
    ) -> EditVirtualDisplayLoadState {
        guard let config = virtualDisplay.getConfig(configId) else {
            return .missingConfig(
                UserFacingAlertState(
                    title: String(localized: "Error"),
                    message: String(localized: "Display configuration not found.")
                )
            )
        }
        return .loaded(config)
    }

    static func actionLayout(isRunning: Bool) -> EditVirtualDisplayActionLayout {
        isRunning ? .running : .stopped
    }
}
