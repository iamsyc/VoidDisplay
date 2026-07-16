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

    package static let list = HomeLayoutConfiguration(
        metrics: Metrics(
            itemHorizontalPadding: AppUI.Spacing.large,
            itemVerticalPadding: AppUI.Spacing.medium,
            itemCornerRadius: 8,
            itemSpacing: AppUI.List.sectionSpacing,
            contentMaxWidth: 1240
        )
    )

    package let metrics: Metrics

    private init(metrics: Metrics) {
        self.metrics = metrics
    }
}
