import SwiftUI
import VoidDisplayDesignSystem

package struct DisplayContentGuideView: View {
    package let displayName: String

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            Text("Put content on this display")
                .font(.headline)
            Text(displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("1. In System Settings > Displays, use this display as an extended display and check its position.")
            Text("2. Drag your document window by its title bar onto that display. Check the document in Preview.")
            Text("3. Share this display and open its link on another device. Check a document update, then continue working on your main screen.")
            Text("Preview shows the screen. Use the original document window to edit its content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("display_content_guide")
    }
}
