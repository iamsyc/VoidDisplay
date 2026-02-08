import SwiftUI

struct ScreenCapturePermissionGuideView: View {
    let loadErrorMessage: String?
    let onOpenSettings: () -> Void
    let onRequestPermission: () -> Void
    let onRefresh: () -> Void
    let onRetry: (() -> Void)?
    @Binding var isDebugInfoExpanded: Bool
    let debugItems: [(title: String, value: String)]

    var body: some View {
        ScrollView {
            VStack(spacing: AppUI.Spacing.medium + 2) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("Screen Recording Permission Required")
                    .font(.headline)
                Text("Allow screen recording in System Settings to monitor displays.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: AppUI.Spacing.medium) {
                    Button("Open System Settings") {
                        onOpenSettings()
                    }
                    Button("Request Permission") {
                        onRequestPermission()
                    }
                }

                HStack(spacing: AppUI.Spacing.medium) {
                    Button("Refresh") {
                        onRefresh()
                    }
                    .controlSize(.small)

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
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                VStack(spacing: AppUI.Spacing.xSmall + 2) {
                    Text("After granting permission, you may need to quit and relaunch the app.")
                    Text("If System Settings shows permission is ON but this page still says it is OFF, the change has not been applied to this running app process. Quit (⌘Q) and reopen, or remove and re-add the app in the permission list.")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420, alignment: .leading)
                }
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
