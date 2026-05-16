import Cocoa
import CoreGraphics
import Foundation
import SwiftUI
import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayVirtualDisplay

package struct SystemDisplaysView: View {
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(\.openURL) private var openURL

    private let activityProvider: any DisplayActivityStatusProviding
    @State private var displays: [NSScreen]?

    package init(activityProvider: any DisplayActivityStatusProviding) {
        self.activityProvider = activityProvider
    }

    package var body: some View {
        content
            .accessibilityIdentifier("system_displays_root")
            .onAppear {
                displays = NSScreen.screens
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            ) { _ in
                displays = NSScreen.screens
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        openDisplaySettings()
                    } label: {
                        Label("Open System Settings", systemImage: "gearshape")
                    }
                    .help(String(localized: "Open System Display Settings"))
                    .accessibilityIdentifier("displays_open_system_settings")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let displays, !displays.isEmpty {
            displayList(displays)
        } else {
            ScrollView {
                ContentUnavailableView(
                    "No display",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Please [go to the settings app](x-apple.systempreferences:com.apple.preference.displays) to adjust the display settings.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
                .appListContentInsets()
                .accessibilityIdentifier("system_displays_empty_state")
            }
        }
    }

    private func displayList(_ displays: [NSScreen]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 320), spacing: AppUI.List.sectionSpacing, alignment: .top)
                ],
                spacing: AppUI.List.sectionSpacing
            ) {
                ForEach(displays, id: \.self) { display in
                    displayRow(display)
                }
            }
            .accessibilityIdentifier("system_displays_list")
            .appListContentInsets()
        }
        .accessibilityIdentifier("system_displays_list")
    }

    private func displayRow(_ display: NSScreen) -> some View {
        let displayID = display.cgDirectDisplayID
        let isPrimary = displayID.map(isPrimaryDisplay) ?? false
        let activityStatus = displayID.map {
            activityProvider.activityStatus(for: $0)
        } ?? .inactive
        let iconScreenTint = DisplayIconTintResolver.resolve(
            isPreviewing: activityStatus.isPreviewing,
            isSharing: activityStatus.isSharing
        )
        let model = AppListRowModel(
            id: displayID.map(String.init) ?? display.localizedName,
            title: display.localizedName,
            subtitle: resolutionText(for: display),
            status: nil,
            metaBadges: displayBadges(for: display),
            ribbon: isPrimary
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            iconScreenTint: iconScreenTint,
            isEmphasized: true,
            accessibilityIdentifier: "system_display_row_card"
        )

        return AppListRowCard(model: model, pushTrailingToEdge: false) {
            EmptyView()
        }
    }

    private func resolutionText(for display: NSScreen) -> String {
        let backingSize = display.convertRectToBacking(display.frame).size
        return "\(Int(backingSize.width)) × \(Int(backingSize.height))"
    }

    private func displayBadges(for display: NSScreen) -> [AppBadgeModel] {
        [
            AppBadgeModel(
                title: displayTypeLabel(for: display.cgDirectDisplayID),
                style: displayTypeBadgeStyle(for: display.cgDirectDisplayID)
            )
        ]
    }

    private func isPrimaryDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsMain(displayID) != 0
    }

    private func openDisplaySettings() {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays") else {
            return
        }
        openURL(settingsURL)
    }

    private func displayTypeLabel(for displayID: CGDirectDisplayID?) -> String {
        guard let displayID else {
            return String(localized: "Physical Display")
        }
        if virtualDisplay.isManagedVirtualDisplay(displayID: displayID) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayTypeBadgeStyle(for displayID: CGDirectDisplayID?) -> AppStatusBadge.Style {
        guard let displayID else {
            return .roundedTag(tint: .gray)
        }
        if virtualDisplay.isManagedVirtualDisplay(displayID: displayID) {
            return .roundedTag(tint: .blue)
        }
        return .roundedTag(tint: .gray)
    }
}
