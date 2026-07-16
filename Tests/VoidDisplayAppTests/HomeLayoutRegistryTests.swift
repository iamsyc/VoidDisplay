@testable import VoidDisplayApp
import Testing

struct HomeLayoutRegistryTests {
    @Test func homeLayoutIDsExposeStableBuiltInOrder() {
        #expect(HomeLayoutID.allCases == [.card, .list])
    }

    @Test func layoutConfigurationOwnsMetricsForSelectedLayout() {
        let card = HomeLayoutConfiguration(id: .card)
        let list = HomeLayoutConfiguration(id: .list)

        #expect(card.id == .card)
        #expect(list.id == .list)
        #expect(card.metrics.itemVerticalPadding > list.metrics.itemVerticalPadding)
        #expect(card.metrics.itemCornerRadius > list.metrics.itemCornerRadius)
        #expect(card.metrics.itemSpacing > list.metrics.itemSpacing)
    }

    @Test func exposesMetadataForEveryHomeLayout() {
        #expect(HomeLayoutRegistry.allLayoutIDs == HomeLayoutID.allCases)
        #expect(HomeLayoutRegistry.metadata.map(\.id) == HomeLayoutID.allCases)
    }

    @Test func exposesStableBuiltInTitleKeys() {
        #expect(HomeLayoutRegistry.metadata.map(\.titleKey) == [
            "Card",
            "List"
        ])
    }

    @Test func metadataLookupReturnsRegisteredEntry() {
        for registeredMetadata in HomeLayoutRegistry.metadata {
            #expect(HomeLayoutRegistry.metadata(for: registeredMetadata.id) == registeredMetadata)
        }
    }

    @Test func metadataDoesNotDuplicateLayoutIDsOrTitleKeys() {
        let ids = HomeLayoutRegistry.metadata.map(\.id)
        let titleKeys = HomeLayoutRegistry.metadata.map(\.titleKey)

        #expect(Set(ids).count == ids.count)
        #expect(Set(titleKeys).count == titleKeys.count)
    }
}
