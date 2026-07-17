import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AppUI.Spacing.small - 1)
            .padding(.vertical, AppUI.Spacing.xSmall)
            .background(.quaternary.opacity(0.45), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
