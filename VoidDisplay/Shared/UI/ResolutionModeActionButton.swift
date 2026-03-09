import SwiftUI

struct ResolutionModeActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let action: () -> Void
    let accessibilityIdentifier: String?

    init(
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

    var body: some View {
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
