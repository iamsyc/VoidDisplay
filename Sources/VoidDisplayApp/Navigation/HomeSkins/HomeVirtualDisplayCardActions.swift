import Foundation
import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayCardActionStack: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            HomeVirtualDisplayCardActionCluster(state: state, actions: actions)
            HomeVirtualDisplayCardToggleButton(state: state, actions: actions)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

package struct HomeVirtualDisplayCardActionCluster: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.xSmall + 2) {
            HomeVirtualDisplayCardPreviewButton(state: state, actions: actions)
            HomeVirtualDisplayCardWebViewButton(state: state, actions: actions)
            HomeVirtualDisplayCardCopyShareAddressButton(state: state, actions: actions)
            HomeVirtualDisplayCardEditButton(state: state, actions: actions)
            HomeVirtualDisplayCardMoreMenu(state: state, actions: actions)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

package struct HomeVirtualDisplayCardToggleButton: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    package var body: some View {
        Button {
            actions.perform(.toggle, for: state)
        } label: {
            if state.isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    card.desiredEnabled ? String(localized: "Disable") : String(localized: "Enable"),
                    systemImage: card.desiredEnabled ? "pause.fill" : "play.fill"
                )
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(card.desiredEnabled ? .orange : .green)
        .disabled(state.isBusy)
        .controlSize(.regular)
        .frame(minWidth: 86)
        .accessibilityIdentifier("virtual_display_toggle_button")
    }
}

package struct HomeVirtualDisplayCardPreviewButton: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    package var body: some View {
        Button {
            actions.perform(.preview, for: state)
        } label: {
            if state.isPreviewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: card.isPreviewing ? "stop.fill" : "dot.scope.display")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(state.isPreviewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(card.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityLabel(Text(card.isPreviewing ? String(localized: "Stop Preview") : String(localized: "Preview")))
        .accessibilityIdentifier("home_virtual_display_preview_button")
    }
}

package struct HomeVirtualDisplayCardWebViewButton: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    package var body: some View {
        Button {
            actions.perform(.webView, for: state)
        } label: {
            if state.isWebViewStarting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: card.isSharing ? "stop.fill" : "network")
            }
        }
        .appActionButtonStyle(variant: .default)
        .disabled(state.isWebViewActionDisabled)
        .controlSize(.small)
        .frame(minWidth: 32)
        .help(Text(card.isSharing ? String(localized: "Stop Sharing") : String(localized: "Sharing")))
        .accessibilityLabel(Text(card.isSharing ? String(localized: "Stop Sharing") : String(localized: "Sharing")))
        .accessibilityIdentifier("home_virtual_display_web_view_button")
    }
}

package struct HomeVirtualDisplayCardCopyShareAddressButton: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var shareAddress: String? {
        state.card.shareAddress
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

package struct HomeVirtualDisplayCardEditButton: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
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

package struct HomeVirtualDisplayCardMoreMenu: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let actions: HomeSkinActions

    package init(
        state: HomeVirtualDisplayCardRenderState,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.actions = actions
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    private var shareAddress: String? {
        card.shareAddress
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
                .disabled(!card.isSharing || shareURL == nil)

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

private extension HomeVirtualDisplayCardRenderState {
    var isBusy: Bool {
        isToggling || isRebuilding
    }
}
