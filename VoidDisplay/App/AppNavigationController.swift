import AppKit
import Observation

enum AppSidebarItem: Hashable {
    case screen
    case virtualDisplay
    case monitorScreen
    case screenSharing
    case supportCenter
}

@MainActor
@Observable
final class AppNavigationController {
    var sidebarSelection: AppSidebarItem? = .screen

    func showSupportCenter() {
        sidebarSelection = .supportCenter
        NSApp.activate(ignoringOtherApps: true)
    }
}
