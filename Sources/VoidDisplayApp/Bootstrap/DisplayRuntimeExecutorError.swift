import Foundation

struct DisplayRuntimeExecutorError: LocalizedError {
    enum Operation: Equatable {
        case rebuild
        case setDesiredEnabled(Bool)
        case editAndRebuild
        case create
        case delete
    }

    let operation: Operation
    let reason: String

    var errorDescription: String? {
        switch operation {
        case .create:
            String(localized: "Create failed.")
        case .delete:
            String(localized: "Delete failed.")
        case .setDesiredEnabled(let enabled):
            enabled ? String(localized: "Enable failed.") : String(localized: "Disable failed.")
        case .rebuild, .editAndRebuild:
            String(localized: "Failed to rebuild virtual display.")
        }
    }
}
