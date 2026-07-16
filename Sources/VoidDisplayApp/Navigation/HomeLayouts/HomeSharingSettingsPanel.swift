import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation

package struct HomeSharingSettingsPopoverButton: View {
    private let context: HomeLayoutContext
    @State private var isPresented = false

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Label("Sharing Settings", systemImage: "gearshape")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .appActionButtonStyle(variant: .default)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HomeSharingSettingsPanel(context: context)
                .padding(AppUI.Spacing.large)
                .frame(width: 460, alignment: .leading)
        }
        .help(Text(labelText))
        .accessibilityLabel(Text("Sharing Settings"))
        .accessibilityValue(Text(labelText))
        .accessibilityIdentifier("home_sharing_settings_popover_button")
    }

    private var labelText: String {
        "\(String(localized: "Sharing")) \(performanceModeLabel) · \(context.sharingSettings.portInput)"
    }

    private var performanceModeLabel: String {
        switch context.sharingSettings.performanceMode {
        case .automatic:
            String(localized: "Automatic")
        case .smooth:
            String(localized: "Smooth")
        case .powerEfficient:
            String(localized: "Power Efficient")
        }
    }
}

package struct HomeSharingSettingsPanel: View {
    private let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.large) {
                    title
                        .fixedSize(horizontal: true, vertical: false)

                    controlsInline
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                    title
                    controlsResponsive
                }
            }

            Divider()

            permissionStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_sharing_settings_panel")
    }

    private var permissionStatus: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            HomeSummaryStatusItem(
                title: String(localized: "Screen Recording"),
                value: context.permissionStatus.label,
                systemImage: context.permissionStatus.systemImage,
                tint: context.permissionStatus.tint,
                isActive: context.permissionStatus.isActive
            )

            Spacer(minLength: AppUI.Spacing.small)

            if context.permissionStatus.canOpenSettings {
                Button {
                    context.actions.openScreenCapturePrivacySettings()
                } label: {
                    Label("Open Privacy Settings", systemImage: "lock.shield")
                }
                .appActionButtonStyle(variant: .default)
                .accessibilityIdentifier("home_sharing_open_privacy_settings_button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_sharing_screen_recording_permission_status")
    }

    private var controlsResponsive: some View {
        ViewThatFits(in: .horizontal) {
            controlsInline

            controlsStack
        }
    }

    private var controlsInline: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            performanceControl
            Divider()
                .frame(height: 24)
            portControl
        }
    }

    private var controlsStack: some View {
        Grid(alignment: .leading, horizontalSpacing: AppUI.Spacing.small, verticalSpacing: AppUI.Spacing.small) {
            GridRow {
                controlLabel("Performance")
                performancePicker
            }

            GridRow {
                controlLabel("Port")
                VStack(alignment: .leading, spacing: 4) {
                    portValueControls
                    portErrorText
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var title: some View {
        Label("Screen Sharing", systemImage: "network")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private var performanceControl: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            controlLabel("Performance")
            performancePicker
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }

    private var portControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                controlLabel("Port")
                portValueControls
            }

            portErrorText
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }

    private func controlLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var performancePicker: some View {
        Picker("Capture Performance", selection: performanceModeBinding) {
            Text("Automatic").tag(CapturePerformanceMode.automatic)
            Text("Smooth").tag(CapturePerformanceMode.smooth)
            Text("Power Efficient").tag(CapturePerformanceMode.powerEfficient)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .tint(.gray)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("home_sharing_performance_picker")
    }

    private var portValueControls: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            TextField("8089", text: portInputBinding)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
                .onSubmit {
                    context.actions.applySharingPortDraft()
                }
                .accessibilityIdentifier("home_sharing_port_input")

            if context.sharingSettings.isPortDirty {
                Button {
                    context.actions.applySharingPortDraft()
                } label: {
                    Image(systemName: "checkmark")
                }
                .appActionButtonStyle(variant: .default)
                .controlSize(.small)
                .frame(width: 30)
                .help(Text("Apply"))
                .accessibilityLabel(Text("Apply"))
                .accessibilityIdentifier("home_sharing_port_apply_button")
            }

            if context.sharingSettings.isWebServiceRunning {
                HomeSharingPortStatusBadge(port: context.sharingSettings.webServicePortValue)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var portErrorText: some View {
        if let portErrorMessage = context.sharingSettings.portErrorMessage {
            Text(portErrorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 14, alignment: .leading)
                .accessibilityIdentifier("home_sharing_port_error_text")
        }
    }

    private var performanceModeBinding: Binding<CapturePerformanceMode> {
        Binding(
            get: { context.sharingSettings.performanceMode },
            set: { context.actions.setCapturePerformanceMode($0) }
        )
    }

    private var portInputBinding: Binding<String> {
        Binding(
            get: { context.sharingSettings.portInput },
            set: { context.actions.updateSharingPortDraft($0) }
        )
    }
}

package struct HomeSharingPortStatusBadge: View {
    package let port: UInt16

    package init(port: UInt16) {
        self.port = port
    }

    package var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(verbatim: "\(String(localized: "Active Port")) \(String(port))")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(Text("Active Port"))
        .accessibilityIdentifier("home_sharing_active_port_badge")
    }
}
