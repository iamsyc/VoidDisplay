import Foundation
import SwiftUI
package struct AppRowStatus {
    package let title: String
    package let tint: Color

    package init(title: String, tint: Color) {
        self.title = title
        self.tint = tint
    }
}
package struct AppCornerRibbonModel {
    package let title: String
    package let tint: Color
    package let accessibilityIdentifier: String?

    package init(title: String, tint: Color, accessibilityIdentifier: String? = nil) {
        self.title = title
        self.tint = tint
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
package struct AppBadgeModel: Identifiable {
    package let id = UUID()
    package let title: String
    package let style: AppStatusBadge.Style
    package let isVisible: Bool

    package init(title: String, style: AppStatusBadge.Style, isVisible: Bool = true) {
        self.title = title
        self.style = style
        self.isVisible = isVisible
    }
}
package struct AppListRowModel: Identifiable {
    package let id: String
    package let title: String
    package let subtitle: String
    package let status: AppRowStatus?
    package let metaBadges: [AppBadgeModel]
    package let ribbon: AppCornerRibbonModel?
    package let iconSystemName: String
    package let iconScreenTint: Color?
    package let isEmphasized: Bool
    package let accessibilityIdentifier: String?

    package init(
        id: String,
        title: String,
        subtitle: String,
        status: AppRowStatus?,
        metaBadges: [AppBadgeModel],
        ribbon: AppCornerRibbonModel? = nil,
        iconSystemName: String,
        iconScreenTint: Color? = nil,
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
        self.iconScreenTint = iconScreenTint
        self.isEmphasized = isEmphasized
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
