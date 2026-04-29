import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
package nonisolated enum SupportWorkflowEventAction: String, Sendable {
    case pageOpened = "page_opened"
    case issueTypeChanged = "issue_type_changed"
    case validationFailed = "validation_failed"
    case exportStarted = "export_started"
    case exportSucceeded = "export_succeeded"
    case exportFailed = "export_failed"
    case summaryCopied = "summary_copied"
    case bundleRevealed = "bundle_revealed"
    case newFeedback = "new_feedback"
    case historySummaryCopied = "history_summary_copied"
    case historyBundleRevealed = "history_bundle_revealed"

    package var operation: String {
        "Support workflow \(rawValue)"
    }

    package var message: String {
        switch self {
        case .pageOpened:
            "Opened support center."
        case .issueTypeChanged:
            "Changed support issue type."
        case .validationFailed:
            "Support export validation failed."
        case .exportStarted:
            "Started support export."
        case .exportSucceeded:
            "Exported support bundle."
        case .exportFailed:
            "Failed to export support bundle."
        case .summaryCopied:
            "Copied support summary."
        case .bundleRevealed:
            "Revealed latest support bundle."
        case .newFeedback:
            "Started a new support draft."
        case .historySummaryCopied:
            "Copied summary from support history."
        case .historyBundleRevealed:
            "Revealed support bundle from history."
        }
    }
}
