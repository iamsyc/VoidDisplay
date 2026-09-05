import SwiftUI
import VoidDisplayDesignSystem

package struct MenuBarQuickActionLabel: View {
    package let title: String
    package let systemImage: String
    package let isWorking: Bool

    package init(title: String, systemImage: String, isWorking: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.isWorking = isWorking
    }

    package var body: some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            ZStack {
                Image(systemName: systemImage)
                    .opacity(isWorking ? 0 : 1)

                ProgressView()
                    .controlSize(.small)
                    .opacity(isWorking ? 1 : 0)
            }
            .frame(width: AppUI.Spacing.large, height: AppUI.Spacing.large)

            Text(title)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
