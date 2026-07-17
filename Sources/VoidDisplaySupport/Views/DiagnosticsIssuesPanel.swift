import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsIssuesPanel: View {
    let issues: [IssueRecord]?

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label(String(localized: "Recent Issues"), systemImage: "exclamationmark.triangle")
                .font(.headline)

            if let issues, issues.isEmpty == false {
                let visibleIssues = Array(issues.prefix(8))
                ForEach(Array(visibleIssues.enumerated()), id: \.element.id) { index, issue in
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        Text(issue.message)
                            .font(.footnote)
                            .textSelection(.enabled)
                        HStack(spacing: AppUI.Spacing.small) {
                            DiagnosticsTag(title: issue.subsystem.rawValue)
                            Text(issue.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            if issue.occurrenceCount > 1 {
                                Text(verbatim: "x\(issue.occurrenceCount)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if index < visibleIssues.count - 1 {
                        Divider()
                    }
                }
            } else {
                Label(String(localized: "No recent issues."), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityIdentifier("diagnostics_recent_issues")
    }
}
