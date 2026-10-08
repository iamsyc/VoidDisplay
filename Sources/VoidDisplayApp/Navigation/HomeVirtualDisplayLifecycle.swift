import AppKit
import SwiftUI
import VoidDisplayVirtualDisplay

@MainActor
struct HomeVirtualDisplayLifecycle: ViewModifier {
    let controller: HomeVirtualDisplaySurfaceController
    let virtualDisplay: VirtualDisplayController

    func body(content: Content) -> some View {
        content
            .onAppear(perform: controller.handleAppear)
            .onDisappear(perform: controller.handleDisappear)
            .onChange(of: virtualDisplay.restoreFailures) { _, failures in
                controller.handleRestoreFailuresChanged(failures)
            }
            .onChange(of: controller.isCatalogLoading) { _, isLoading in
                controller.handleCatalogLoadingChanged(isLoading)
            }
            .onChange(of: controller.isWebServiceRunning) { _, isRunning in
                controller.handleSharingServiceStateChanged(isRunning: isRunning)
            }
            .onChange(of: controller.preferredSharingPort) { oldValue, newValue in
                controller.handlePreferredSharingPortChanged(from: oldValue, to: newValue)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            ) { _ in
                controller.handleCatalogTopologyChanged()
            }
    }
}
