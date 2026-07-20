import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayItemCopyShareAddressLabel: View {
    package let isShowingConfirmation: Bool

    package init(isShowingConfirmation: Bool) {
        self.isShowingConfirmation = isShowingConfirmation
    }

    package var body: some View {
        ZStack {
            Label {
                Text("Copy Access Link")
            } icon: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .frame(width: AppUI.Spacing.large, height: AppUI.Spacing.large)
            }
            .opacity(isShowingConfirmation ? 0 : 1)

            Label {
                Text("Copied")
            } icon: {
                Image(systemName: "checkmark")
                    .font(.callout)
                    .frame(width: AppUI.Spacing.large, height: AppUI.Spacing.large)
            }
            .opacity(isShowingConfirmation ? 1 : 0)
        }
    }
}
