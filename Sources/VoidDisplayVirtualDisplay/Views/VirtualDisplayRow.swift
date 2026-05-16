import Foundation
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import SwiftUI

@MainActor
package struct VirtualDisplayRow: View {
    package let config: VirtualDisplayConfig
    package let isRunning: Bool
    package let isToggling: Bool
    package let isRebuilding: Bool
    package let rebuildFailureMessage: String?
    package let hasRecentApplySuccess: Bool
    package let isFirst: Bool
    package let isLast: Bool
    package let isPrimary: Bool
    package let canSetAsPrimary: Bool

    package let onMoveUp: () -> Void
    package let onMoveDown: () -> Void
    package let onSetAsPrimary: () -> Void
    package let onToggle: () -> Void
    package let onEdit: () -> Void
    package let onDelete: () -> Void
    package let onRetryRebuild: () -> Void
    package let iconScreenTint: Color?
    package let uiTestOpenEditAccessibilityIdentifier: String?

    private var isRowBusy: Bool {
        isToggling || isRebuilding
    }

    package var body: some View {
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
            iconScreenTint: iconScreenTint,
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
                    uiTestOpenEditButton
                    editButton
                    deleteButton
                }

                HStack(spacing: AppUI.Spacing.small) {
                    moveButtons
                    rebuildAction
                    toggleButton
                    uiTestOpenEditButton
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
        Button("Edit", systemImage: "square.and.pencil", action: onEdit)
        .labelStyle(.iconOnly)
        .font(.title3)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.borderless)
        .accessibilityRespondsToUserInteraction(true)
        .disabled(isRowBusy)
        .accessibilityIdentifier("virtual_display_edit_button")
    }

    @ViewBuilder
    private var uiTestOpenEditButton: some View {
        if let uiTestOpenEditAccessibilityIdentifier {
            Button("Test Edit", systemImage: "square.and.pencil", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(uiTestOpenEditAccessibilityIdentifier)
        }
    }

    private var deleteButton: some View {
        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        .labelStyle(.iconOnly)
        .font(.title3)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .foregroundStyle(.red)
        .buttonStyle(.borderless)
        .accessibilityRespondsToUserInteraction(true)
        .disabled(isRowBusy)
        .accessibilityIdentifier("virtual_display_delete_button")
    }
}
