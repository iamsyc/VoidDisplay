import SwiftUI

struct AppListRowCard<Trailing: View>: View {
    let model: AppListRowModel
    private let trailing: Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(model: AppListRowModel, @ViewBuilder trailing: () -> Trailing) {
        self.model = model
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AppUI.Spacing.small + 2) {
            iconTile

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(model.isEmphasized ? .primary : .secondary)

                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !model.metaBadges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.metaBadges) { badge in
                            AppStatusBadge(title: badge.title, style: badge.style)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .frame(minHeight: AppUI.List.rowMinHeight)
        .padding(.horizontal, AppUI.List.rowHorizontalInset)
        .padding(.vertical, AppUI.List.rowVerticalInset)
        .appInteractiveCardStyle(isHovered: isHovered)
        .offset(y: isHovered && !reduceMotion ? -AppUI.List.hoverLift : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(model.accessibilityIdentifier ?? "app_list_row_card")
    }

    private var iconTile: some View {
        ZStack {
            Circle()
                .fill(.primary.opacity(0.05))
                .frame(width: AppUI.List.iconBoxHeight - 4, height: AppUI.List.iconBoxHeight - 4)
            Image(systemName: model.iconSystemName)
                .font(.system(size: 14, weight: .semibold)) // Increased weight for better visibility
                .foregroundStyle(model.isEmphasized ? .primary : .secondary)
        }
        .frame(width: AppUI.List.iconBoxWidth, height: AppUI.List.iconBoxHeight, alignment: .center)
    }
}
