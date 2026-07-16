import SwiftUI

package struct HomeCardGrid: View {
    private static let minimumCardWidth: CGFloat = 420
    private static let maximumCardWidth: CGFloat = 620

    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: context.layout.metrics.itemSpacing) {
            ForEach(context.itemStates) { state in
                HomeVirtualDisplayItem(
                    state: state,
                    layout: context.layout,
                    actions: context.actions
                )
                .accessibilityIdentifier("home_virtual_display_card")
            }
        }
        .accessibilityIdentifier("home_virtual_display_card_grid")
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: Self.minimumCardWidth,
                    maximum: Self.maximumCardWidth
                ),
                spacing: context.layout.metrics.itemSpacing,
                alignment: .top
            )
        ]
    }
}
