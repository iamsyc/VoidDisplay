import SwiftUI
import VoidDisplayDesignSystem

package struct HomeHeaderControls: View {
    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        summaryHeader
    }

    private var summaryHeader: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    titleBlock
                    Spacer(minLength: AppUI.Spacing.large)
                    summaryActionButtons
                }

                HomeSummaryStatusStrip(context: context)
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    titleBlock
                    Spacer(minLength: AppUI.Spacing.medium)
                    createVirtualDisplayButton
                }
                HomeSummaryStatusStrip(context: context)
                HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                    sharingSettingsButton
                    refreshIconButton
                }
            }
        }
    }

    private var titleBlock: some View {
        Label("Virtual Displays", systemImage: "display.2")
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("home_virtual_display_title")
    }

    private var summaryActionButtons: some View {
        HStack(spacing: AppUI.Spacing.small) {
            createVirtualDisplayButton
            sharingSettingsButton
            refreshIconButton
        }
        .labelStyle(.titleAndIcon)
    }

    private var sharingSettingsButton: some View {
        HomeSharingSettingsPopoverButton(context: context)
    }

    private var createVirtualDisplayButton: some View {
        Button {
            context.actions.createVirtualDisplay()
        } label: {
            Label("Add Virtual Display", systemImage: "plus")
        }
        .appActionButtonStyle(variant: .primary)
        .disabled(context.isCreateVirtualDisplayDisabled)
        .accessibilityIdentifier("home_add_virtual_display_button")
    }

    private var refreshIconButton: some View {
        Button {
            context.actions.refresh()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .appActionButtonStyle(variant: .default)
        .help(Text("Refresh"))
        .accessibilityLabel(Text("Refresh"))
        .accessibilityIdentifier("home_refresh_button")
    }
}
