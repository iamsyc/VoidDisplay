import SwiftUI
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation

@MainActor
struct ShareDisplayList: View {
    private enum ShareAccessibilityState {
        static let sharing = "sharing"
        static let idle = "idle"
    }

    let displays: [SCDisplay]
    @Bindable var viewModel: ShareViewModel
    let openURLAction: OpenURLAction

    @Environment(SharingController.self) private var sharing
    @Environment(VirtualDisplayController.self) private var virtualDisplay

    var body: some View {
        VStack(spacing: AppUI.Spacing.small) {
            ShareStatusPanel(
                displayCount: displays.count,
                sharingDisplayCount: sharing.activeSharingDisplayIDs.count,
                clientsCount: sharing.sharingClientCount,
                isRunning: sharing.isWebServiceRunning
            )
            .padding(.horizontal, AppUI.List.listHorizontalInset)
            .padding(.top, AppUI.Spacing.small + 2)

            ScrollView {
                LazyVStack(spacing: AppUI.Spacing.small) {
                    ForEach(displays, id: \.self) { display in
                        shareableDisplayRow(display)
                    }
                }
                .padding(.horizontal, AppUI.List.listHorizontalInset)
                .padding(.bottom, AppUI.Spacing.small)
                .padding(.top, 2)
            }
        }
        .accessibilityIdentifier("share_displays_list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: AppUI.Spacing.small + 2) {
                Divider()
                Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppUI.Spacing.large)
            .padding(.top, AppUI.Spacing.small + 2)
            .padding(.bottom, AppUI.Spacing.medium)
        }
    }

    private func shareableDisplayRow(_ display: SCDisplay) -> some View {
        let displayName = NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName
            ?? String(localized: "Monitor")
        let isVirtual = virtualDisplay.isManagedVirtualDisplay(displayID: display.displayID)
        let isSharingDisplay = sharing.isDisplaySharing(displayID: display.displayID)
        let displayAddress = viewModel.sharePageAddress(for: display.displayID, sharing: sharing)
        let displayURL = displayAddress.flatMap(URL.init(string:))
        let displayClientCount = sharing.sharingClientCounts[display.displayID] ?? 0
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0

        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: "\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))",
            status: AppRowStatus(
                title: isSharingDisplay
                    ? String(localized: "Sharing in Progress")
                    : String(localized: "Not Sharing"),
                tint: isSharingDisplay ? .green : .gray
            ),
            metaBadges: [
                AppBadgeModel(
                    title: isVirtual
                        ? String(localized: "Virtual Display")
                        : String(localized: "Physical Display"),
                    style: isVirtual
                        ? .roundedTag(tint: .blue)
                        : .roundedTag(tint: .gray)
                )
            ],
            ribbon: isPrimaryDisplay
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            displayRowTrailing(
                display: display,
                displayAddress: displayAddress,
                displayURL: displayURL,
                displayClientCount: displayClientCount,
                isSharingDisplay: isSharingDisplay
            )
        }
    }

    @ViewBuilder
    private func displayRowTrailing(
        display: SCDisplay,
        displayAddress: String?,
        displayURL: URL?,
        displayClientCount: Int,
        isSharingDisplay: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            if let displayAddress {
                displayAddressInline(
                    displayID: display.displayID,
                    displayAddress: displayAddress,
                    displayURL: displayURL,
                    isSharingDisplay: isSharingDisplay
                )
            }

            HStack(spacing: AppUI.Spacing.xSmall) {
                Image(systemName: "person.2")
                    .font(.caption)
                    .foregroundStyle(displayClientCount > 0 ? Color.accentColor : .secondary)
                Text("\(displayClientCount)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(connectedClientsAccessibilityLabel(displayClientCount))

            shareActionButton(display: display, isSharingDisplay: isSharingDisplay)
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }

    private func displayAddressInline(
        displayID: CGDirectDisplayID,
        displayAddress: String,
        displayURL: URL?,
        isSharingDisplay: Bool
    ) -> some View {
        HStack(spacing: AppUI.Spacing.xSmall) {
            if let displayURL {
                Button {
                    openURLAction(displayURL)
                } label: {
                    Image(systemName: "link")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSharingDisplay ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isSharingDisplay)
                .help(String(localized: "Open Share Page"))
                .accessibilityLabel(String(localized: "Open Share Page"))
            }

            Text(displayAddress)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityIdentifier("share_display_address_\(displayID)")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayAddress, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Copy display address"))
        }
    }

    private func connectedClientsAccessibilityLabel(_ count: Int) -> String {
        let format = String(localized: "%lld connected")
        return String.localizedStringWithFormat(format, Int64(count))
    }

    @ViewBuilder
    private func shareActionButton(display: SCDisplay, isSharingDisplay: Bool) -> some View {
        Button {
            if isSharingDisplay {
                viewModel.stopSharing(displayID: display.displayID, sharing: sharing)
            } else {
                Task {
                    await viewModel.startSharing(display: display, sharing: sharing)
                }
            }
        } label: {
            ZStack {
                Label(String(localized: "Share"), systemImage: "play.fill").hidden()
                Label(String(localized: "Stop"), systemImage: "stop.fill").hidden()

                if isSharingDisplay {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                } else {
                    Label(String(localized: "Share"), systemImage: "play.fill")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(isSharingDisplay ? .red : .accentColor)
        .accessibilityIdentifier("share_action_button_\(display.displayID)")
        .accessibilityValue(
            Text(verbatim: isSharingDisplay ? ShareAccessibilityState.sharing : ShareAccessibilityState.idle)
        )
    }
}
