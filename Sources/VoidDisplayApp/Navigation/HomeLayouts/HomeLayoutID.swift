import SwiftUI

package enum HomeLayoutID: String, CaseIterable, Identifiable, Sendable {
    case card
    case list

    package var id: String { rawValue }
}

package extension EnvironmentValues {
    @Entry var homeLayoutID: HomeLayoutID = .card
}

package extension View {
    func homeLayout(_ layoutID: HomeLayoutID) -> some View {
        environment(\.homeLayoutID, layoutID)
    }
}
