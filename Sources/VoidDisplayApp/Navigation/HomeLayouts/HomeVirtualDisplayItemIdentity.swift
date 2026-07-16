import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayItemIdentityBlock: View {
    package let state: HomeVirtualDisplayItemRenderState

    package init(state: HomeVirtualDisplayItemRenderState) {
        self.state = state
    }

    private var item: HomeVirtualDisplayItemPresentation { state.item }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small + 2) {
            displayIcon(size: 25, frameSize: 40)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HomeVirtualDisplayItemStatusBadgeRow(state: state)
            }
        }
    }

    private func displayIcon(size: CGFloat, frameSize: CGFloat) -> some View {
        Image(systemName: "display")
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.primary.opacity(0.88), iconTint)
            .frame(width: frameSize, height: frameSize)
            .appTileStyle()
    }

    private var iconTint: Color {
        DisplayIconTintResolver.resolve(
            isPreviewing: item.isPreviewing,
            isSharing: item.isSharing
        ) ?? (item.isRunning ? DisplayIconTintResolver.enabledIdle : .secondary)
    }
}

package struct HomeVirtualDisplayItemStatusBadgeRow: View {
    package let state: HomeVirtualDisplayItemRenderState

    package init(state: HomeVirtualDisplayItemRenderState) {
        self.state = state
    }

    package var body: some View {
        HStack(spacing: 6) {
            HomeVirtualDisplayItemPrimaryStatusBadge(state: state)

            if state.isPrimary {
                HomeStatusBadge(
                    title: String(localized: "Primary Display"),
                    tone: .success
                )
                .accessibilityIdentifier("virtual_display_primary_ribbon")
            }

            if state.hasRecentApplySuccess {
                HomeStatusBadge(
                    title: String(localized: "Applied"),
                    tone: .success
                )
            }
        }
    }
}

package struct HomeVirtualDisplayItemPrimaryStatusBadge: View {
    package let state: HomeVirtualDisplayItemRenderState

    package init(state: HomeVirtualDisplayItemRenderState) {
        self.state = state
    }

    private var item: HomeVirtualDisplayItemPresentation { state.item }

    package var body: some View {
        if let rebuildFailureMessage = state.rebuildFailureMessage {
            HomeStatusBadge(
                title: item.statusLabel,
                tone: item.statusTone
            )
            .help(rebuildFailureMessage)
        } else {
            HomeStatusBadge(
                title: item.statusLabel,
                tone: item.statusTone
            )
        }
    }
}

package struct HomeVirtualDisplayItemStatusGrid: View {
    package let item: HomeVirtualDisplayItemPresentation

    package init(item: HomeVirtualDisplayItemPresentation) {
        self.item = item
    }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.medium) {
            ForEach(item.operationalStatusItems) { statusItem in
                HomeInlineStatusText(item: statusItem)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("home_card_status_grid")
    }
}
