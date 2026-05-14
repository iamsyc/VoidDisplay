import Foundation
import AppKit
import Observation
package enum AppSidebarItem: Hashable {
    case screen
    case diagnostics
}

@MainActor
@Observable
package final class AppNavigationController {
    package var sidebarSelection: AppSidebarItem? = .screen

    package func showDiagnostics() {
        sidebarSelection = .diagnostics
        NSApp.activate(ignoringOtherApps: true)
    }
}
