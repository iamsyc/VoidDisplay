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
                    let presentation = DiagnosticsEvidencePresentation.issue(issue)
                    VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                        Text(presentation.title)
                            .font(.footnote.weight(.medium))
                        HStack(spacing: AppUI.Spacing.small) {
                            DiagnosticsTag(title: presentation.domainTitle)
                            Text(presentation.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            if presentation.occurrenceCount > 1 {
                                Text(verbatim: "x\(presentation.occurrenceCount)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        DisclosureGroup(String(localized: "Details")) {
                            DiagnosticsRawEvidenceDetails(evidence: [presentation.evidence])
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
