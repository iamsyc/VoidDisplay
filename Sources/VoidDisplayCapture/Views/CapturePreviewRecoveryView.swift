import SwiftUI

package struct CapturePreviewRecoveryView: View {
    package let state: CapturePreviewState
    package let isRetrying: Bool
    package let retry: () -> Void
    package let close: () -> Void

    package init(
        state: CapturePreviewState,
        isRetrying: Bool,
        retry: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.state = state
        self.isRetrying = isRetrying
        self.retry = retry
        self.close = close
    }

    package var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .restarting:
                ProgressView()
                    .controlSize(.large)
                Text("Restoring Preview")
                    .font(.headline)
                Text("Reconnecting to the rebuilt display…")
                    .foregroundStyle(.secondary)
            case let .failed(failureCode):
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Preview Could Not Be Restored")
                    .font(.headline)
                Text(failureMessage(failureCode: failureCode))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Close", action: close)
                        .accessibilityIdentifier("capture_preview_close_button")
                    Button(action: retry) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Retry")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetrying)
                    .accessibilityIdentifier("capture_preview_retry_button")
                }
            case .active, .released:
                EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var accessibilityIdentifier: String {
        switch state {
        case .restarting:
            "capture_preview_restarting_state"
        case .failed:
            "capture_preview_failed_state"
        case .active:
            "capture_preview_active_state"
        case .released:
            "capture_preview_released_state"
        }
    }

    private func failureMessage(failureCode: String) -> String {
        switch failureCode {
        case "capture_intent_display_unavailable":
            String(localized: "The rebuilt display is no longer available. Retry or close this window.")
        case "capture_intent_permission_unavailable":
            String(localized: "Screen Recording permission is unavailable. Retry after restoring access, or close this window.")
        default:
            String(localized: "The preview could not be restored. Retry or close this window.")
        }
    }
}
