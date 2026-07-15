import SwiftUI
import VoidDisplayDesignSystem

package struct HomeHeaderControls: View {
    package let context: HomeSkinContext
    private let showsSummaryStatus: Bool
    private let showsSharingSettingsPopover: Bool

    package init(
        context: HomeSkinContext,
        showsSummaryStatus: Bool = false,
        showsSharingSettingsPopover: Bool = false
    ) {
        self.context = context
        self.showsSummaryStatus = showsSummaryStatus
        self.showsSharingSettingsPopover = showsSharingSettingsPopover
    }

    package var body: some View {
        if showsSummaryStatus {
            summaryHeader
        } else {
            plainHeader
        }
    }

    private var plainHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                titleBlock
                Spacer(minLength: AppUI.Spacing.large)
                actionButtons
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                titleBlock
                actionButtons
            }
        }
    }

    private var summaryHeader: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    titleBlock
                    Spacer(minLength: AppUI.Spacing.large)
                    classicActionButtons
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

    private var actionButtons: some View {
        HStack(spacing: AppUI.Spacing.small) {
            createVirtualDisplayButton
            refreshTextButton
        }
        .labelStyle(.titleAndIcon)
    }

    private var classicActionButtons: some View {
        HStack(spacing: AppUI.Spacing.small) {
            createVirtualDisplayButton
            sharingSettingsButton
            refreshIconButton
        }
        .labelStyle(.titleAndIcon)
    }

    private var sharingSettingsButton: some View {
        Group {
            if showsSharingSettingsPopover {
                HomeSharingSettingsPopoverButton(context: context)
            }
        }
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

    private var refreshTextButton: some View {
        Button {
            context.actions.refresh()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .appActionButtonStyle(variant: .default)
        .accessibilityIdentifier("home_refresh_button")
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
