import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsHeaderActions: View {
    let isRefreshing: Bool
    let canOpenDataDirectory: Bool
    let onRefresh: () -> Void
    let onOpenDataDirectory: () -> Void

    var body: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Button(action: onRefresh) {
                Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
            }
            .appActionButtonStyle(variant: .default)
            .disabled(isRefreshing)
            .accessibilityIdentifier("diagnostics_refresh_button")

            Button(action: onOpenDataDirectory) {
                Label(String(localized: "Open Data Directory"), systemImage: "folder")
            }
            .appActionButtonStyle(variant: .default)
            .disabled(canOpenDataDirectory == false)
            .accessibilityIdentifier("diagnostics_open_data_directory_button")
        }
        .labelStyle(.titleAndIcon)
    }
}
