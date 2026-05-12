import VoidDisplayRuntime
import Foundation

package typealias ScreenCatalogSource = DisplayRuntimeCatalogSource

@MainActor
package final class ScreenCatalogOrchestrator {
    private let runtime: DisplayRuntime
    private let openPrivacySettings: (@escaping (URL) -> Void) -> Void

    package init(
        runtime: DisplayRuntime,
        openScreenCapturePrivacySettings: @escaping (@escaping (URL) -> Void) -> Void
    ) {
        self.runtime = runtime
        self.openPrivacySettings = openScreenCapturePrivacySettings
    }

    package func handleAppear(source: ScreenCatalogSource) async {
        await runtime.handleCatalogAppear(source: source)
    }

    package func handleDisappear(source: ScreenCatalogSource) async {
        await runtime.handleCatalogDisappear(source: source)
    }

    package func requestPermission(source: ScreenCatalogSource) async {
        await runtime.requestCatalogPermission(source: source)
    }

    package func refreshPermission(source: ScreenCatalogSource) async {
        await runtime.refreshCatalogPermission(source: source)
    }

    package func forceRefresh(source: ScreenCatalogSource) async {
        await runtime.forceRefreshCatalog(source: source)
    }

    package func handleTopologyChanged() async {
        await runtime.handleCatalogTopologyChanged()
    }

    package func handleSharingServiceStateChanged(isRunning: Bool) async {
        await runtime.handleSharingServiceStateChanged(isRunning: isRunning)
    }

    package func openScreenCapturePrivacySettings(openURL: @escaping (URL) -> Void) {
        openPrivacySettings(openURL)
    }
}
