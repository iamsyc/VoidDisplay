import SwiftUI

struct DiagnosticsEvidenceField: View {
    let title: String
    let value: String
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
