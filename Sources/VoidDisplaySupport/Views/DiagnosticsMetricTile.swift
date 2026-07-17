import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsMetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(spacing: AppUI.Spacing.small) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(AppUI.Spacing.medium)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous))
    }
}
