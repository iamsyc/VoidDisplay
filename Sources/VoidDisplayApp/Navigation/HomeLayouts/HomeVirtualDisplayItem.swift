import Foundation
import SwiftUI
import VoidDisplayDesignSystem

private enum HomeItemLayoutConstants {
    static let wideIdentityMinWidth: CGFloat = 250
    static let wideStatusMinWidth: CGFloat = 220
}

package struct HomeVirtualDisplayItem: View {
    package let state: HomeVirtualDisplayItemRenderState
    package let metrics: HomeLayoutMetrics
    package let actions: HomeLayoutActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    package init(
        state: HomeVirtualDisplayItemRenderState,
        metrics: HomeLayoutMetrics,
        actions: HomeLayoutActions
    ) {
        self.state = state
        self.metrics = metrics
        self.actions = actions
    }

    private var item: HomeVirtualDisplayItemPresentation { state.item }
    private var rebuildFailureMessage: String? { state.rebuildFailureMessage }

    package var body: some View {
        itemBody
        .padding(.horizontal, metrics.itemHorizontalPadding)
        .padding(.vertical, metrics.itemVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: metrics.itemCornerRadius, style: .continuous)
                .fill(AppUI.Surface.cardFill(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.itemCornerRadius, style: .continuous)
                .stroke(itemStroke, lineWidth: AppUI.Stroke.subtle)
        )
        .overlay(alignment: .leading) {
            if showsIssueAccent {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(AppThemeStatusPalette.standard.warning.opacity(colorScheme == .dark ? 0.72 : 0.58))
                    .frame(width: 3)
                    .padding(.vertical, AppUI.Spacing.medium)
                    .padding(.leading, 1)
            }
        }
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.accessibilitySummary))
    }

    private var itemBody: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
            narrowLayout
        }
    }

    private var wideLayout: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.large) {
            identityBlock
                .layoutPriority(2)
                .frame(minWidth: HomeItemLayoutConstants.wideIdentityMinWidth, alignment: .leading)

            if hasOperationalStatusItems {
                statusGrid
                    .layoutPriority(1)
                    .frame(minWidth: HomeItemLayoutConstants.wideStatusMinWidth, alignment: .leading)
            } else {
                Spacer(minLength: AppUI.Spacing.medium)
            }

            Spacer(minLength: AppUI.Spacing.small)

            actionStack
        }
        .frame(maxWidth: .infinity, minHeight: AppUI.List.rowMinHeight, alignment: .leading)
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

                actionCluster
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

            actionCluster
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var identityBlock: some View {
        HomeVirtualDisplayItemIdentityBlock(state: state)
    }

    private var statusGrid: some View {
        HomeVirtualDisplayItemStatusGrid(state: state, actions: actions)
    }

    private var actionStack: some View {
        HomeVirtualDisplayItemActionStack(state: state, actions: actions)
    }

    private var actionCluster: some View {
        HomeVirtualDisplayItemActionCluster(state: state, actions: actions)
    }

    private var hasOperationalStatusItems: Bool {
        !item.operationalStatusItems.isEmpty
    }

    private var toggleButton: some View {
        HomeVirtualDisplayItemToggleButton(state: state, actions: actions)
    }

    private var itemStroke: Color {
        if item.hasIssue || rebuildFailureMessage != nil {
            return AppThemeStatusPalette.standard.warning
                .opacity(colorScheme == .dark ? 0.52 : 0.36)
        }
        if isHovered {
            return AppUI.Surface.cardHoverStroke(for: colorScheme)
        }
        return AppUI.Surface.cardStroke(for: colorScheme)
    }

    private var showsIssueAccent: Bool {
        item.hasIssue || rebuildFailureMessage != nil
    }
}
