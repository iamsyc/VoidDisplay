import Foundation
import VoidDisplayFoundation
import SwiftUI

// MARK: - Action button variant
package enum AppActionVariant {
    case `default`
    case primary
    case danger
}

// MARK: - Design tokens
package enum AppUI {
    package enum Spacing {
        package static let xSmall: CGFloat = 4
        package static let small: CGFloat = 8
        package static let medium: CGFloat = 12
        package static let large: CGFloat = 16
    }
    package enum Corner {
        package static let small: CGFloat = 10
        package static let medium: CGFloat = 14
        package static let large: CGFloat = 18
    }
    package enum Stroke {
        package static let subtle: CGFloat = 1
    }
    package enum List {
        package static let rowMinHeight: CGFloat = 56
        package static let iconBoxWidth: CGFloat = 42
        package static let iconBoxHeight: CGFloat = 42
        package static let rowHorizontalInset: CGFloat = 12
        package static let rowVerticalInset: CGFloat = 6
        package static let contentInsetTop: CGFloat = 3
        package static let contentInsetLeading: CGFloat = 20
        package static let contentInsetTrailing: CGFloat = 20
        package static let contentInsetBottom: CGFloat = 3
        package static let sectionSpacing: CGFloat = 8
        package static let listHorizontalInset: CGFloat = 12
        package static let listVerticalInset: CGFloat = 3
    }
    package enum DebugLayout {
        package static let showBorders: Bool = false
        package static let borderColor: Color = .red
        package static let borderWidth: CGFloat = 1
    }

    // MARK: - Surface helpers
    package enum Surface {
        // -- Panel (standalone container: empty-state, start-service panel)
        package static func panelFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.06) : .white
        }

        package static func panelStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.08)
        }

        // -- Interactive card (list row cards)
        package static func cardFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? .white.opacity(0.06)
                : Color(nsColor: .controlBackgroundColor).opacity(0.90)
        }

        package static func cardStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
        }

        package static func cardHoverStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.accentColor.opacity(0.55)
                : Color.accentColor.opacity(0.40)
        }

        // -- Tile (icon boxes inside cards)
        package static func tileFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.03)
        }

        package static func tileStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
        }

        // -- Sidebar selection pill
        package static func sidebarSelectionFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.28)
        }

        package static func sidebarSelectionStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.08)
        }

        // -- Reduce-transparency fallbacks
        package static func fallbackBarFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.90)
        }

    }
}

// MARK: ─── View Modifiers ───

/// Standalone panel: solid fill + border + shadow.
package struct AppPanel: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    package func body(content: Content) -> some View {
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
                color: colorScheme == .dark ? .clear : .black.opacity(0.08),
                radius: colorScheme == .dark ? 0 : 8,
                x: 0,
                y: 2
            )
    }
}

/// Tile: small icon container inside cards — subtle fill, no border.
package struct AppTile: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    package func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                    .fill(AppUI.Surface.tileFill(for: colorScheme))
            )
    }
}

/// Interactive card: solid fill with always-visible border + hover accent stroke.
package struct AppInteractiveCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    package let isHovered: Bool

    package func body(content: Content) -> some View {
        let strokeColor = isHovered
            ? AppUI.Surface.cardHoverStroke(for: colorScheme)
            : AppUI.Surface.cardStroke(for: colorScheme)

        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .fill(AppUI.Surface.cardFill(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                    .stroke(strokeColor, lineWidth: AppUI.Stroke.subtle)
            )
    }
}

/// Bottom action bar: native `.ultraThinMaterial` with reduce-transparency fallback.
package struct AppMaterialBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    package func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppUI.Surface.fallbackBarFill(for: colorScheme))
        } else {
            content
                .background(.ultraThinMaterial)
        }
    }
}

/// Sidebar selection pill: translucent highlight + fine border + soft shadow.
package struct AppSidebarSelectionPill: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    package let isSelected: Bool

    package func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppUI.Spacing.small - 1)
            .padding(.vertical, AppUI.Spacing.xSmall + 2)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                        .fill(AppUI.Surface.sidebarSelectionFill(for: colorScheme))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                                .stroke(
                                    AppUI.Surface.sidebarSelectionStroke(for: colorScheme),
                                    lineWidth: AppUI.Stroke.subtle
                                )
                        }
                        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
                }
            }
    }
}

/// Action button using native SwiftUI styles.
package struct AppActionButton: ViewModifier {
    package let variant: AppActionVariant

    package func body(content: Content) -> some View {
        switch variant {
        case .primary:
            content.buttonStyle(.borderedProminent)
        case .danger:
            content.buttonStyle(.borderedProminent).tint(.red)
        case .default:
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: ─── View Extensions ───

package extension View {
    func appPanelStyle() -> some View {
        modifier(AppPanel())
    }

    func appTileStyle() -> some View {
        modifier(AppTile())
    }

    func appInteractiveCardStyle(isHovered: Bool) -> some View {
        modifier(AppInteractiveCard(isHovered: isHovered))
    }

    func appListContentInsets(top: Bool = true, bottom: Bool = true) -> some View {
        self
            .padding(.leading, AppUI.List.contentInsetLeading)
            .padding(.trailing, AppUI.List.contentInsetTrailing)
            .padding(.top, top ? AppUI.List.contentInsetTop : 0)
            .padding(.bottom, bottom ? AppUI.List.contentInsetBottom : 0)
            .appDebugLayoutBorder()
    }

    @ViewBuilder
    func appDebugLayoutBorder() -> some View {
        if AppUI.DebugLayout.showBorders {
            self.overlay {
                Rectangle()
                    .stroke(
                        AppUI.DebugLayout.borderColor,
                        lineWidth: AppUI.DebugLayout.borderWidth
                    )
            }
        } else {
            self
        }
    }

    func appListRowStyle() -> some View {
        self
            .listRowInsets(
                EdgeInsets(
                    top: AppUI.List.listVerticalInset,
                    leading: AppUI.List.contentInsetLeading,
                    bottom: AppUI.List.listVerticalInset,
                    trailing: AppUI.List.contentInsetTrailing
                )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func appSidebarSelectionPill(isSelected: Bool) -> some View {
        modifier(AppSidebarSelectionPill(isSelected: isSelected))
    }

    func appActionButtonStyle(variant: AppActionVariant = .default) -> some View {
        modifier(AppActionButton(variant: variant))
    }

    func appMaterialBarStyle() -> some View {
        modifier(AppMaterialBar())
    }
}

// MARK: ─── Shared Components ───
package struct AppStatusBadge: View {
    package enum Style {
        case neutral
        case accent(Color)
        case roundedTag(tint: Color)
    }

    package let title: String
    package let style: Style
    @Environment(\.colorScheme) private var colorScheme

    package var body: some View {
        switch style {
        case .roundedTag(let tint):
            Text(title)
                .font(.caption)
                .bold()
                .padding(.horizontal, AppUI.Spacing.small - 1)
                .padding(.vertical, AppUI.Spacing.xSmall)
                .background(tint.opacity(colorScheme == .dark ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: AppUI.Stroke.subtle)
                )
                .foregroundStyle(tint)
        default:
            let p = badgePresentation
            Text(title)
                .font(.caption)
                .bold()
                .padding(.horizontal, AppUI.Spacing.small - 1)
                .padding(.vertical, AppUI.Spacing.xSmall)
                .background(p.background, in: Capsule())
                .overlay(Capsule().stroke(p.stroke, lineWidth: AppUI.Stroke.subtle))
                .foregroundStyle(p.foreground)
        }
    }

    private var badgePresentation: (foreground: Color, background: Color, stroke: Color) {
        switch style {
        case .neutral:
            return colorScheme == .dark
                ? (.white.opacity(0.92), .white.opacity(0.14), .white.opacity(0.20))
                : (.black.opacity(0.70), .black.opacity(0.06), .black.opacity(0.12))
        case .accent(let tint), .roundedTag(let tint):
            return (tint, tint.opacity(colorScheme == .dark ? 0.24 : 0.16), tint.opacity(colorScheme == .dark ? 0.32 : 0.28))
        }
    }
}
package struct AppCornerRibbon: View {
    package let model: AppCornerRibbonModel
    @Environment(\.colorScheme) private var colorScheme

    package var body: some View {
        Text(model.title)
            .font(.caption)
            .bold()
            .padding(.horizontal, AppUI.Spacing.small)
            .padding(.vertical, AppUI.Spacing.xSmall)
            .background(model.tint.opacity(colorScheme == .dark ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(model.tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: AppUI.Stroke.subtle)
            )
            .foregroundStyle(model.tint)
            .accessibilityIdentifier(model.accessibilityIdentifier ?? "app_corner_ribbon")
    }
}
package struct AppStatusDotLabel: View {
    package let title: String
    package let tint: Color

    package var body: some View {
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
