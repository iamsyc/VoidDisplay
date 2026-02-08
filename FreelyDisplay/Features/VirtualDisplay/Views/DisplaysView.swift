//
//  DisplayView.swift
//  FreelyDisplay
//
//  Created by Phineas Guo on 2025/10/4.
//

import SwiftUI
import Cocoa

struct DisplaysView: View {
    @Environment(AppHelper.self) private var appHelper: AppHelper
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
            ContentUnavailableView(
                "No display",
                systemImage: "display.trianglebadge.exclamationmark",
                description: Text("Please [go to the settings app](x-apple.systempreferences:com.apple.preference.displays) to adjust the monitor settings.")
            )
            .accessibilityIdentifier("displays_empty_state")
        }
    }

    private func displayList(_ displays: [NSScreen]) -> some View {
        List(displays, id: \.self) { display in
            displayRow(display)
        }
        .accessibilityIdentifier("displays_list")
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func displayRow(_ display: NSScreen) -> some View {
        let displayID = display.cgDirectDisplayID
        let model = AppListRowModel(
            id: displayID.map(String.init) ?? display.localizedName,
            title: display.localizedName,
            subtitle: resolutionText(for: display),
            status: nil,
            metaBadges: displayBadges(for: display),
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: "display_row_card"
        )

        return AppListRowCard(model: model) {
            EmptyView()
        }
        .appListRowStyle()
    }

    private func resolutionText(for display: NSScreen) -> String {
        "\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))"
    }

    private func displayBadges(for display: NSScreen) -> [AppBadgeModel] {
        let displayID = display.cgDirectDisplayID
        var badges: [AppBadgeModel] = [
            AppBadgeModel(
                title: displayTypeLabel(for: displayID),
                style: displayTypeBadgeStyle(for: displayID)
            )
        ]
        if isPrimaryDisplay(displayID) {
            badges.insert(
                AppBadgeModel(title: String(localized: "Primary Display"), style: .accent(.green)),
                at: 0
            )
        }
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
        if appHelper.isManagedVirtualDisplay(displayID: displayID) {
            return String(localized: "Virtual Display")
        }
        return String(localized: "Physical Display")
    }

    private func displayTypeBadgeStyle(for displayID: CGDirectDisplayID?) -> AppStatusBadge.Style {
        guard let displayID else {
            return .neutral
        }
        if appHelper.isManagedVirtualDisplay(displayID: displayID) {
            return .accent(.blue)
        }
        return .neutral
    }
}

#Preview {
    DisplaysView()
}
