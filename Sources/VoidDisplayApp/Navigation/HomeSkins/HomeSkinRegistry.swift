import SwiftUI
import VoidDisplayDesignSystem

package struct HomeSkinMetadata: Identifiable, Equatable {
    package let id: AppSkinID
    package let titleKey: String

    package init(id: AppSkinID, titleKey: String) {
        self.id = id
        self.titleKey = titleKey
    }
}

package enum HomeSkinRegistry {
    package static let metadata: [HomeSkinMetadata] = [
        HomeSkinMetadata(id: .classic, titleKey: "Classic"),
        HomeSkinMetadata(id: .compact, titleKey: "Compact"),
        HomeSkinMetadata(id: .dashboard, titleKey: "Dashboard")
    ]

    package static var allSkinIDs: [AppSkinID] {
        metadata.map(\.id)
    }

    package static func metadata(for skinID: AppSkinID) -> HomeSkinMetadata {
        guard let metadata = metadata.first(where: { $0.id == skinID }) else {
            preconditionFailure("Missing Home skin metadata for \(skinID)")
        }
        return metadata
    }

    package static func title(for skinID: AppSkinID) -> LocalizedStringKey {
        LocalizedStringKey(metadata(for: skinID).titleKey)
    }

    @MainActor
    @ViewBuilder
    package static func makeSkin<CardContent: View>(
        for skinID: AppSkinID,
        context: HomeSkinContext,
        @ViewBuilder cardContent: () -> CardContent
    ) -> some View {
        switch skinID {
        case .classic:
            HomeClassicSkin(context: context, cardContent: cardContent)
        case .compact:
            HomeCompactSkin(context: context, cardContent: cardContent)
        case .dashboard:
            HomeDashboardSkin(context: context, cardContent: cardContent)
        }
    }

    @MainActor
    @ViewBuilder
    package static func makeCardContent(
        for skinID: AppSkinID,
        context: HomeSkinContext
    ) -> some View {
        switch skinID {
        case .classic:
            HomeClassicCardSection(context: context)
        case .compact:
            HomeCompactCardSection(context: context)
        case .dashboard:
            HomeDashboardCardSection(context: context)
        }
    }
}
