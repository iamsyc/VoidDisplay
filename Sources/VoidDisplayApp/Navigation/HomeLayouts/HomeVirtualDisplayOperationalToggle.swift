import SwiftUI
import VoidDisplayDesignSystem

package struct HomeVirtualDisplayOperationalToggle: View {
    package let statusItem: DisplaySurfaceStatusItemPresentation
    package let systemImage: String
    package let isOn: Bool
    package let isStarting: Bool
    package let isDisabled: Bool
    package let accessibilityIdentifier: String
    package let onToggle: @MainActor () -> Void

    package init(
        statusItem: DisplaySurfaceStatusItemPresentation,
        systemImage: String,
        isOn: Bool,
        isStarting: Bool,
        isDisabled: Bool,
        accessibilityIdentifier: String,
        onToggle: @escaping @MainActor () -> Void
    ) {
        self.statusItem = statusItem
        self.systemImage = systemImage
        self.isOn = isOn
        self.isStarting = isStarting
        self.isDisabled = isDisabled
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onToggle = onToggle
    }

    package var body: some View {
        Toggle(isOn: runtimeStateBinding) {
            Label {
                Text(statusItem.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } icon: {
                Group {
                    if isStarting || statusItem.tone == .warning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(statusItem.tone.tintColor)
                            .accessibilityHidden(true)
                    } else if statusItem.tone == .danger {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(statusItem.tone.tintColor)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(iconForegroundColor)
                    }
                }
                .frame(width: 13, height: 13)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(DisplaySurfaceStatusTone.success.tintColor)
        .disabled(isDisabled)
        .accessibilityValue(Text(displayedStatusValue))
        .accessibilityIdentifier(accessibilityIdentifier)
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .help(Text("\(statusItem.title): \(displayedStatusValue)"))
    }

    private var runtimeStateBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { nextValue in
                guard nextValue != isOn, !isDisabled else { return }
                onToggle()
            }
        )
    }

    private var displayedStatusValue: String {
        isStarting ? String(localized: "Starting") : statusItem.value
    }

    private var iconForegroundColor: Color {
        statusItem.tone == .neutral ? .secondary : statusItem.tone.tintColor
    }
}
