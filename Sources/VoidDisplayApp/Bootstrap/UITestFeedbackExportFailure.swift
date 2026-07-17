import Foundation

struct UITestFeedbackExportFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
