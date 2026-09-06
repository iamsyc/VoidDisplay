import SwiftUI

struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let navigation: AppNavigationController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open VoidDisplay") {
                openWindow(id: AppWindowID.main)
                navigation.showHome()
            }
            .keyboardShortcut("n")
        }
    }
}
