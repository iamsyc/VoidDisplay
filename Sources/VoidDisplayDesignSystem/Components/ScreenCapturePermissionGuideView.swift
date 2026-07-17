import Foundation
import SwiftUI
package struct ScreenCapturePermissionGuideView: View {
    package let loadErrorMessage: String?
    package let onOpenSettings: () -> Void
    package let onRequestPermission: () -> Void
    package let onRefresh: () -> Void
    package let onRetry: (() -> Void)?
    @Binding var isDebugInfoExpanded: Bool
    package let debugItems: [(title: String, value: String)]
    package let rootAccessibilityIdentifier: String?
    package let openSettingsButtonAccessibilityIdentifier: String?
    package let requestPermissionButtonAccessibilityIdentifier: String?
    package let refreshButtonAccessibilityIdentifier: String?

    package init(
        loadErrorMessage: String?,
        onOpenSettings: @escaping () -> Void,
        onRequestPermission: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onRetry: (() -> Void)?,
        isDebugInfoExpanded: Binding<Bool>,
        debugItems: [(title: String, value: String)],
        rootAccessibilityIdentifier: String?,
        openSettingsButtonAccessibilityIdentifier: String?,
        requestPermissionButtonAccessibilityIdentifier: String?,
        refreshButtonAccessibilityIdentifier: String?
    ) {
        self.loadErrorMessage = loadErrorMessage
        self.onOpenSettings = onOpenSettings
        self.onRequestPermission = onRequestPermission
        self.onRefresh = onRefresh
        self.onRetry = onRetry
        _isDebugInfoExpanded = isDebugInfoExpanded
        self.debugItems = debugItems
        self.rootAccessibilityIdentifier = rootAccessibilityIdentifier
        self.openSettingsButtonAccessibilityIdentifier = openSettingsButtonAccessibilityIdentifier
        self.requestPermissionButtonAccessibilityIdentifier = requestPermissionButtonAccessibilityIdentifier
        self.refreshButtonAccessibilityIdentifier = refreshButtonAccessibilityIdentifier
    }

    package var body: some View {
        permissionPanel
    }

    private var permissionPanel: some View {
        VStack(spacing: AppUI.Spacing.medium + 2) {
            Image(systemName: "lock.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Screen Recording Permission Required")
                .font(.headline)
            Text("Allow screen recording in System Settings to preview displays.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: AppUI.Spacing.medium) {
                Button("Open System Settings") {
                    onOpenSettings()
                }
                .optionalAccessibilityIdentifier(openSettingsButtonAccessibilityIdentifier)

                Button("Request Permission") {
                    onRequestPermission()
                }
                .optionalAccessibilityIdentifier(requestPermissionButtonAccessibilityIdentifier)
            }

            HStack(spacing: AppUI.Spacing.medium) {
                Button("Refresh") {
                    onRefresh()
                }
                .controlSize(.small)
                .optionalAccessibilityIdentifier(refreshButtonAccessibilityIdentifier)

                if let onRetry {
                    Button("Retry") {
                        onRetry()
                    }
                    .controlSize(.small)
                }
            }

            if let loadErrorMessage {
                Text(loadErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(spacing: AppUI.Spacing.xSmall + 2) {
                Text("After granting permission, you may need to quit and relaunch the app.")
                Text("If System Settings shows permission is ON but this page still says it is OFF, the change has not been applied to this running app process. Quit (⌘Q) and reopen, or remove and re-add the app in the permission list.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            DisclosureGroup("Debug Info", isExpanded: $isDebugInfoExpanded) {
                VStack(alignment: .leading, spacing: AppUI.Spacing.small - 2) {
                    ForEach(Array(debugItems.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(verbatim: item.value)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppUI.Spacing.large)
        .frame(maxWidth: 760)
        .accessibilityElement(children: .contain)
        .optionalAccessibilityIdentifier(rootAccessibilityIdentifier)
    }
}

private extension View {
    @ViewBuilder
    func optionalAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
