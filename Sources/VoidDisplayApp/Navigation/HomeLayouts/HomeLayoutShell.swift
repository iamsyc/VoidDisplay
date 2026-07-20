import SwiftUI
import VoidDisplayDesignSystem

package struct HomeLayoutShell<LayoutContent: View>: View {
    package let context: HomeLayoutContext
    private let content: LayoutContent

    package init(
        context: HomeLayoutContext,
        @ViewBuilder content: () -> LayoutContent
    ) {
        self.context = context
        self.content = content()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HomeSummaryStatusStrip(context: context)
            content
        }
        .toolbar {
            HomeToolbarActions(context: context)
        }
    }
}
