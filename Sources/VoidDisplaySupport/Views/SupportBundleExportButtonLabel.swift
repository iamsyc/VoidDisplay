import SwiftUI

package struct SupportBundleExportButtonLabel: View {
    package let isExporting: Bool

    package init(isExporting: Bool) {
        self.isExporting = isExporting
    }

    package var body: some View {
        Label {
            Text("Export Support Bundle")
        } icon: {
            Group {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        }
    }
}
