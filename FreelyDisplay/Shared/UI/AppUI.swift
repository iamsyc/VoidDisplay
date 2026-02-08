import SwiftUI

enum AppUI {
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
        static let rowMinHeight: CGFloat = 62
        static let iconBoxWidth: CGFloat = 36
        static let iconBoxHeight: CGFloat = 30
        static let rowHorizontalInset: CGFloat = 12
        static let rowVerticalInset: CGFloat = 8
        static let listHorizontalInset: CGFloat = 12
        static let listVerticalInset: CGFloat = 6
        static let hoverLift: CGFloat = 1
    }

    enum Surface {
        static func panelFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.06) : .white.opacity(0.94)
        }

        static func panelStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.10)
        }

        static func interactivePanelStroke(for colorScheme: ColorScheme, isHovered: Bool) -> Color {
            guard isHovered else {
                return panelStroke(for: colorScheme)
            }
            if colorScheme == .dark {
                return Color.accentColor.opacity(0.55)
            }
            return Color.accentColor.opacity(0.40)
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
                : Color(nsColor: .windowBackgroundColor) // Was .underPageBackgroundColor, changed for better contrast
        }
    }
}

struct AppPanel: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .fill(AppUI.Surface.panelFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .stroke(AppUI.Surface.panelStroke(for: colorScheme), lineWidth: AppUI.Stroke.subtle)
            )
            .shadow(
                color: colorScheme == .dark ? .clear : .black.opacity(0.06),
                radius: colorScheme == .dark ? 0 : 6,
                x: 0,
                y: 2
            )
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
            .background(AppUI.Surface.screenBackground(for: colorScheme))
    }
}

struct AppInteractiveCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .fill(AppUI.Surface.panelFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .stroke(
                        AppUI.Surface.interactivePanelStroke(for: colorScheme, isHovered: isHovered),
                        lineWidth: AppUI.Stroke.subtle
                    )
            )
            .shadow(
                color: colorScheme == .dark
                    ? .clear
                    : .black.opacity(isHovered ? 0.12 : 0.08), // Increased opacity for better depth
                radius: colorScheme == .dark ? 0 : (isHovered ? 8 : 6), // Increased radius
                x: 0,
                y: colorScheme == .dark ? 0 : (isHovered ? 3 : 2) // Increased Y offset
            )
    }
}

extension View {
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
    }

    let title: String
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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

    private var badgePresentation: (foreground: Color, background: Color, stroke: Color) {
        switch style {
        case .neutral:
            if colorScheme == .dark {
                return (.white.opacity(0.92), .white.opacity(0.14), .white.opacity(0.20))
            }
            return (.black.opacity(0.70), .black.opacity(0.06), .black.opacity(0.12))
        case .accent(let tint):
            return (tint, tint.opacity(colorScheme == .dark ? 0.24 : 0.16), tint.opacity(colorScheme == .dark ? 0.32 : 0.28))
        }
    }
}
