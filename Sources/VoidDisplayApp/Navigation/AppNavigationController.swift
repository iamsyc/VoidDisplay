import Foundation
import AppKit
import Observation
package enum AppSidebarItem: Hashable {
    case screen
    case virtualDisplay
    case monitorScreen
    case screenSharing
    case supportCenter
}

@MainActor
@Observable
package final class AppNavigationController {
    package var sidebarSelection: AppSidebarItem? = .screen

    package func showSupportCenter() {
        sidebarSelection = .supportCenter
        NSApp.activate(ignoringOtherApps: true)
    }
}
