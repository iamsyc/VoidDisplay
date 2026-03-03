import SwiftUI

enum AppUI {
    enum GlassRole {
        case sidebar
        case panel
        case interactiveCard
        case toolbar
        case status
    }

    struct GlassTokens {
        let material: Material
        let strokeOpacityDark: Double
        let strokeOpacityLight: Double
        let highlightOpacityDark: Double
        let highlightOpacityLight: Double
        let shadowOpacityDark: Double
        let shadowOpacityLight: Double
        let shadowRadius: CGFloat
        let shadowYOffset: CGFloat
        let cornerRadius: CGFloat
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Corner {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 18
    }

    enum Stroke {
        static let subtle: CGFloat = 1
    }

    enum List {
        static let rowMinHeight: CGFloat = 56
        static let iconBoxWidth: CGFloat = 42 // Increased from 36
        static let iconBoxHeight: CGFloat = 42 // Increased from 30
        static let rowHorizontalInset: CGFloat = 12
        static let rowVerticalInset: CGFloat = 6
        static let listHorizontalInset: CGFloat = 12
        static let listVerticalInset: CGFloat = 3
        static let hoverLift: CGFloat = 1
    }

    enum Surface {
        static func panelFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.06) : .white.opacity(0.94)
        }

        static func panelStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
        }

        static func tileFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.03)
        }

        static func tileStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
        }

        static func screenBackground(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color(nsColor: .windowBackgroundColor)
                : Color(nsColor: .windowBackgroundColor)
        }

        static func screenBackgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
            if colorScheme == .dark {
                return LinearGradient(
                    colors: [
                        .white.opacity(0.06),
                        .white.opacity(0.02),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [
                    .white.opacity(0.24),
                    .white.opacity(0.10),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        static func glassTokens(for role: GlassRole) -> GlassTokens {
            switch role {
            case .sidebar:
                return GlassTokens(
                    material: .thinMaterial,
                    strokeOpacityDark: 0.10,
                    strokeOpacityLight: 0.08,
                    highlightOpacityDark: 0.02,
                    highlightOpacityLight: 0.04,
                    shadowOpacityDark: 0.00,
                    shadowOpacityLight: 0.00,
                    shadowRadius: 0,
                    shadowYOffset: 0,
                    cornerRadius: 0
                )
            case .panel:
                return GlassTokens(
                    material: .thickMaterial,
                    strokeOpacityDark: 0.22,
                    strokeOpacityLight: 0.12,
                    highlightOpacityDark: 0.04,
                    highlightOpacityLight: 0.08,
                    shadowOpacityDark: 0.00,
                    shadowOpacityLight: 0.07,
                    shadowRadius: 8,
                    shadowYOffset: 3,
                    cornerRadius: AppUI.Corner.medium
                )
            case .interactiveCard:
                return GlassTokens(
                    material: .regularMaterial,
                    strokeOpacityDark: 0.18,
                    strokeOpacityLight: 0.10,
                    highlightOpacityDark: 0.04,
                    highlightOpacityLight: 0.06,
                    shadowOpacityDark: 0.00,
                    shadowOpacityLight: 0.05,
                    shadowRadius: 6,
                    shadowYOffset: 2,
                    cornerRadius: AppUI.Corner.medium
                )
            case .toolbar:
                return GlassTokens(
                    material: .ultraThinMaterial,
                    strokeOpacityDark: 0.14,
                    strokeOpacityLight: 0.08,
                    highlightOpacityDark: 0.02,
                    highlightOpacityLight: 0.03,
                    shadowOpacityDark: 0.00,
                    shadowOpacityLight: 0.00,
                    shadowRadius: 0,
                    shadowYOffset: 0,
                    cornerRadius: 0
                )
            case .status:
                return GlassTokens(
                    material: .thinMaterial,
                    strokeOpacityDark: 0.20,
                    strokeOpacityLight: 0.10,
                    highlightOpacityDark: 0.03,
                    highlightOpacityLight: 0.06,
                    shadowOpacityDark: 0.00,
                    shadowOpacityLight: 0.05,
                    shadowRadius: 5,
                    shadowYOffset: 2,
                    cornerRadius: AppUI.Corner.medium
                )
            }
        }

        static func glassCornerRadius(for role: GlassRole) -> CGFloat {
            glassTokens(for: role).cornerRadius
        }

        static func glassFallbackFill(for role: GlassRole, colorScheme: ColorScheme) -> Color {
            switch role {
            case .panel:
                return panelFill(for: colorScheme)
            case .interactiveCard:
                return colorScheme == .dark
                    ? .white.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.90)
            case .toolbar:
                return colorScheme == .dark ? .white.opacity(0.07) : .white.opacity(0.92)
            case .status:
                return colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.04)
            case .sidebar:
                return colorScheme == .dark
                    ? .white.opacity(0.04)
                    : Color(nsColor: .windowBackgroundColor).opacity(0.96)
            }
        }

        static func glassStroke(for role: GlassRole, colorScheme: ColorScheme) -> Color {
            let tokens = glassTokens(for: role)
            let strokeOpacity = colorScheme == .dark ? tokens.strokeOpacityDark : tokens.strokeOpacityLight
            return (colorScheme == .dark ? Color.white : Color.black).opacity(strokeOpacity)
        }

        static func glassFallbackStroke(for role: GlassRole, colorScheme: ColorScheme) -> Color {
            switch role {
            case .panel:
                return panelStroke(for: colorScheme)
            case .interactiveCard:
                return colorScheme == .dark ? .white.opacity(0.20) : .black.opacity(0.10)
            case .toolbar, .status, .sidebar:
                return glassStroke(for: role, colorScheme: colorScheme)
            }
        }

        static func glassHighlightTint(for role: GlassRole, colorScheme: ColorScheme) -> Color {
            let tokens = glassTokens(for: role)
            let opacity = colorScheme == .dark ? tokens.highlightOpacityDark : tokens.highlightOpacityLight
            return .white.opacity(opacity)
        }

        static func glassShadow(
            for role: GlassRole,
            colorScheme: ColorScheme,
            reduceTransparency: Bool
        ) -> (color: Color, radius: CGFloat, y: CGFloat) {
            let tokens = glassTokens(for: role)
            let opacity = colorScheme == .dark ? tokens.shadowOpacityDark : tokens.shadowOpacityLight
            if reduceTransparency || opacity == 0 {
                return (.clear, 0, 0)
            }
            return (.black.opacity(opacity), tokens.shadowRadius, tokens.shadowYOffset)
        }

        static func sidebarDivider(for colorScheme: ColorScheme, reduceTransparency: Bool) -> Color {
            if reduceTransparency {
                return colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
            }
            return glassStroke(for: .sidebar, colorScheme: colorScheme)
        }

        static func interactivePanelStroke(for colorScheme: ColorScheme, isHovered: Bool) -> Color {
            guard isHovered else {
                return .clear
            }
            if colorScheme == .dark {
                return Color.accentColor.opacity(0.55)
            }
            return Color.accentColor.opacity(0.40)
        }
    }
}

struct AppGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let role: AppUI.GlassRole

    private var cornerRadius: CGFloat {
        AppUI.Surface.glassCornerRadius(for: role)
    }

    private var fillStyle: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(AppUI.Surface.glassFallbackFill(for: role, colorScheme: colorScheme))
        }
        return AnyShapeStyle(AppUI.Surface.glassTokens(for: role).material)
    }

    private var strokeColor: Color {
        if reduceTransparency {
            return AppUI.Surface.glassFallbackStroke(for: role, colorScheme: colorScheme)
        }
        return AppUI.Surface.glassStroke(for: role, colorScheme: colorScheme)
    }

    func body(content: Content) -> some View {
        let shadow = AppUI.Surface.glassShadow(
            for: role,
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency
        )

        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fillStyle)
                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AppUI.Surface.glassHighlightTint(for: role, colorScheme: colorScheme))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: AppUI.Stroke.subtle)
            }
            .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
}

struct AppGlassBar: ViewModifier {
    let role: AppUI.GlassRole

    func body(content: Content) -> some View {
        content
            .modifier(AppGlassSurface(role: role))
    }
}

struct AppGlassSidebarBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    AppUI.Surface.glassFallbackFill(for: .sidebar, colorScheme: colorScheme)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(AppUI.Surface.glassTokens(for: .sidebar).material)
                        Rectangle()
                            .fill(AppUI.Surface.glassHighlightTint(for: .sidebar, colorScheme: colorScheme))
                    }
                }
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(AppUI.Surface.sidebarDivider(for: colorScheme, reduceTransparency: reduceTransparency))
                    .frame(width: AppUI.Stroke.subtle)
            }
    }
}

struct AppPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .appGlassSurface(role: .panel)
    }
}

struct AppTile: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                    .fill(AppUI.Surface.tileFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                    .stroke(AppUI.Surface.tileStroke(for: colorScheme), lineWidth: AppUI.Stroke.subtle)
            )
    }
}

struct AppScreenBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    AppUI.Surface.screenBackground(for: colorScheme)
                    AppUI.Surface.screenBackgroundGradient(for: colorScheme)
                }
            }
    }
}

struct AppInteractiveCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .appGlassSurface(role: .interactiveCard)
            .overlay(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .stroke(
                        AppUI.Surface.interactivePanelStroke(
                            for: colorScheme,
                            isHovered: isHovered
                        ),
                        lineWidth: AppUI.Stroke.subtle
                    )
            )
    }
}

extension View {
    func appGlassSurface(role: AppUI.GlassRole) -> some View {
        modifier(AppGlassSurface(role: role))
    }

    func appGlassBar(role: AppUI.GlassRole) -> some View {
        modifier(AppGlassBar(role: role))
    }

    func appGlassSidebarBackground() -> some View {
        modifier(AppGlassSidebarBackground())
    }

    func appPanelStyle() -> some View {
        modifier(AppPanel())
    }

    func appTileStyle() -> some View {
        modifier(AppTile())
    }

    func appScreenBackground() -> some View {
        modifier(AppScreenBackground())
    }

    func appInteractiveCardStyle(isHovered: Bool) -> some View {
        modifier(AppInteractiveCard(isHovered: isHovered))
    }

    func appListRowStyle() -> some View {
        self
            .listRowInsets(
                EdgeInsets(
                    top: AppUI.List.listVerticalInset,
                    leading: AppUI.List.listHorizontalInset,
                    bottom: AppUI.List.listVerticalInset,
                    trailing: AppUI.List.listHorizontalInset
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct AppStatusBadge: View {
    enum Style {
        case neutral
        case accent(Color)
        case roundedTag(tint: Color)
    }

    let title: String
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch style {
        case .roundedTag(let tint):
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, AppUI.Spacing.small - 1)
                .padding(.vertical, AppUI.Spacing.xSmall - 1)
                .background(tint.opacity(colorScheme == .dark ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: AppUI.Stroke.subtle)
                )
                .foregroundStyle(tint)
        default:
            let presentation = badgePresentation

            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, AppUI.Spacing.small - 1)
                .padding(.vertical, AppUI.Spacing.xSmall - 1)
                .background(presentation.background, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(presentation.stroke, lineWidth: AppUI.Stroke.subtle)
                )
                .foregroundStyle(presentation.foreground)
        }
    }

    private var badgePresentation: (foreground: Color, background: Color, stroke: Color) {
        switch style {
        case .neutral:
            if colorScheme == .dark {
                return (.white.opacity(0.92), .white.opacity(0.14), .white.opacity(0.20))
            }
            return (.black.opacity(0.70), .black.opacity(0.06), .black.opacity(0.12))
        case .accent(let tint):
            return (tint, tint.opacity(colorScheme == .dark ? 0.24 : 0.16), tint.opacity(colorScheme == .dark ? 0.32 : 0.28))
        case .roundedTag(let tint):
            return (tint, tint.opacity(colorScheme == .dark ? 0.24 : 0.16), tint.opacity(colorScheme == .dark ? 0.32 : 0.28))
        }
    }
}

struct AppCornerRibbon: View {
    let model: AppCornerRibbonModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(model.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, AppUI.Spacing.small)
            .padding(.vertical, AppUI.Spacing.xSmall - 1)
            .background(model.tint.opacity(colorScheme == .dark ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(model.tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: AppUI.Stroke.subtle)
            )
            .foregroundStyle(model.tint)
            .accessibilityIdentifier(model.accessibilityIdentifier ?? "app_corner_ribbon")
    }
}

struct AppStatusDotLabel: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
