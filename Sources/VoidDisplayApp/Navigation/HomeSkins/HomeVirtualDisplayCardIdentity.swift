import SwiftUI
import VoidDisplayDesignSystem

package enum HomeVirtualDisplayCardIdentityStyle {
    case regular
    case compact
}

package struct HomeVirtualDisplayCardIdentityBlock: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let style: HomeVirtualDisplayCardIdentityStyle

    package init(
        state: HomeVirtualDisplayCardRenderState,
        style: HomeVirtualDisplayCardIdentityStyle = .regular
    ) {
        self.state = state
        self.style = style
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    package var body: some View {
        switch style {
        case .regular:
            regularBody
        case .compact:
            compactBody
        }
    }

    private var regularBody: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small + 2) {
            displayIcon(size: 25, frameSize: 40)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HomeVirtualDisplayCardStatusBadgeRow(state: state)
            }
        }
    }

    private var compactBody: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            displayIcon(size: 20, frameSize: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HomeVirtualDisplayCardPrimaryStatusBadge(state: state)
                }

                Text(card.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            isPreviewing: card.isPreviewing,
            isSharing: card.isSharing
        ) ?? (card.isRunning ? DisplayIconTintResolver.enabledIdle : .secondary)
    }
}

package struct HomeVirtualDisplayCardStatusBadgeRow: View {
    package let state: HomeVirtualDisplayCardRenderState

    package init(state: HomeVirtualDisplayCardRenderState) {
        self.state = state
    }

    package var body: some View {
        HStack(spacing: 6) {
            HomeVirtualDisplayCardPrimaryStatusBadge(state: state)

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

package struct HomeVirtualDisplayCardPrimaryStatusBadge: View {
    package let state: HomeVirtualDisplayCardRenderState

    package init(state: HomeVirtualDisplayCardRenderState) {
        self.state = state
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }

    package var body: some View {
        if let rebuildFailureMessage = state.rebuildFailureMessage {
            HomeStatusBadge(
                title: card.statusLabel,
                tone: card.statusTone
            )
            .help(rebuildFailureMessage)
        } else {
            HomeStatusBadge(
                title: card.statusLabel,
                tone: card.statusTone
            )
        }
    }
}

package struct HomeVirtualDisplayCardStatusGrid: View {
    package let card: HomeVirtualDisplayCardPresentation

    package init(card: HomeVirtualDisplayCardPresentation) {
        self.card = card
    }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.medium) {
            ForEach(card.operationalStatusItems) { item in
                HomeInlineStatusText(item: item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("home_card_status_grid")
    }
}
