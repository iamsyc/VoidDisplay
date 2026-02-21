import SwiftUI

struct AppRowStatus {
    let title: String
    let tint: Color
}

struct AppCornerRibbonModel {
    let title: String
    let tint: Color

    init(title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }
}

struct AppBadgeModel: Identifiable {
    let id = UUID()
    let title: String
    let style: AppStatusBadge.Style
    let isVisible: Bool

    init(title: String, style: AppStatusBadge.Style, isVisible: Bool = true) {
        self.title = title
        self.style = style
        self.isVisible = isVisible
    }
}

struct AppListRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let status: AppRowStatus?
    let metaBadges: [AppBadgeModel]
    let ribbon: AppCornerRibbonModel?
    let iconSystemName: String
    let isEmphasized: Bool
    let accessibilityIdentifier: String?

    init(
        id: String,
        title: String,
        subtitle: String,
        status: AppRowStatus?,
        metaBadges: [AppBadgeModel],
        ribbon: AppCornerRibbonModel? = nil,
        iconSystemName: String,
        isEmphasized: Bool,
        accessibilityIdentifier: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.metaBadges = metaBadges
        self.ribbon = ribbon
        self.iconSystemName = iconSystemName
        self.isEmphasized = isEmphasized
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
