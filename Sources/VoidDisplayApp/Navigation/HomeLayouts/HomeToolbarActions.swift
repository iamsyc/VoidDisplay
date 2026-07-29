import SwiftUI

package struct HomeToolbarActions: ToolbarContent {
    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: context.actions.rescanDisplays) {
                Label {
                    if context.showsRescanToolbarTitle {
                        Text(verbatim: context.displayDetection.toolbarTitle)
                    }
                } icon: {
                    ZStack {
                        Image(
                            systemName: context.showsRescanToolbarTitle
                                ? "display"
                                : "arrow.clockwise"
                        )
                        .opacity(context.displayDetection.isScanning ? 0 : 1)

                        ProgressView()
                            .controlSize(.small)
                            .opacity(context.displayDetection.isScanning ? 1 : 0)
                    }
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                }
            }
            .labelStyle(.titleAndIcon)
            .disabled(context.displayDetection.isScanning)
            .help(Text("Get the latest displays available for preview and sharing. Use after connecting or disconnecting a display, granting Screen Recording permission, or when the display list is out of date."))
            .accessibilityLabel(Text(verbatim: context.displayDetection.toolbarTitle))
            .accessibilityValue(Text(verbatim: context.displayDetection.toolbarAccessibilityValue))
            .accessibilityHint(Text("Gets the latest displays available for preview and sharing."))
            .accessibilityIdentifier("home_rescan_displays_button")
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
