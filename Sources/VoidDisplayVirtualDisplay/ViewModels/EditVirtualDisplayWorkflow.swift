import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package enum EditVirtualDisplayActionLayout: Equatable {
    case stopped
    case running
}
package enum EditVirtualDisplayLoadState: Equatable {
    case loaded(VirtualDisplayConfig)
    case missingConfig(UserFacingAlertState)
}

@MainActor
package enum EditVirtualDisplayWorkflow {
    package static func load(
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

    package static func actionLayout(isRunning: Bool) -> EditVirtualDisplayActionLayout {
        isRunning ? .running : .stopped
    }
}
