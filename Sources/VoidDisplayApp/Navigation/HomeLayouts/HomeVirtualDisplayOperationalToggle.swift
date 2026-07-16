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
        HStack(spacing: AppUI.Spacing.xSmall) {
            Toggle(isOn: runtimeStateBinding) {
                Label {
                    Text(statusItem.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(iconForegroundColor)
                        .frame(width: 13)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DisplaySurfaceStatusTone.success.tintColor)
            .disabled(isDisabled)
            .accessibilityValue(Text(displayedStatusValue))
            .accessibilityIdentifier(accessibilityIdentifier)

            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }

            if showsStatusDetail {
                Text(displayedStatusValue)
                    .fontWeight(.semibold)
                    .foregroundStyle(detailForegroundColor)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
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

    private var isPending: Bool {
        if isStarting { return true }
        return statusItem.tone == .warning
    }

    private var showsStatusDetail: Bool {
        if isStarting { return true }
        return switch statusItem.tone {
        case .warning, .danger:
            true
        case .neutral, .info, .success:
            false
        }
    }

    private var iconForegroundColor: Color {
        statusItem.tone == .neutral ? .secondary : statusItem.tone.tintColor
    }

    private var detailForegroundColor: Color {
        isStarting ? .secondary : statusItem.tone.tintColor
    }
}
