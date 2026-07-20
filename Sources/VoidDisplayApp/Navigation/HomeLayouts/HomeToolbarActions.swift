import SwiftUI

package struct HomeToolbarActions: ToolbarContent {
    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Refresh", systemImage: "arrow.clockwise", action: context.actions.refresh)
                .labelStyle(.iconOnly)
                .help(Text("Refresh"))
                .accessibilityIdentifier("home_refresh_button")
        }

        ToolbarItem(placement: .automatic) {
            HomeSharingSettingsPopoverButton(context: context)
                .labelStyle(.titleAndIcon)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(
                "Add Virtual Display",
                systemImage: "plus",
                action: context.actions.createVirtualDisplay
            )
            .labelStyle(.titleAndIcon)
            .disabled(context.isCreateVirtualDisplayDisabled)
            .accessibilityIdentifier("home_add_virtual_display_button")
        }
    }
}
