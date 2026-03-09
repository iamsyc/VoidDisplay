//
//  DisplayView.swift
//  VoidDisplay
//
//

import SwiftUI
import Cocoa

struct DisplaysView: View {
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(CaptureController.self) private var capture
    @Environment(SharingController.self) private var sharing
    @Environment(\.openURL) private var openURL
    @State private var displays: [NSScreen]?

    var body: some View {
        content
            .onAppear {
                displays = NSScreen.screens
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
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
            .appScreenBackground()
    }

    @ViewBuilder
    private var content: some View {
        if let displays = displays, !displays.isEmpty {
            displayList(displays)
        } else {
            ScrollView {
                ContentUnavailableView(
                    "No display",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("Please [go to the settings app](x-apple.systempreferences:com.apple.preference.displays) to adjust the monitor settings.")
                )
                .frame(maxWidth: .infinity, minHeight: 200)
                .appListContentInsets()
                .accessibilityIdentifier("displays_empty_state")
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
            .appListContentInsets()
        }
        .accessibilityIdentifier("displays_list")
    }

    private func displayRow(_ display: NSScreen) -> some View {
        let displayID = display.cgDirectDisplayID
        let isPrimary = isPrimaryDisplay(displayID)

        let isMonitoring: Bool = displayID.map { did in
            capture.screenCaptureSessions.contains { $0.displayID == did }
        } ?? false
        let isSharing: Bool = displayID.map { did in
            sharing.isDisplaySharing(displayID: did)
        } ?? false
        let iconScreenTint = DisplayIconTintResolver.resolve(isMonitoring: isMonitoring, isSharing: isSharing)

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
            accessibilityIdentifier: "display_row_card"
        )

        return AppListRowCard(model: model) {
            EmptyView()
        }
    }

    private func resolutionText(for display: NSScreen) -> String {
        // NSScreen.frame is in points; convert to backing coordinates so the UI shows pixel
        // resolution (aligned with SCDisplay-based screens that expose pixel dimensions directly).
        let backingSize = display.convertRectToBacking(display.frame).size
        return "\(Int(backingSize.width)) × \(Int(backingSize.height))"
    }

    private func displayBadges(for display: NSScreen) -> [AppBadgeModel] {
        let displayID = display.cgDirectDisplayID
        let badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: displayTypeBadgeStyle(for: displayID)
            )
        ]
        return badges
    }

    private func isPrimaryDisplay(_ displayID: CGDirectDisplayID?) -> Bool {
        guard let displayID else {
            return false
        }
        return CGDisplayIsMain(displayID) != 0
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

#Preview {
    let env = AppBootstrap.makeEnvironment(preview: true, isRunningUnderXCTestOverride: false)
    DisplaysView()
        .environment(env.capture)
        .environment(env.sharing)
        .environment(env.virtualDisplay)
}
