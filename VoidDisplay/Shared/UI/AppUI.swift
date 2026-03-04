import SwiftUI

// MARK: - Action button variant

enum AppActionVariant {
    case `default`
    case primary
    case danger
}

// MARK: - Design tokens

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
        static let rowMinHeight: CGFloat = 56
        static let iconBoxWidth: CGFloat = 42
        static let iconBoxHeight: CGFloat = 42
        static let rowHorizontalInset: CGFloat = 12
        static let rowVerticalInset: CGFloat = 6
        static let contentInsetTop: CGFloat = 3
        static let contentInsetLeading: CGFloat = 20
        static let contentInsetTrailing: CGFloat = 20
        static let contentInsetBottom: CGFloat = 3
        static let sectionSpacing: CGFloat = 8
        static let listHorizontalInset: CGFloat = 12
        static let listVerticalInset: CGFloat = 3
    }

    enum DebugLayout {
        static let showBorders: Bool = false
        static let borderColor: Color = .red
        static let borderWidth: CGFloat = 1
    }

    // Kept for call-site compat (appActionButtonStyle `state:` parameter).
    enum InteractionState {
        case normal, hover, active, disabled
    }

    // MARK: - Surface helpers

    enum Surface {
        // -- Panel (standalone container: empty-state, start-service panel)
        static func panelFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.06) : .white
        }

        static func panelStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.08)
        }

        // -- Interactive card (list row cards)
        static func cardFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? .white.opacity(0.06)
                : Color(nsColor: .controlBackgroundColor).opacity(0.90)
        }

        static func cardStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
        }

        static func cardHoverStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark
                ? Color.accentColor.opacity(0.55)
                : Color.accentColor.opacity(0.40)
        }

        // -- Tile (icon boxes inside cards)
        static func tileFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.03)
        }

        static func tileStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
        }

        // -- Status bar
        static func statusStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.09)
        }

        // -- Sidebar selection pill
        static func sidebarSelectionFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.28)
        }

        static func sidebarSelectionStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.08)
        }

        // -- Screen background
        static func screenBackground(for _: ColorScheme) -> Color {
            Color(nsColor: .windowBackgroundColor)
        }

        static func screenBackgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
            let topOpacity: Double = colorScheme == .dark ? 0.03 : 0
            return LinearGradient(
                colors: [
                    .white.opacity(topOpacity),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // -- Reduce-transparency fallbacks
        static func fallbackBarFill(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.90)
        }

        static func fallbackBarStroke(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.10)
        }
    }
}

// MARK: - Role enum (call-site compat)

/// Kept so `appGlassBar(role:)` / `appGlassSurface(role:)` call sites compile.
enum AppGlassBarRole {
    case sidebar, panel, interactiveCard, toolbar, status
}

// MARK: ─── View Modifiers ───

/// Screen background: window color + subtle gradient overlay.
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

/// Standalone panel: solid fill + border + shadow.
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
                color: colorScheme == .dark ? .clear : .black.opacity(0.08),
                radius: colorScheme == .dark ? 0 : 8,
                x: 0,
                y: 2
            )
    }
}

/// Tile: small icon container inside cards — subtle fill, no border.
struct AppTile: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                    .fill(AppUI.Surface.tileFill(for: colorScheme))
            )
    }
}

/// Interactive card: solid fill with always-visible border + hover accent stroke.
struct AppInteractiveCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isHovered: Bool

    func body(content: Content) -> some View {
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

/// Toolbar / bottom action bar: native `.ultraThinMaterial` with reduce-transparency fallback.
struct AppToolbarBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(AppUI.Surface.fallbackBarFill(for: colorScheme))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppUI.Surface.fallbackBarStroke(for: colorScheme))
                        .frame(height: AppUI.Stroke.subtle)
                }
        } else {
            content
                .background(.ultraThinMaterial)
        }
    }
}

/// Status panel: `.thinMaterial` with rounded corners + fine border.
struct AppStatusBar: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                        .fill(AppUI.Surface.fallbackBarFill(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                        .stroke(AppUI.Surface.fallbackBarStroke(for: colorScheme), lineWidth: AppUI.Stroke.subtle)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                        .stroke(AppUI.Surface.statusStroke(for: colorScheme), lineWidth: AppUI.Stroke.subtle)
                )
        }
    }
}

/// Sidebar selection pill: translucent highlight + fine border + soft shadow.
struct AppSidebarSelectionPill: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool

    func body(content: Content) -> some View {
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
struct AppActionButton: ViewModifier {
    let variant: AppActionVariant

    func body(content: Content) -> some View {
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

extension View {
    func appScreenBackground() -> some View {
        modifier(AppScreenBackground())
    }

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

    func appActionButtonStyle(
        variant: AppActionVariant = .default,
        state _: AppUI.InteractionState = .normal
    ) -> some View {
        modifier(AppActionButton(variant: variant))
    }

    // MARK: Compat shims

    /// Toolbar / bottom bar — uses `.ultraThinMaterial`.
    func appGlassBar(role: AppGlassBarRole) -> some View {
        switch role {
        case .status:
            return AnyView(modifier(AppStatusBar()))
        default:
            return AnyView(modifier(AppToolbarBar()))
        }
    }

    /// Panel surface — uses solid fill.
    func appGlassSurface(role _: AppGlassBarRole) -> some View {
        modifier(AppPanel())
    }

    /// Sidebar background — system handles it; no-op.
    func appGlassSidebarBackground() -> some View {
        self
    }
}

// MARK: ─── Shared Components ───

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
            let p = badgePresentation
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, AppUI.Spacing.small - 1)
                .padding(.vertical, AppUI.Spacing.xSmall - 1)
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
