import SwiftUI

struct AppListRowCard<Trailing: View>: View {
    let model: AppListRowModel
    private let trailing: Trailing

    @State private var isHovered = false

    init(model: AppListRowModel, @ViewBuilder trailing: () -> Trailing) {
        self.model = model
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AppUI.Spacing.small) {
            iconTile

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(model.isEmphasized ? .primary : .secondary)

                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if model.status != nil || !model.metaBadges.isEmpty {
                    HStack(spacing: 6) {
                        if let status = model.status {
                            AppStatusDotLabel(title: status.title, tint: status.tint)
                        }

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
        .onHover { hovered in
            isHovered = hovered
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(model.accessibilityIdentifier ?? "app_list_row_card")
    }

    private var iconTile: some View {
        Image(systemName: model.iconSystemName)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(model.isEmphasized ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.secondary))
            .frame(width: AppUI.List.iconBoxWidth, height: AppUI.List.iconBoxHeight, alignment: .center)
    }
}
