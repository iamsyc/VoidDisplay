import Foundation
import SwiftUI

struct DiagnosticsFeedbackSections: View {
    let controller: AppSettingsFeedbackController
    let validationFocusRequest: Int
    let onExport: () -> Void
    let onCopySummary: () -> Void
    let onRevealLatestBundle: () -> Void
    let onStartNewFeedback: () -> Void
    let onCopyHistorySummary: (UUID) -> Void
    let onRevealHistoryBundle: (UUID) -> Void

    var body: some View {
        if let alert = controller.alert {
            DiagnosticsErrorBanner(alert: alert)
        }

        SupportBundleDraftSectionView(
            controller: controller,
            validationFocusRequest: validationFocusRequest,
            onExport: onExport
        )

        if let completionRecord = controller.completionRecord {
            SupportExportCompletionSectionView(
                record: completionRecord,
                onCopySummary: onCopySummary,
                onRevealBundle: onRevealLatestBundle,
                onStartNewFeedback: onStartNewFeedback
            )
        }

        let historicalRecords = Array(controller.exportHistory.dropFirst())
        if historicalRecords.isEmpty == false {
            SupportHistorySectionView(
                records: historicalRecords,
                onCopySummary: onCopyHistorySummary,
                onRevealBundle: onRevealHistoryBundle
            )
        }
    }
}
