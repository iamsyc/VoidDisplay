import SwiftUI
import VoidDisplayDesignSystem

package struct HomeClassicSkin<CardContent: View>: View {
    package let context: HomeSkinContext
    private let cardContent: CardContent

    package init(
        context: HomeSkinContext,
        @ViewBuilder cardContent: () -> CardContent
    ) {
        self.context = context
        self.cardContent = cardContent()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HomeHeaderControls(
                context: context,
                showsSummaryStatus: true,
                showsSharingSettingsPopover: true
            )
            cardContent
        }
    }
}

package struct HomeCompactSkin<CardContent: View>: View {
    package let context: HomeSkinContext
    private let cardContent: CardContent

    package init(
        context: HomeSkinContext,
        @ViewBuilder cardContent: () -> CardContent
    ) {
        self.context = context
        self.cardContent = cardContent()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            HomeHeaderControls(context: context)
            HomeSummaryPanel(context: context)
            cardContent
        }
    }
}

package struct HomeDashboardSkin<CardContent: View>: View {
    package let context: HomeSkinContext
    private let cardContent: CardContent

    package init(
        context: HomeSkinContext,
        @ViewBuilder cardContent: () -> CardContent
    ) {
        self.context = context
        self.cardContent = cardContent()
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.large) {
            HomeHeaderControls(context: context)
            HomeDashboardStatusBoard(context: context)
            cardContent
        }
    }
}

package struct HomeClassicCardSection: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        LazyVStack(alignment: .leading, spacing: context.theme.density.cardSpacing) {
            ForEach(context.cardStates) { state in
                HomeVirtualDisplayCard(
                    state: state,
                    style: .classic,
                    actions: context.actions
                )
                .accessibilityIdentifier("home_virtual_display_card")
            }
        }
        .accessibilityIdentifier("home_virtual_display_card_grid")
    }
}

package struct HomeCompactCardSection: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        LazyVStack(alignment: .leading, spacing: context.theme.density.cardSpacing) {
            ForEach(context.cardStates) { state in
                HomeVirtualDisplayCard(
                    state: state,
                    style: .compact,
                    actions: context.actions
                )
                .accessibilityIdentifier("home_virtual_display_card")
            }
        }
        .accessibilityIdentifier("home_virtual_display_card_grid")
    }
}

package struct HomeDashboardCardSection: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        let statesByID = Dictionary(uniqueKeysWithValues: context.cardStates.map { ($0.id, $0) })
        let groups = HomeDashboardCardGroupResolver.groupedCards(context.cardStates.map(\.card))

        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ForEach(groups) { entry in
                let group = entry.group
                let cards = entry.cards
                VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    LazyVStack(alignment: .leading, spacing: context.theme.density.cardSpacing) {
                        ForEach(cards) { card in
                            if let state = statesByID[card.id] {
                                HomeVirtualDisplayCard(
                                    state: state,
                                    style: .dashboard,
                                    actions: context.actions
                                )
                                .accessibilityIdentifier("home_virtual_display_card")
                            }
                        }
                    }
                }
                .accessibilityIdentifier(group.accessibilityIdentifier)
            }
        }
        .accessibilityIdentifier("home_virtual_display_card_grid")
    }
}
