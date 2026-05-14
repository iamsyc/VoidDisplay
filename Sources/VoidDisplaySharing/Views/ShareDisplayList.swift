import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import SwiftUI
import ScreenCaptureKit
import Cocoa
import CoreGraphics

@MainActor
package struct ShareDisplayList: View {
    private enum ShareAccessibilityState {
        static let sharing = "sharing"
        static let idle = "idle"
    }

    package let displays: [SCDisplay]
    @Bindable var viewModel: ShareViewModel
    package let runtimeState: ShareRuntimeState
    package let openURLAction: OpenURLAction
    package let displayStatusProvider: ShareDisplayStatusProvider

    package var body: some View {
        VStack(spacing: AppUI.List.sectionSpacing) {
            ShareStatusPanel(
                displayCount: displays.count,
                sharingDisplayCount: runtimeState.activeSharingDisplayIDs.count,
                clientsCount: runtimeState.sharingClientCount,
                isRunning: runtimeState.isWebServiceRunning
            )
            .appListContentInsets(bottom: false)

            ScrollView {
                LazyVStack(spacing: AppUI.List.sectionSpacing) {
                    ForEach(displays, id: \.self) { display in
                        shareableDisplayRow(display)
                    }
                }
                .appListContentInsets(top: false)
            }
        }
        .accessibilityIdentifier("lan_web_view_displays_list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: AppUI.Spacing.small + 2) {
                Divider()
                Text("Share links are reachable from devices on the same local network. Send them only to trusted viewers.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
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
        let displayStatus = displayStatusProvider.status(display.displayID)
        let isVirtual = displayStatus.isManagedVirtualDisplay
        let isSharingDisplay = runtimeState.isDisplaySharing(displayID: display.displayID)
        let displayAddress = runtimeState.sharePageAddress(for: display.displayID)
        let displayURL = displayAddress.flatMap(URL.init(string:))
        let displayClientCount = runtimeState.displayClientCount(for: display.displayID)
        let isPrimaryDisplay = CGDisplayIsMain(display.displayID) != 0
        let isStartingDisplay = runtimeState.isStarting(displayID: display.displayID)

        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: "\(display.width) × \(display.height)",
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
            iconScreenTint: DisplayIconTintResolver.resolve(
                isMonitoring: displayStatus.isMonitoring,
                isSharing: isSharingDisplay
            ),
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            displayRowTrailing(
                display: display,
                displayAddress: displayAddress,
                displayURL: displayURL,
                displayClientCount: displayClientCount,
                isSharingDisplay: isSharingDisplay,
                isStartingDisplay: isStartingDisplay
            )
        }
    }

    @ViewBuilder
    private func displayRowTrailing(
        display: SCDisplay,
        displayAddress: String?,
        displayURL: URL?,
        displayClientCount: Int,
        isSharingDisplay: Bool,
        isStartingDisplay: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                ShareDisplayMetaBar(
                    displayID: display.displayID,
                    displayAddress: displayAddress,
                    displayURL: displayURL,
                    displayClientCount: displayClientCount,
                    isSharingDisplay: isSharingDisplay,
                    openURLAction: openURLAction
                )

                shareActionButton(
                    display: display,
                    isSharingDisplay: isSharingDisplay,
                    isStartingDisplay: isStartingDisplay
                )
            }

            VStack(alignment: .trailing, spacing: AppUI.Spacing.small) {
                ShareDisplayMetaBar(
                    displayID: display.displayID,
                    displayAddress: displayAddress,
                    displayURL: displayURL,
                    displayClientCount: displayClientCount,
                    isSharingDisplay: isSharingDisplay,
                    openURLAction: openURLAction
                )

                shareActionButton(
                    display: display,
                    isSharingDisplay: isSharingDisplay,
                    isStartingDisplay: isStartingDisplay
                )
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
    }

    @ViewBuilder
    private func shareActionButton(
        display: SCDisplay,
        isSharingDisplay: Bool,
        isStartingDisplay: Bool
    ) -> some View {
        Button {
            if isSharingDisplay {
                viewModel.stopSharing(displayID: display.displayID)
            } else {
                Task {
                    await viewModel.startSharing(display: display)
                }
            }
        } label: {
            ZStack {
                Label(String(localized: "Share"), systemImage: "play.fill").hidden()
                Label(String(localized: "Starting"), systemImage: "hourglass").hidden()
                Label(String(localized: "Stop"), systemImage: "stop.fill").hidden()

                if isSharingDisplay {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                } else if isStartingDisplay {
                    Label(String(localized: "Starting"), systemImage: "hourglass")
                } else {
                    Label(String(localized: "Share"), systemImage: "play.fill")
                }
            }
        }
        .appActionButtonStyle(variant: isSharingDisplay ? .danger : .primary)
        .disabled(isStartingDisplay)
        .accessibilityIdentifier("share_action_button_\(display.displayID)")
        .accessibilityValue(
            Text(verbatim: isSharingDisplay ? ShareAccessibilityState.sharing : (isStartingDisplay ? "starting" : ShareAccessibilityState.idle))
        )
    }
}
