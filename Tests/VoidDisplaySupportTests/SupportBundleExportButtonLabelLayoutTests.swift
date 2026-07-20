@testable import VoidDisplaySupport
import SwiftUI
import Testing

@MainActor
struct SupportBundleExportButtonLabelLayoutTests {
    @Test func exportingStateKeepsButtonWidthStable() {
        let idleWidth = fittingWidth(isExporting: false)
        let exportingWidth = fittingWidth(isExporting: true)

        #expect(abs(idleWidth - exportingWidth) < 0.1)
    }

    private func fittingWidth(isExporting: Bool) -> CGFloat {
        let view = SupportBundleExportButtonLabel(isExporting: isExporting)
        let hostingView = NSHostingView(rootView: view)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.width
    }
}
