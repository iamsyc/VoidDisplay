import Foundation
import SwiftUI
package struct AppQuickActionsMenu<MenuContent: View>: View {
    package let label: String
    package var accessibilityIdentifier: String?
    private let menuContent: MenuContent

    package init(
        _ label: String = String(localized: "Quick Actions"),
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> MenuContent
    ) {
        self.label = label
        self.accessibilityIdentifier = accessibilityIdentifier
        self.menuContent = content()
    }

    package var body: some View {
        Menu {
            menuContent
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(accessibilityIdentifier ?? "app_quick_actions_menu")
    }
}
