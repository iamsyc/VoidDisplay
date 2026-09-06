import SwiftUI
import VoidDisplayDesignSystem

package struct MenuBarVirtualDisplayRow: View {
    private static let copyConfirmationDuration: Duration = .seconds(2)

    package let state: HomeVirtualDisplayItemRenderState
    package let performAction: @MainActor (MenuBarVirtualDisplayAction) -> Void

    @State private var copyFeedback = HomeCopyShareAddressFeedbackState()

    package init(
        state: HomeVirtualDisplayItemRenderState,
        performAction: @escaping @MainActor (MenuBarVirtualDisplayAction) -> Void
    ) {
        self.state = state
        self.performAction = performAction
    }

    private var item: HomeVirtualDisplayItemPresentation { state.item }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                identity

                if !showsSupplementalActions {
                    toggleButton
                }
            }

            if showsSupplementalActions {
                HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                    toggleButton

                    if showsPreviewAction {
                        previewButton
                    }

                    if showsWebViewAction {
                        webViewButton
                    }

                    if item.shareAddress != nil {
                        copyButton
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, AppUI.Spacing.xSmall + 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu_bar_virtual_display_row")
        .onChange(of: item.shareAddress) { _, _ in
            copyFeedback.cancelConfirmation()
        }
        .task(id: copyFeedback.revision) {
            await hideCopyConfirmationAfterDelay(revision: copyFeedback.revision)
        }
    }

    private var showsSupplementalActions: Bool {
        showsPreviewAction || showsWebViewAction || item.shareAddress != nil
    }

    private var showsPreviewAction: Bool {
        item.isPreviewing || state.isPreviewStarting || !state.isPreviewActionDisabled
    }

    private var showsWebViewAction: Bool {
        item.isSharing || state.isWebViewStarting || !state.isWebViewActionDisabled
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            Image(systemName: "display")
                .font(.body)
                .foregroundStyle(item.statusTone.tintColor)
                .frame(width: AppUI.Spacing.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(item.statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(item.statusTone.tintColor)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.accessibilitySummary))
    }

    private var toggleButton: some View {
        Button(action: toggleDisplay) {
            MenuBarQuickActionLabel(
                title: String(localized: item.desiredEnabled ? "Disable" : "Enable"),
                systemImage: item.desiredEnabled ? "pause.fill" : "play.fill",
                isWorking: state.isToggling || state.isRebuilding
            )
        }
        .buttonStyle(.bordered)
        .tint(item.desiredEnabled ? .secondary : .green)
        .controlSize(.small)
        .disabled(state.isToggling || state.isRebuilding)
        .accessibilityValue(state.isToggling ? Text("Working") : Text(verbatim: ""))
        .accessibilityIdentifier("menu_bar_virtual_display_toggle_button")
    }

    private var previewButton: some View {
        Button(action: openPreview) {
            MenuBarQuickActionLabel(
                title: String(localized: "Preview"),
                systemImage: "dot.scope.display",
                isWorking: state.isPreviewStarting
            )
        }
        .appActionButtonStyle(variant: .default)
        .controlSize(.small)
        .disabled(state.isPreviewActionDisabled)
        .help(Text("Preview"))
        .accessibilityLabel(Text("Preview"))
        .accessibilityValue(state.isPreviewStarting ? Text("Working") : Text(verbatim: ""))
        .accessibilityIdentifier("menu_bar_open_preview_button")
    }

    private var webViewButton: some View {
        Button(action: toggleWebView) {
            MenuBarQuickActionLabel(
                title: String(localized: "Web Sharing"),
                systemImage: item.isSharing ? "stop.circle" : "network",
                isWorking: state.isWebViewStarting
            )
        }
        .appActionButtonStyle(variant: .default)
        .controlSize(.small)
        .disabled(state.isWebViewActionDisabled)
        .help(Text(item.isSharing ? "Stop LAN Web View" : "Open LAN Web View"))
        .accessibilityLabel(Text(item.isSharing ? "Stop LAN Web View" : "Open LAN Web View"))
        .accessibilityValue(state.isWebViewStarting ? Text("Working") : Text(verbatim: ""))
        .accessibilityIdentifier("menu_bar_web_view_button")
    }

    private var copyButton: some View {
        Button(action: copyShareAddress) {
            Label(
                copyFeedback.isShowingConfirmation
                    ? String(localized: "Copied")
                    : String(localized: "Copy Access Link"),
                systemImage: copyFeedback.isShowingConfirmation ? "checkmark" : "doc.on.doc"
            )
            .labelStyle(.iconOnly)
            .frame(width: AppUI.Spacing.large, height: AppUI.Spacing.large)
        }
        .appActionButtonStyle(variant: .default)
        .controlSize(.small)
        .disabled(item.shareAddress == nil)
        .help(Text("Copy Access Link"))
        .accessibilityLabel(Text("Copy Access Link"))
        .accessibilityValue(
            copyFeedback.isShowingConfirmation
                ? Text("Copied")
                : Text(verbatim: item.shareAddress ?? "")
        )
        .accessibilityIdentifier("menu_bar_copy_access_link_button")
    }

    private func toggleDisplay() {
        performAction(.toggle)
    }

    private func openPreview() {
        performAction(.openPreview)
    }

    private func toggleWebView() {
        performAction(.toggleWebView)
    }

    private func copyShareAddress() {
        guard item.shareAddress != nil else { return }
        performAction(.copyShareAddress)
        copyFeedback.beginConfirmation()
    }

    private func hideCopyConfirmationAfterDelay(revision: UInt64) async {
        guard copyFeedback.isShowingConfirmation else { return }
        do {
            try await Task.sleep(for: Self.copyConfirmationDuration)
        } catch {
            return
        }
        copyFeedback.endConfirmation(ifCurrent: revision)
    }
}
