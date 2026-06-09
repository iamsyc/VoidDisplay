@testable import VoidDisplayApp
@testable import VoidDisplayRuntime
import CoreGraphics
import Foundation
import Testing

struct HomeDashboardCardGroupResolverTests {
    @Test func groupsCardsByAttentionActiveIdleOrder() throws {
        let attentionID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let activeID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let idleID = try #require(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))

        let cards = [
            card(id: idleID, title: "Idle Display"),
            card(id: activeID, title: "Active Display", isRunning: true),
            card(id: attentionID, title: "Broken Display", hasIssue: true, statusTone: .warning)
        ]

        let groups = HomeDashboardCardGroupResolver.groupedCards(cards)

        #expect(groups.map(\.group) == [.attention, .active, .idle])
        #expect(groups.map { $0.cards.map(\.id) } == [[attentionID], [activeID], [idleID]])
    }

    private func card(
        id: UUID,
        title: String,
        isRunning: Bool = false,
        isPreviewing: Bool = false,
        isSharing: Bool = false,
        viewerCount: Int = 0,
        hasIssue: Bool = false,
        statusTone: DisplaySurfaceStatusTone = .neutral
    ) -> HomeVirtualDisplayCardPresentation {
        HomeVirtualDisplayCardPresentation(
            id: id,
            displayID: isRunning ? CGDirectDisplayID(7101) : nil,
            shareAddress: nil,
            title: title,
            subtitle: "1920 × 1080 @ 60Hz",
            desiredEnabled: isRunning,
            isRunning: isRunning,
            isPreviewing: isPreviewing,
            isSharing: isSharing,
            viewerCount: viewerCount,
            statusLabel: isRunning ? "Enabled · Running" : "Disabled",
            statusTone: statusTone,
            hasIssue: hasIssue,
            compactStatusItems: [],
            operationalStatusItems: [],
            accessibilitySummary: title
        )
    }
}
