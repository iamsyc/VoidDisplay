import SwiftUI

package struct HomeLayoutMetadata: Identifiable, Equatable {
    package let id: HomeLayoutID
    package let titleKey: String

    package init(id: HomeLayoutID, titleKey: String) {
        self.id = id
        self.titleKey = titleKey
    }
}

package enum HomeLayoutRegistry {
    package static let metadata: [HomeLayoutMetadata] = [
        HomeLayoutMetadata(id: .card, titleKey: "Card"),
        HomeLayoutMetadata(id: .list, titleKey: "List")
    ]

    package static var allLayoutIDs: [HomeLayoutID] {
        metadata.map(\.id)
    }

    package static func metadata(for layoutID: HomeLayoutID) -> HomeLayoutMetadata {
        guard let metadata = metadata.first(where: { $0.id == layoutID }) else {
            preconditionFailure("Missing Home layout metadata for \(layoutID)")
        }
        return metadata
    }

    package static func title(for layoutID: HomeLayoutID) -> LocalizedStringKey {
        LocalizedStringKey(metadata(for: layoutID).titleKey)
    }

    @MainActor
    @ViewBuilder
    package static func makeContent(context: HomeLayoutContext) -> some View {
        switch context.layout.id {
        case .card:
            HomeCardGrid(context: context)
        case .list:
            HomeListRows(context: context)
        }
    }
}
