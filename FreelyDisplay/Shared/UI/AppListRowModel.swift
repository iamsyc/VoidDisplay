import SwiftUI

struct AppBadgeModel: Identifiable {
    let id = UUID()
    let title: String
    let style: AppStatusBadge.Style
}

struct AppListRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let metaBadges: [AppBadgeModel]
    let iconSystemName: String
    let isEmphasized: Bool
    var accessibilityIdentifier: String?
}
