import SwiftUI
import VoidDisplayDesignSystem

package struct HomeStatusBadge: View {
    package let title: String
    package let tone: DisplaySurfaceStatusTone
    @Environment(\.appSkinID) private var skinID

    package init(title: String, tone: DisplaySurfaceStatusTone) {
        self.title = title
        self.tone = tone
    }

    package var body: some View {
        let tint = tone.tint(skinID: skinID)
        Text(title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, AppUI.Spacing.small - 1)
            .padding(.vertical, AppUI.Spacing.xSmall - 1)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(tint)
    }
}

package struct HomeInlineStatusText: View {
    package let item: DisplaySurfaceStatusItemPresentation
    @Environment(\.appSkinID) private var skinID

    package init(item: DisplaySurfaceStatusItemPresentation) {
        self.item = item
    }

    package var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconForegroundColor)
                .frame(width: 13)

            Text(item.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(item.value)
                .fontWeight(valueFontWeight)
                .foregroundStyle(valueForegroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.title): \(item.value)"))
        .accessibilityIdentifier(item.accessibilityIdentifier)
    }

    private var systemImage: String {
        switch item.id {
        case "preview":
            "dot.scope.display"
        case "webView":
            "network"
        case "viewerCount":
            "person.2"
        case "issue":
            "exclamationmark.triangle"
        default:
            "circle"
        }
    }

    private var iconForegroundColor: Color {
        switch item.tone {
        case .neutral:
            Color.secondary
        default:
            item.tone.tint(skinID: skinID)
        }
    }

    private var valueForegroundColor: Color {
        if item.id == "viewerCount" {
            return .primary
        }
        return switch item.tone {
        case .neutral:
            Color.secondary.opacity(0.72)
        default:
            item.tone.tint(skinID: skinID)
        }
    }

    private var valueFontWeight: Font.Weight {
        item.tone == .neutral ? .regular : .semibold
    }
}

package extension DisplaySurfaceStatusTone {
    func tint(skinID: AppSkinID) -> Color {
        let palette = AppThemeStatusPalette.resolve(skinID: skinID)
        return switch self {
        case .neutral:
            palette.neutral
        case .info:
            palette.info
        case .success:
            palette.success
        case .warning:
            palette.warning
        case .danger:
            palette.danger
        }
    }
}
