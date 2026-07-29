import SwiftUI
import VoidDisplayDesignSystem

package struct HomeLayoutMetrics: Equatable {
    package static let current = HomeLayoutMetrics(
        itemHorizontalPadding: AppUI.Spacing.large,
        itemVerticalPadding: AppUI.List.rowVerticalInset,
        itemCornerRadius: 8,
        itemSpacing: AppUI.List.sectionSpacing,
        contentMaxWidth: 1240,
        minimumContentWidthForRescanToolbarTitle: 700
    )

    package let itemHorizontalPadding: CGFloat
    package let itemVerticalPadding: CGFloat
    package let itemCornerRadius: CGFloat
    package let itemSpacing: CGFloat
    package let contentMaxWidth: CGFloat
    package let minimumContentWidthForRescanToolbarTitle: CGFloat

    private init(
        itemHorizontalPadding: CGFloat,
        itemVerticalPadding: CGFloat,
        itemCornerRadius: CGFloat,
        itemSpacing: CGFloat,
        contentMaxWidth: CGFloat,
        minimumContentWidthForRescanToolbarTitle: CGFloat
    ) {
        self.itemHorizontalPadding = itemHorizontalPadding
        self.itemVerticalPadding = itemVerticalPadding
        self.itemCornerRadius = itemCornerRadius
        self.itemSpacing = itemSpacing
        self.contentMaxWidth = contentMaxWidth
        self.minimumContentWidthForRescanToolbarTitle = minimumContentWidthForRescanToolbarTitle
    }
}
