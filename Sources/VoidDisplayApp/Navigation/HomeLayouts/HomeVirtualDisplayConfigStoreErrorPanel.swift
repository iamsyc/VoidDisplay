import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayVirtualDisplay

package struct HomeVirtualDisplayConfigStoreErrorPanel: View {
    package let presentation: VirtualDisplayConfigStorePresentation
    @Binding package var isDetailsExpanded: Bool
    package let resetConfigStore: @MainActor () -> Void

    package init(
        presentation: VirtualDisplayConfigStorePresentation,
        isDetailsExpanded: Binding<Bool>,
        resetConfigStore: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        _isDetailsExpanded = isDetailsExpanded
        self.resetConfigStore = resetConfigStore
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            Label("Virtual Display Config File Unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(
                presentation.loadErrorMessage ??
                    String(localized: "The virtual display config file is incompatible or corrupted. Reset the config file to continue.")
            )
            .font(.body)

            if let diagnostics = presentation.diagnosticsSummary {
                DisclosureGroup(isExpanded: $isDetailsExpanded) {
                    Text(diagnostics)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Text("Details")
                }
            }

            Button("Reset Config File", role: .destructive, action: resetConfigStore)
                .appActionButtonStyle(variant: .danger)
                .accessibilityIdentifier("virtual_display_reset_config_file_button")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: AppUI.Stroke.subtle)
        }
        .accessibilityIdentifier("virtual_display_config_store_error_panel")
    }
}
