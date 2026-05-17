import Foundation
import AppKit
import Observation
package enum AppSidebarItem: Hashable {
    case home
    case diagnostics
}

@MainActor
@Observable
package final class AppNavigationController {
    package var sidebarSelection: AppSidebarItem? = .home

    package func showDiagnostics() {
        sidebarSelection = .diagnostics
        NSApp.activate(ignoringOtherApps: true)
    }
}
