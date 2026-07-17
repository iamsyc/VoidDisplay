import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayObservability

struct DiagnosticsAdvancedSnapshotPanel: View {
    @Binding var isExpanded: Bool

    let snapshot: ObservabilityDiagnosticsSnapshot?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            DiagnosticsAdvancedSnapshotDetails(snapshot: snapshot)
                .padding(.top, AppUI.Spacing.small)
        } label: {
            Label(String(localized: "Technical Details"), systemImage: "curlybraces")
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
    }

}
