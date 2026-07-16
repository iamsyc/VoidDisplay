import SwiftUI
import VoidDisplayDesignSystem

package struct HomeLayoutConfiguration: Equatable {
    package struct Metrics: Equatable {
        package let itemHorizontalPadding: CGFloat
        package let itemVerticalPadding: CGFloat
        package let itemCornerRadius: CGFloat
        package let itemSpacing: CGFloat
        package let contentMaxWidth: CGFloat

        fileprivate init(
            itemHorizontalPadding: CGFloat,
            itemVerticalPadding: CGFloat,
            itemCornerRadius: CGFloat,
            itemSpacing: CGFloat,
            contentMaxWidth: CGFloat
        ) {
            self.itemHorizontalPadding = itemHorizontalPadding
            self.itemVerticalPadding = itemVerticalPadding
            self.itemCornerRadius = itemCornerRadius
            self.itemSpacing = itemSpacing
            self.contentMaxWidth = contentMaxWidth
        }
    }

    package let id: HomeLayoutID
    package let metrics: Metrics

    package init(id: HomeLayoutID) {
        self.id = id
        self.metrics = switch id {
        case .card:
            Metrics(
                itemHorizontalPadding: AppUI.Spacing.large,
                itemVerticalPadding: AppUI.Spacing.large,
                itemCornerRadius: AppUI.Corner.small,
                itemSpacing: AppUI.Spacing.medium,
                contentMaxWidth: 1280
            )
        case .list:
            Metrics(
                itemHorizontalPadding: AppUI.Spacing.large,
                itemVerticalPadding: AppUI.Spacing.medium,
                itemCornerRadius: 8,
                itemSpacing: AppUI.List.sectionSpacing,
                contentMaxWidth: 1240
            )
        }
    }
}
