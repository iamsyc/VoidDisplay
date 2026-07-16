import SwiftUI

package struct AppThemeSurfacePalette {
    package let panelFill: Color
    package let panelStroke: Color
    package let cardFill: Color
    package let cardStroke: Color
    package let cardHoverStroke: Color
    package let tileFill: Color
    package let tileStroke: Color
    package let sidebarSelectionFill: Color
    package let sidebarSelectionStroke: Color
    package let fallbackBarFill: Color

    package static func resolve(colorScheme: ColorScheme) -> AppThemeSurfacePalette {
        switch colorScheme {
        case .dark:
            AppThemeSurfacePalette(
                panelFill: .white.opacity(0.06),
                panelStroke: .white.opacity(0.16),
                cardFill: .white.opacity(0.06),
                cardStroke: .white.opacity(0.14),
                cardHoverStroke: Color.accentColor.opacity(0.55),
                tileFill: .white.opacity(0.08),
                tileStroke: .white.opacity(0.14),
                sidebarSelectionFill: .white.opacity(0.10),
                sidebarSelectionStroke: .white.opacity(0.18),
                fallbackBarFill: .white.opacity(0.08)
            )
        default:
            AppThemeSurfacePalette(
                panelFill: .white,
                panelStroke: .black.opacity(0.08),
                cardFill: Color(nsColor: .controlBackgroundColor).opacity(0.90),
                cardStroke: .black.opacity(0.08),
                cardHoverStroke: Color.accentColor.opacity(0.40),
                tileFill: .black.opacity(0.03),
                tileStroke: .black.opacity(0.12),
                sidebarSelectionFill: .white.opacity(0.28),
                sidebarSelectionStroke: .black.opacity(0.08),
                fallbackBarFill: .white.opacity(0.90)
            )
        }
    }
}

package struct AppThemeStatusPalette {
    package let neutral: Color
    package let info: Color
    package let success: Color
    package let warning: Color
    package let danger: Color

    package static let standard = AppThemeStatusPalette(
        neutral: .gray,
        info: .blue,
        success: .green,
        warning: .orange,
        danger: .red
    )
}
