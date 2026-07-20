import SwiftUI
import VoidDisplayDesignSystem

package struct HomeSharingPortApplyButton: View {
    package let isVisible: Bool
    package let action: @MainActor () -> Void

    package init(
        isVisible: Bool,
        action: @escaping @MainActor () -> Void
    ) {
        self.isVisible = isVisible
        self.action = action
    }

    package var body: some View {
        Button("Apply", systemImage: "checkmark", action: action)
            .labelStyle(.iconOnly)
            .appActionButtonStyle(variant: .default)
            .controlSize(.small)
            .frame(width: 30)
            .opacity(isVisible ? 1 : 0)
            .disabled(!isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .help(Text("Apply"))
            .accessibilityIdentifier("home_sharing_port_apply_button")
    }
}
