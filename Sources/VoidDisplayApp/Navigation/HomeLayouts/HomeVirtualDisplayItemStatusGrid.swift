import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayItemStatusGrid: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let actions: HomeLayoutActions

    package init(
        state: HomeVirtualDisplayItemRenderState,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var item: HomeVirtualDisplayItemPresentation { state.item }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.medium) {
            ForEach(item.operationalStatusItems) { statusItem in
                switch statusItem.id {
                case "preview":
                    HomeVirtualDisplayOperationalToggle(
                        statusItem: statusItem,
                        systemImage: "dot.scope.display",
                        isOn: item.isPreviewing,
                        isStarting: state.isPreviewStarting,
                        isDisabled: state.isPreviewActionDisabled,
                        accessibilityIdentifier: "home_virtual_display_preview_toggle",
                        onToggle: {
                            actions.perform(.preview, for: state)
                        }
                    )
                case "webView":
                    HomeVirtualDisplayOperationalToggle(
                        statusItem: statusItem,
                        systemImage: "network",
                        isOn: item.isSharing,
                        isStarting: state.isWebViewStarting,
                        isDisabled: state.isWebViewActionDisabled,
                        accessibilityIdentifier: "home_virtual_display_web_view_toggle",
                        onToggle: {
                            actions.perform(.webView, for: state)
                        }
                    )
                default:
                    HomeInlineStatusText(item: statusItem)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_item_status_grid")
    }
}
