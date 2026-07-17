import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsReadableRow: View {
    let title: String
    let value: String
    let detail: String?
    let isMonospaced: Bool
    let accessibilityIdentifier: String?

    init(
        title: String,
        value: String,
        detail: String? = nil,
        isMonospaced: Bool = false,
        accessibilityIdentifier: String? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.isMonospaced = isMonospaced
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Spacing.medium) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: AppUI.Spacing.medium)
                Text(value)
                    .font(isMonospaced ? .footnote.monospaced() : .footnote)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
            }

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
