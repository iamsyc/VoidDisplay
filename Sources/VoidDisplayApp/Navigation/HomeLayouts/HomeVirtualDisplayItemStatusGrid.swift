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
            if state.needsDisplayDetection {
                Button(action: actions.rescanDisplays) {
                    Label {
                        Text("Rescan Displays")
                    } icon: {
                        ZStack {
                            Image(systemName: "arrow.clockwise")
                                .opacity(state.isDisplayDetectionScanning ? 0 : 1)

                            ProgressView()
                                .controlSize(.small)
                                .opacity(state.isDisplayDetectionScanning ? 1 : 0)
                        }
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    }
                }
                .appActionButtonStyle(variant: .default)
                .controlSize(.small)
                .disabled(state.isDisplayDetectionScanning)
                .help(Text("This virtual display is running but isn’t available for preview or sharing. Rescan displays to detect it."))
                .accessibilityValue(
                    state.isDisplayDetectionScanning
                        ? Text("Detecting Displays…")
                        : Text(verbatim: "")
                )
                .accessibilityIdentifier("home_virtual_display_rescan_button")
            } else {
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
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_item_status_grid")
    }
}
