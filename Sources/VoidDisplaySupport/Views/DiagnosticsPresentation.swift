import SwiftUI
import VoidDisplayObservability

struct DiagnosticsPresentation {
    let snapshot: ObservabilityDiagnosticsSnapshot?

    var runtimeSummary: RuntimeDiagnosticsSummary {
        RuntimeDiagnosticsSummary(state: snapshot?.state)
    }

    var statusTitle: String {
        guard let snapshot else {
            return String(localized: "Diagnostics")
        }
        guard runtimeSummary.isAvailable else {
            return String(localized: "Runtime Snapshot Unavailable")
        }
        if snapshot.health.recentIssueCount > 0 {
            return String(localized: "Recent Issues")
        }
        if (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return String(localized: "Diagnostics Warning")
        }
        return String(localized: "Looks Good")
    }

    var statusRecommendation: String {
        guard let snapshot else {
            return String(localized: "If the issue happened recently, export a support package now.")
        }
        guard runtimeSummary.isAvailable else {
            return String(localized: "Refresh diagnostics, then export a support package if the runtime snapshot stays unavailable.")
        }
        if snapshot.health.recentIssueCount > 0 {
            return String(localized: "Review the recent issues below, then export another support package if needed.")
        }
        if (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return String(localized: "Review the recent events below, then export another support package if needed.")
        }
        return String(localized: "If the issue happened recently, export a support package now.")
    }

    var statusSystemImage: String {
        guard let snapshot else { return "arrow.triangle.2.circlepath" }
        guard runtimeSummary.isAvailable else { return "exclamationmark.triangle" }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    var statusTint: Color {
        guard let snapshot else { return .blue }
        guard runtimeSummary.isAvailable else { return .orange }
        if snapshot.health.recentIssueCount > 0 ||
            (snapshot.health.highestSeverity ?? .debug) >= .warning {
            return .orange
        }
        return .green
    }

    var collectedAreasLabel: String {
        "\(snapshot?.state.sections.count ?? 0)"
    }

    static func color(for severity: ObservabilitySeverity) -> Color {
        switch severity {
        case .debug:
            .secondary
        case .info, .notice:
            .blue
        case .warning:
            .orange
        case .error, .critical:
            .red
        }
    }
}
