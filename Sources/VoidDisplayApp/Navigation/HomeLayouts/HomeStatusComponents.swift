import SwiftUI
import VoidDisplayDesignSystem

package struct HomeStatusBadge: View {
    package let title: String
    package let tone: DisplaySurfaceStatusTone

    package init(title: String, tone: DisplaySurfaceStatusTone) {
        self.title = title
        self.tone = tone
    }

    package var body: some View {
        let tint = tone.tintColor
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
            item.tone.tintColor
        }
    }

    private var valueForegroundColor: Color {
        if item.id == "viewerCount" {
            .primary
        } else {
            switch item.tone {
            case .neutral:
                Color.secondary.opacity(0.72)
            default:
                item.tone.tintColor
            }
        }
    }

    private var valueFontWeight: Font.Weight {
        item.tone == .neutral ? .regular : .semibold
    }
}

package extension DisplaySurfaceStatusTone {
    var tintColor: Color {
        switch self {
        case .neutral:
            AppThemeStatusPalette.standard.neutral
        case .info:
            AppThemeStatusPalette.standard.info
        case .success:
            AppThemeStatusPalette.standard.success
        case .warning:
            AppThemeStatusPalette.standard.warning
        case .danger:
            AppThemeStatusPalette.standard.danger
        }
    }
}
