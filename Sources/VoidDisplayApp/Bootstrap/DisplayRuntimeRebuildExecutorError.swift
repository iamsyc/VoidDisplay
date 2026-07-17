import Foundation

struct DisplayRuntimeRebuildExecutorError: LocalizedError {
    let reason: String

    init(transactionStatus: String) {
        reason = "display_runtime_transaction_\(transactionStatus)"
    }

    var errorDescription: String? {
        String(localized: "Failed to rebuild virtual display.")
    }
}
