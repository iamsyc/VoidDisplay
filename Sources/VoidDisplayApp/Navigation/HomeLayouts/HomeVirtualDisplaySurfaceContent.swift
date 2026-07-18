import SwiftUI
import VoidDisplayVirtualDisplay

package struct HomeVirtualDisplaySurfaceContent: View {
    package let context: HomeLayoutContext
    package let configStorePresentation: VirtualDisplayConfigStorePresentation
    @Binding package var isConfigStoreDetailsExpanded: Bool
    package let resetConfigStore: @MainActor () -> Void

    package init(
        context: HomeLayoutContext,
        configStorePresentation: VirtualDisplayConfigStorePresentation,
        isConfigStoreDetailsExpanded: Binding<Bool>,
        resetConfigStore: @escaping @MainActor () -> Void
    ) {
        self.context = context
        self.configStorePresentation = configStorePresentation
        _isConfigStoreDetailsExpanded = isConfigStoreDetailsExpanded
        self.resetConfigStore = resetConfigStore
    }

    package var body: some View {
        HomeLayoutShell(context: context) {
            if configStorePresentation.hasLoadFailure {
                HomeVirtualDisplayConfigStoreErrorPanel(
                    presentation: configStorePresentation,
                    isDetailsExpanded: $isConfigStoreDetailsExpanded,
                    resetConfigStore: resetConfigStore
                )
            } else if context.itemStates.isEmpty {
                ContentUnavailableView(
                    "No Virtual Display",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Add a virtual display to start previewing or sharing it from Home.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
                .accessibilityIdentifier("virtual_displays_empty_state")
            } else {
                HomeListRows(context: context)
            }
        }
    }
}
