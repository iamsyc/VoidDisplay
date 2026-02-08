import SwiftUI

struct AppRowStatus {
    let title: String
    let tint: Color
}

struct AppBadgeModel: Identifiable {
    let id = UUID()
    let title: String
    let style: AppStatusBadge.Style
}

struct AppListRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let status: AppRowStatus?
    let metaBadges: [AppBadgeModel]
    let iconSystemName: String
    let isEmphasized: Bool
    let accessibilityIdentifier: String?
}
