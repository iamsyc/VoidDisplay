import VoidDisplayDesignSystem
import SwiftUI

package struct CapturePreviewToolbar: ToolbarContent {
    @Binding var scaleMode: CapturePreviewScaleMode
    let cursorCapture: Binding<Bool>
    let isUpdatingCursorCapture: Bool
    let isSharingDisplay: Bool

    package var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Scale Mode", selection: $scaleMode) {
                ForEach(CapturePreviewScaleMode.allCases, id: \.self) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 150)
            .accessibilityIdentifier("capture_preview_scale_mode_picker")
            .accessibilityValue(Text(scaleMode.title))
        }
        ToolbarItem(placement: .automatic) {
            HStack(spacing: AppUI.Spacing.small + 2) {
                Text(String(localized: "Cursor"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                Toggle("", isOn: cursorCapture)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Cursor"))
            }
            .padding(.horizontal, AppUI.Spacing.xSmall)
            .disabled(isUpdatingCursorCapture || isSharingDisplay)
            .accessibilityIdentifier("capture_preview_cursor_toggle")
        }
    }
}
