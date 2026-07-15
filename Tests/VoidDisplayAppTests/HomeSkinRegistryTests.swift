@testable import VoidDisplayApp
@testable import VoidDisplayDesignSystem
import Testing

struct HomeSkinRegistryTests {
    @Test func exposesMetadataForEveryAppSkin() {
        #expect(HomeSkinRegistry.allSkinIDs == AppSkinID.allCases)
        #expect(HomeSkinRegistry.metadata.map(\.id) == AppSkinID.allCases)
    }

    @Test func exposesStableBuiltInTitleKeys() {
        #expect(HomeSkinRegistry.metadata.map(\.titleKey) == [
            "Classic",
            "Compact",
            "Dashboard"
        ])
    }

    @Test func metadataLookupReturnsRegisteredEntry() {
        for registeredMetadata in HomeSkinRegistry.metadata {
            #expect(HomeSkinRegistry.metadata(for: registeredMetadata.id) == registeredMetadata)
        }
    }

    @Test func metadataDoesNotDuplicateSkinIDsOrTitleKeys() {
        let ids = HomeSkinRegistry.metadata.map(\.id)
        let titleKeys = HomeSkinRegistry.metadata.map(\.titleKey)

        #expect(Set(ids).count == ids.count)
        #expect(Set(titleKeys).count == titleKeys.count)
    }
}
