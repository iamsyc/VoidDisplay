import SwiftUI

struct AppQuickActionsMenu<MenuContent: View>: View {
    let label: String
    var accessibilityIdentifier: String?
    private let menuContent: MenuContent

    init(
        _ label: String = String(localized: "Quick Actions"),
        accessibilityIdentifier: String? = nil,
        @ViewBuilder content: () -> MenuContent
    ) {
        self.label = label
        self.accessibilityIdentifier = accessibilityIdentifier
        self.menuContent = content()
    }

    var body: some View {
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
