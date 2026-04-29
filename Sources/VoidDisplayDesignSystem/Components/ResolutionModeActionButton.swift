import Foundation
import VoidDisplayFoundation
import SwiftUI
package struct ResolutionModeActionButton: View {
    package let title: LocalizedStringKey
    package let systemImage: String
    package let tint: Color
    package let action: () -> Void
    package let accessibilityIdentifier: String?

    package init(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    package var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(tint)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .optionalAccessibilityIdentifier(accessibilityIdentifier)
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
