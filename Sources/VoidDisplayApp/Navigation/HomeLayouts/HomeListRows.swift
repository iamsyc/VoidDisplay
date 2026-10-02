import SwiftUI

package struct HomeListRows: View {
    package let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        LazyVStack(alignment: .leading, spacing: context.metrics.itemSpacing) {
            ForEach(context.itemStates) { state in
                HomeVirtualDisplayItem(
                    state: state,
                    metrics: context.metrics,
                    actions: context.actions
                )
                .accessibilityIdentifier("home_virtual_display_list_row")
                if state.item.desiredEnabled && !state.item.isRunning && state.item.hasIssue {
                    HStack {
                        Text("This display could not start. Retry enabling it or edit its settings.").font(.callout)
                        Button("Retry Enable") { context.actions.perform(.retryEnable, for: state) }
                            .disabled(state.isToggling || state.isRebuilding)
                    }
                }
                if context.contentGuideConfigID == state.id {
                    GroupBox {
                        VStack(alignment: .leading) {
                            DisplayContentGuideView(displayName: state.item.title)
                            HStack {
                                if context.previewFailureConfigID == state.id {
                                    Button("Retry Preview") {
                                        context.actions.perform(.preview, for: state)
                                    }
                                    .disabled(state.isPreviewStarting || state.isToggling || state.isRebuilding)
                                    .accessibilityIdentifier("created_display_retry_preview_button")
                                    Button("Screen Recording Settings") {
                                        context.actions.openScreenCapturePrivacySettings()
                                    }
                                }
                                Spacer()
                                Button("Close") {
                                    context.actions.perform(.contentGuide, for: state)
                                }
                            }
                        }
                        .padding(context.metrics.itemVerticalPadding)
                    }
                }
            }
        }
        .accessibilityIdentifier("home_virtual_display_list")
    }
}
