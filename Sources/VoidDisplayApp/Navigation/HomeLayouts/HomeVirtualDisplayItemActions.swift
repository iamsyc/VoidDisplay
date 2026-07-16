import Foundation
import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayItemActionStack: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let actions: HomeLayoutActions

    package init(
        state: HomeVirtualDisplayItemRenderState,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            HomeVirtualDisplayItemActionCluster(state: state, actions: actions)
            HomeVirtualDisplayItemToggleButton(state: state, actions: actions)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

package struct HomeVirtualDisplayItemActionCluster: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let actions: HomeLayoutActions

    package init(
        state: HomeVirtualDisplayItemRenderState,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.xSmall + 2) {
            HomeVirtualDisplayItemPreviewButton(state: state, actions: actions)
            HomeVirtualDisplayItemWebViewButton(state: state, actions: actions)
            HomeVirtualDisplayItemCopyShareAddressButton(state: state, actions: actions)
            HomeVirtualDisplayItemEditButton(state: state, actions: actions)
            HomeVirtualDisplayItemMoreMenu(state: state, actions: actions)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

package struct HomeVirtualDisplayItemToggleButton: View {
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
        Button {
            actions.perform(.toggle, for: state)
        } label: {
            if state.isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    item.desiredEnabled ? String(localized: "Disable") : String(localized: "Enable"),
                    systemImage: item.desiredEnabled ? "pause.fill" : "play.fill"
                )
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(item.desiredEnabled ? .orange : .green)
        .disabled(state.isBusy)
        .controlSize(.regular)
        .frame(minWidth: 86)
        .accessibilityIdentifier("virtual_display_toggle_button")
    }
}

package struct HomeVirtualDisplayItemPreviewButton: View {
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
        Button {
            actions.perform(.preview, for: state)
        } label: {
            if state.isPreviewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: item.isPreviewing ? "stop.fill" : "dot.scope.display")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(state.isPreviewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(item.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityLabel(Text(item.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityIdentifier("home_virtual_display_preview_button")
    }
}

package struct HomeVirtualDisplayItemWebViewButton: View {
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
        Button {
            actions.perform(.webView, for: state)
        } label: {
            if state.isWebViewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: item.isSharing ? "stop.fill" : "network")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(state.isWebViewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(item.isSharing ? String(localized: "Stop Sharing") : String(localized: "Sharing")))
        .accessibilityLabel(Text(item.isSharing ? String(localized: "Stop Sharing") : String(localized: "Sharing")))
        .accessibilityIdentifier("home_virtual_display_web_view_button")
    }
}

package struct HomeVirtualDisplayItemCopyShareAddressButton: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let actions: HomeLayoutActions

    package init(
        state: HomeVirtualDisplayItemRenderState,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var shareAddress: String? {
        state.item.shareAddress
    }

    package var body: some View {
        if let shareAddress {
            Button {
                actions.perform(.copyShareAddress, for: state)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .appActionButtonStyle(variant: .default)
            .controlSize(.small)
            .frame(minWidth: 32)
            .help(shareAddress)
            .accessibilityLabel(Text("Copy Link"))
            .accessibilityValue(Text(verbatim: shareAddress))
            .accessibilityIdentifier("home_virtual_display_copy_share_address_button")
        }
    }
}

package struct HomeVirtualDisplayItemEditButton: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let actions: HomeLayoutActions

    package init(
        state: HomeVirtualDisplayItemRenderState,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        Button {
            actions.perform(.edit, for: state)
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .appActionButtonStyle(variant: .default)
        .disabled(state.isBusy)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text("Edit"))
        .accessibilityLabel(Text("Edit"))
        .accessibilityIdentifier("virtual_display_edit_button")
    }
}

package struct HomeVirtualDisplayItemMoreMenu: View {
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

    private var shareAddress: String? {
        item.shareAddress
    }

    private var shareURL: URL? {
        shareAddress.flatMap(URL.init(string:))
    }

    package var body: some View {
        Menu {
            if shareAddress != nil {
                Button("Open Share Page", systemImage: "link") {
                    actions.perform(.openSharePage, for: state)
                }
                .disabled(!item.isSharing || shareURL == nil)

                Button("Copy display address", systemImage: "doc.on.doc") {
                    actions.perform(.copyShareAddress, for: state)
                }

                Divider()
            }

            Button("Set as Primary", systemImage: state.isPrimary ? "star.circle.fill" : "star.circle") {
                actions.perform(.setPrimary, for: state)
            }
            .disabled(!state.canSetAsPrimary)

            Divider()

            Button("Move up", systemImage: "chevron.up") {
                actions.perform(.moveUp, for: state)
            }
            .disabled(state.isFirst || state.isBusy)

            Button("Move down", systemImage: "chevron.down") {
                actions.perform(.moveDown, for: state)
            }
            .disabled(state.isLast || state.isBusy)

            if state.rebuildFailureMessage != nil {
                Divider()
                Button("Retry Rebuild", systemImage: "arrow.clockwise") {
                    actions.perform(.retryRebuild, for: state)
                }
                .disabled(state.isBusy)
            }

            Divider()

            Button("Delete", systemImage: "trash", role: .destructive) {
                actions.perform(.delete, for: state)
            }
            .disabled(state.isBusy)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .help(Text("More"))
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("home_virtual_display_more_button")
    }
}

private extension HomeVirtualDisplayItemRenderState {
    var isBusy: Bool {
        isToggling || isRebuilding
    }
}
