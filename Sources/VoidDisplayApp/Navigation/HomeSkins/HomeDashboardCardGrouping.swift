import SwiftUI

package enum HomeDashboardCardGroup: String, CaseIterable, Identifiable {
    case attention
    case active
    case idle

    package var id: String { rawValue }

    package var title: LocalizedStringKey {
        switch self {
        case .attention:
            "Attention"
        case .active:
            "Active"
        case .idle:
            "Idle"
        }
    }

    package var accessibilityIdentifier: String {
        "home_dashboard_group_\(rawValue)"
    }
}

package struct HomeDashboardCardGroupSection: Identifiable {
    package let group: HomeDashboardCardGroup
    package let cards: [HomeVirtualDisplayCardPresentation]

    package var id: HomeDashboardCardGroup { group }

    package init(
        group: HomeDashboardCardGroup,
        cards: [HomeVirtualDisplayCardPresentation]
    ) {
        self.group = group
        self.cards = cards
    }
}

package enum HomeDashboardCardGroupResolver {
    package static func groupedCards(
        _ cards: [HomeVirtualDisplayCardPresentation]
    ) -> [HomeDashboardCardGroupSection] {
        HomeDashboardCardGroup.allCases.compactMap { group in
            let matches = cards.filter { card in
                self.group(for: card) == group
            }
            guard !matches.isEmpty else { return nil }
            return HomeDashboardCardGroupSection(group: group, cards: matches)
        }
    }

    package static func group(
        for card: HomeVirtualDisplayCardPresentation
    ) -> HomeDashboardCardGroup {
        if card.hasIssue || card.statusTone == .warning || card.statusTone == .danger {
            return .attention
        }
        if card.isRunning || card.isPreviewing || card.isSharing || card.viewerCount > 0 {
            return .active
        }
        return .idle
    }
}
