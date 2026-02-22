import SwiftUI

struct VirtualDisplayRowPresentation {
    static func subtitleText(for config: VirtualDisplayConfig) -> String {
        let serial = "\(String(localized: "Serial Number")): \(config.serialNum)"
        guard let mode = modeSummary(for: config) else {
            return serial
        }

        return "\(serial) • \(mode)"
    }

    static func modeSummary(for config: VirtualDisplayConfig) -> String? {
        guard let maxMode = config.modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            return nil
        }

        return "\(maxMode.width) × \(maxMode.height)"
    }

    static func statusLabel(isRunning: Bool, isRebuilding: Bool) -> String {
        if isRebuilding {
            return String(localized: "Rebuilding")
        }

        if isRunning {
            return String(localized: "Enable")
        }

        return String(localized: "Disable")
    }

    static func statusTint(isRunning: Bool, isRebuilding: Bool) -> Color {
        if isRebuilding {
            return .orange
        }

        return isRunning ? .green : .gray
    }

    static func badges(rebuildFailureMessage: String?, hasRecentApplySuccess: Bool) -> [AppBadgeModel] {
        var badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: String(localized: "Virtual Display"),
                style: .roundedTag(tint: .blue)
            )
        ]

        if hasRecentApplySuccess {
            badges.append(
                AppBadgeModel(
                    title: String(localized: "Applied"),
                    style: .roundedTag(tint: .green)
                )
            )
        }

        if rebuildFailureMessage != nil {
            badges.append(
                AppBadgeModel(
                    title: String(localized: "Rebuild failed"),
                    style: .roundedTag(tint: .red)
                )
            )
        }

        return badges
    }

    static func toggleButtonTitle(isRunning: Bool) -> String {
        if isRunning {
            return String(localized: "Disable")
        }

        return String(localized: "Enable")
    }

    static func restoreFailureSummary(_ failures: [VirtualDisplayRestoreFailure], maxVisible: Int = 3) -> String {
        let items = failures.prefix(maxVisible)
        let summary = items
            .map { "\($0.name) (Serial \($0.serialNum)): \($0.message)" }
            .joined(separator: "\n\n")

        if failures.count > maxVisible {
            return summary + "\n\n…"
        }

        return summary
    }
}
