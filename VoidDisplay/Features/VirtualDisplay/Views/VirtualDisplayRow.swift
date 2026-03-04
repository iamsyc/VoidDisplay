import SwiftUI

@MainActor
struct VirtualDisplayRow: View {
    let config: VirtualDisplayConfig
    let isRunning: Bool
    let isToggling: Bool
    let isRebuilding: Bool
    let rebuildFailureMessage: String?
    let hasRecentApplySuccess: Bool
    let isFirst: Bool
    let isLast: Bool
    let isPrimary: Bool
    let canSetAsPrimary: Bool

    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSetAsPrimary: () -> Void
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRetryRebuild: () -> Void

    private var isRowBusy: Bool {
        isToggling || isRebuilding
    }

    var body: some View {
        let model = AppListRowModel(
            id: config.id.uuidString,
            title: config.displayName,
            subtitle: VirtualDisplayRowPresentation.subtitleText(for: config),
            status: AppRowStatus(
                title: VirtualDisplayRowPresentation.statusLabel(isRunning: isRunning, isRebuilding: isRebuilding),
                tint: VirtualDisplayRowPresentation.statusTint(isRunning: isRunning, isRebuilding: isRebuilding)
            ),
            metaBadges: VirtualDisplayRowPresentation.badges(
                rebuildFailureMessage: rebuildFailureMessage,
                hasRecentApplySuccess: hasRecentApplySuccess
            ),
            ribbon: isPrimary
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green,
                    accessibilityIdentifier: "virtual_display_primary_ribbon"
                )
                : nil,
            iconSystemName: "display",
            isEmphasized: isRunning,
            accessibilityIdentifier: "virtual_display_row_card"
        )

        return AppListRowCard(model: model) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons
                    rebuildAction
                    toggleButton
                    setPrimaryButton
                    editButton
                    deleteButton
                }

                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons
                    rebuildAction
                    toggleButton
                    AppQuickActionsMenu {
                        Button(
                            String(localized: "Set as Primary"),
                            systemImage: isPrimary ? "star.circle.fill" : "star.circle"
                        ) {
                            onSetAsPrimary()
                        }
                        .disabled(!canSetAsPrimary)

                        Divider()

                        Button(String(localized: "Edit"), systemImage: "pencil") {
                            onEdit()
                        }

                        Divider()

                        Button(String(localized: "Delete"), systemImage: "trash", role: .destructive) {
                            onDelete()
                        }
                    }
                    .disabled(isRowBusy)
                }
            }
        }
    }

    private var moveButtons: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button {
                onMoveUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(isFirst || isRowBusy)
            .accessibilityLabel(Text("Move up"))
            .accessibilityIdentifier("virtual_display_move_up_button")

            Button {
                onMoveDown()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(isLast || isRowBusy)
            .accessibilityLabel(Text("Move down"))
            .accessibilityIdentifier("virtual_display_move_down_button")
        }
    }

    private var setPrimaryButton: some View {
        Button {
            onSetAsPrimary()
        } label: {
            Text(String(localized: "Primary Action Glyph"))
                .font(.system(size: 14, weight: .bold))
                .frame(height: 24)
                .foregroundStyle(isPrimary ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!canSetAsPrimary)
        .help(isPrimary ? String(localized: "Primary Display") : String(localized: "Set as Primary"))
        .accessibilityLabel(Text("Set as primary display"))
        .accessibilityIdentifier("virtual_display_set_primary_button")
    }

    @ViewBuilder
    private var rebuildAction: some View {
        if isRebuilding {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Rebuilding")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("virtual_display_rebuild_progress")
        } else if let rebuildFailureMessage {
            Button("Retry Rebuild") {
                onRetryRebuild()
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(isRowBusy)
            .help(rebuildFailureMessage)
            .accessibilityIdentifier("virtual_display_rebuild_retry_button")
        }
    }

    private var toggleButton: some View {
        Button {
            onToggle()
        } label: {
            Label(
                VirtualDisplayRowPresentation.toggleButtonTitle(isRunning: isRunning),
                systemImage: isRunning ? "pause.fill" : "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(isRunning ? .orange : .green)
        .disabled(isRowBusy)
        .accessibilityIdentifier("virtual_display_toggle_button")
    }

    private var editButton: some View {
        Button {
            onEdit()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.title3)
                .frame(height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Edit"))
        .disabled(isRowBusy)
        .accessibilityIdentifier("virtual_display_edit_button")
    }

    private var deleteButton: some View {
        Button {
            onDelete()
        } label: {
            Image(systemName: "trash")
                .font(.title3)
                .frame(height: 24)
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Delete"))
        .disabled(isRowBusy)
        .accessibilityIdentifier("virtual_display_delete_button")
    }
}
