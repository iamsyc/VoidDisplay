import Foundation
import SwiftUI

package enum AppSkinID: String, CaseIterable, Identifiable, Sendable {
    case classic
    case compact
    case dashboard

    package var id: String { rawValue }
}

package struct AppTheme {
    package let skinID: AppSkinID
    package let surface: AppThemeSurfacePalette
    package let status: AppThemeStatusPalette
    package let density: AppThemeDensity

    package static func resolve(
        skinID: AppSkinID,
        colorScheme: ColorScheme
    ) -> AppTheme {
        AppTheme(
            skinID: skinID,
            surface: AppThemeSurfacePalette.resolve(skinID: skinID, colorScheme: colorScheme),
            status: AppThemeStatusPalette.resolve(skinID: skinID),
            density: AppThemeDensity.resolve(skinID: skinID)
        )
    }
}

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

    package static func resolve(
        skinID: AppSkinID,
        colorScheme: ColorScheme
    ) -> AppThemeSurfacePalette {
        switch (skinID, colorScheme) {
        case (.classic, .dark):
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
        case (.classic, _):
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
        case (.compact, .dark):
            AppThemeSurfacePalette(
                panelFill: .white.opacity(0.05),
                panelStroke: .white.opacity(0.13),
                cardFill: .white.opacity(0.045),
                cardStroke: .white.opacity(0.11),
                cardHoverStroke: Color.accentColor.opacity(0.48),
                tileFill: .white.opacity(0.07),
                tileStroke: .white.opacity(0.12),
                sidebarSelectionFill: .white.opacity(0.08),
                sidebarSelectionStroke: .white.opacity(0.16),
                fallbackBarFill: .white.opacity(0.07)
            )
        case (.compact, _):
            AppThemeSurfacePalette(
                panelFill: Color(nsColor: .controlBackgroundColor).opacity(0.82),
                panelStroke: .black.opacity(0.07),
                cardFill: Color(nsColor: .controlBackgroundColor).opacity(0.74),
                cardStroke: .black.opacity(0.075),
                cardHoverStroke: Color.accentColor.opacity(0.34),
                tileFill: .black.opacity(0.025),
                tileStroke: .black.opacity(0.10),
                sidebarSelectionFill: .white.opacity(0.24),
                sidebarSelectionStroke: .black.opacity(0.07),
                fallbackBarFill: .white.opacity(0.86)
            )
        case (.dashboard, .dark):
            AppThemeSurfacePalette(
                panelFill: .white.opacity(0.07),
                panelStroke: .white.opacity(0.17),
                cardFill: .white.opacity(0.065),
                cardStroke: .white.opacity(0.15),
                cardHoverStroke: Color.accentColor.opacity(0.58),
                tileFill: .white.opacity(0.09),
                tileStroke: .white.opacity(0.15),
                sidebarSelectionFill: .white.opacity(0.11),
                sidebarSelectionStroke: .white.opacity(0.19),
                fallbackBarFill: .white.opacity(0.09)
            )
        case (.dashboard, _):
            AppThemeSurfacePalette(
                panelFill: .white.opacity(0.96),
                panelStroke: .black.opacity(0.09),
                cardFill: Color(nsColor: .controlBackgroundColor).opacity(0.94),
                cardStroke: .black.opacity(0.09),
                cardHoverStroke: Color.accentColor.opacity(0.44),
                tileFill: .black.opacity(0.035),
                tileStroke: .black.opacity(0.13),
                sidebarSelectionFill: .white.opacity(0.30),
                sidebarSelectionStroke: .black.opacity(0.09),
                fallbackBarFill: .white.opacity(0.92)
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

    package static func resolve(skinID: AppSkinID) -> AppThemeStatusPalette {
        switch skinID {
        case .classic:
            AppThemeStatusPalette(
                neutral: .gray,
                info: .blue,
                success: .green,
                warning: .orange,
                danger: .red
            )
        case .compact:
            AppThemeStatusPalette(
                neutral: .gray,
                info: Color(red: 0.20, green: 0.46, blue: 0.84),
                success: Color(red: 0.12, green: 0.55, blue: 0.32),
                warning: Color(red: 0.86, green: 0.48, blue: 0.10),
                danger: Color(red: 0.82, green: 0.18, blue: 0.18)
            )
        case .dashboard:
            AppThemeStatusPalette(
                neutral: .gray,
                info: Color(red: 0.10, green: 0.44, blue: 0.90),
                success: Color(red: 0.05, green: 0.58, blue: 0.36),
                warning: Color(red: 0.92, green: 0.52, blue: 0.08),
                danger: Color(red: 0.86, green: 0.16, blue: 0.16)
            )
        }
    }
}

package struct AppThemeDensity: Equatable {
    package let cardHorizontalPadding: CGFloat
    package let cardVerticalPadding: CGFloat
    package let cardCornerRadius: CGFloat
    package let cardSpacing: CGFloat
    package let contentMaxWidth: CGFloat

    package static func resolve(skinID: AppSkinID) -> AppThemeDensity {
        switch skinID {
        case .classic:
            AppThemeDensity(
                cardHorizontalPadding: AppUI.Spacing.large,
                cardVerticalPadding: AppUI.Spacing.medium,
                cardCornerRadius: 8,
                cardSpacing: AppUI.Spacing.small + 2,
                contentMaxWidth: 1240
            )
        case .compact:
            AppThemeDensity(
                cardHorizontalPadding: AppUI.Spacing.medium,
                cardVerticalPadding: AppUI.Spacing.small,
                cardCornerRadius: 7,
                cardSpacing: 6,
                contentMaxWidth: 1320
            )
        case .dashboard:
            AppThemeDensity(
                cardHorizontalPadding: AppUI.Spacing.large,
                cardVerticalPadding: AppUI.Spacing.medium,
                cardCornerRadius: 10,
                cardSpacing: AppUI.Spacing.medium,
                contentMaxWidth: 1280
            )
        }
    }
}

private struct AppSkinIDEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppSkinID = .classic
}

package extension EnvironmentValues {
    var appSkinID: AppSkinID {
        get { self[AppSkinIDEnvironmentKey.self] }
        set { self[AppSkinIDEnvironmentKey.self] = newValue }
    }
}

package extension View {
    func appSkin(_ skinID: AppSkinID) -> some View {
        environment(\.appSkinID, skinID)
    }
}
