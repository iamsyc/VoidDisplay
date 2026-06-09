import Foundation
import SwiftUI
import VoidDisplayDesignSystem

private enum HomeLayout {
    static let cardIdentityMinWidth: CGFloat = 300
    static let cardStatusMinWidth: CGFloat = 280
}

package enum HomeVirtualDisplayCardStyle {
    case classic
    case compact
    case dashboard
}

package struct HomeVirtualDisplayCard: View {
    package let state: HomeVirtualDisplayCardRenderState
    package let style: HomeVirtualDisplayCardStyle
    package let actions: HomeSkinActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appSkinID) private var skinID
    @State private var isHovered = false

    package init(
        state: HomeVirtualDisplayCardRenderState,
        style: HomeVirtualDisplayCardStyle,
        actions: HomeSkinActions
    ) {
        self.state = state
        self.style = style
        self.actions = actions
    }

    private var card: HomeVirtualDisplayCardPresentation { state.card }
    private var rebuildFailureMessage: String? { state.rebuildFailureMessage }

    private var theme: AppTheme {
        AppTheme.resolve(skinID: skinID, colorScheme: colorScheme)
    }

    package var body: some View {
        cardBody
        .padding(.horizontal, theme.density.cardHorizontalPadding)
        .padding(.vertical, theme.density.cardVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: theme.density.cardCornerRadius, style: .continuous)
                .fill(AppUI.Surface.cardFill(for: colorScheme, skinID: skinID))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.density.cardCornerRadius, style: .continuous)
                .stroke(cardStroke, lineWidth: AppUI.Stroke.subtle)
        )
        .overlay(alignment: .leading) {
            if showsStatusAccent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(statusAccent.opacity(colorScheme == .dark ? 0.72 : 0.58))
                    .frame(width: 3)
                    .padding(.vertical, AppUI.Spacing.medium)
                    .padding(.leading, 1)
            }
        }
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.accessibilitySummary))
    }

    @ViewBuilder
    private var cardBody: some View {
        switch style {
        case .classic:
            ViewThatFits(in: .horizontal) {
                wideLayout
                compactLayout
                narrowLayout
            }
        case .compact:
            compactRowLayout
        case .dashboard:
            dashboardLayout
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.large) {
            identityBlock
                .layoutPriority(2)
                .frame(minWidth: HomeLayout.cardIdentityMinWidth, alignment: .leading)

            if hasOperationalStatusItems {
                statusGrid
                    .layoutPriority(1)
                    .frame(minWidth: HomeLayout.cardStatusMinWidth, alignment: .leading)
            } else {
                Spacer(minLength: AppUI.Spacing.medium)
            }

            Spacer(minLength: AppUI.Spacing.small)

            actionStack
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .layoutPriority(1)

                Spacer(minLength: AppUI.Spacing.medium)

                toggleButton
            }

            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                if hasOperationalStatusItems {
                    statusGrid
                }

                Spacer(minLength: AppUI.Spacing.medium)

                compactActionCluster
            }
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .layoutPriority(1)

                Spacer(minLength: AppUI.Spacing.medium)

                toggleButton
            }

            if hasOperationalStatusItems {
                statusGrid
            }

            compactActionCluster
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var compactRowLayout: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            compactIdentityBlock
                .layoutPriority(2)
                .frame(minWidth: 240, alignment: .leading)

            if hasOperationalStatusItems {
                statusGrid
                    .layoutPriority(1)
                    .frame(minWidth: 250, alignment: .leading)
            }

            Spacer(minLength: AppUI.Spacing.small)

            compactActionCluster
            toggleButton
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }

    private var dashboardLayout: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                identityBlock
                    .layoutPriority(1)

                Spacer(minLength: AppUI.Spacing.medium)

                toggleButton
            }

            if hasOperationalStatusItems {
                statusGrid
            }

            HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                compactActionCluster
                Spacer(minLength: AppUI.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var identityBlock: some View {
        HomeVirtualDisplayCardIdentityBlock(state: state, style: .regular)
    }

    private var compactIdentityBlock: some View {
        HomeVirtualDisplayCardIdentityBlock(state: state, style: .compact)
    }

    private var statusGrid: some View {
        HomeVirtualDisplayCardStatusGrid(card: card)
    }

    private var actionStack: some View {
        HomeVirtualDisplayCardActionStack(state: state, actions: actions)
    }

    private var compactActionCluster: some View {
        HomeVirtualDisplayCardActionCluster(state: state, actions: actions)
    }

    private var hasOperationalStatusItems: Bool {
        !card.operationalStatusItems.isEmpty
    }

    private var toggleButton: some View {
        HomeVirtualDisplayCardToggleButton(state: state, actions: actions)
    }

    private var cardStroke: Color {
        if card.hasIssue || rebuildFailureMessage != nil {
            return AppThemeStatusPalette.resolve(skinID: skinID).warning
                .opacity(colorScheme == .dark ? 0.52 : 0.36)
        }
        if isHovered {
            return AppUI.Surface.cardHoverStroke(for: colorScheme, skinID: skinID)
        }
        return AppUI.Surface.cardStroke(for: colorScheme, skinID: skinID)
    }

    private var showsStatusAccent: Bool {
        card.isRunning || card.hasIssue || rebuildFailureMessage != nil
    }

    private var statusAccent: Color {
        if card.hasIssue || rebuildFailureMessage != nil {
            return AppThemeStatusPalette.resolve(skinID: skinID).warning
        }
        return card.isRunning ? AppThemeStatusPalette.resolve(skinID: skinID).success : .secondary
    }
}
