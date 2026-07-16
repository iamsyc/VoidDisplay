import SwiftUI

package struct HomeListRows: View {
    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        LazyVStack(alignment: .leading, spacing: context.layout.metrics.itemSpacing) {
            ForEach(context.itemStates) { state in
                HomeVirtualDisplayItem(
                    state: state,
                    layout: context.layout,
                    actions: context.actions
                )
                .accessibilityIdentifier("home_virtual_display_list_row")
            }
        }
        .accessibilityIdentifier("home_virtual_display_list")
    }
}
