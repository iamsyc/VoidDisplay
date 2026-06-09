import SwiftUI
import VoidDisplayDesignSystem

package struct HomeHeaderControls: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                titleBlock
                Spacer(minLength: AppUI.Spacing.large)
                actionButtons
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                titleBlock
                actionButtons
            }
        }
    }

    private var titleBlock: some View {
        Label("Virtual Displays", systemImage: "display.2")
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("home_virtual_display_title")
    }

    private var actionButtons: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button {
                context.actions.createVirtualDisplay()
            } label: {
                Label("Add Virtual Display", systemImage: "plus")
            }
            .appActionButtonStyle(variant: .primary)
            .disabled(context.isCreateVirtualDisplayDisabled)
            .accessibilityIdentifier("home_add_virtual_display_button")

            Button {
                context.actions.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .appActionButtonStyle(variant: .default)
            .accessibilityIdentifier("home_refresh_button")
        }
        .labelStyle(.titleAndIcon)
    }
}
