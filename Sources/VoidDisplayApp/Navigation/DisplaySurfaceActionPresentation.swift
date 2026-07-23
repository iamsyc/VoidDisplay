import CoreGraphics
import Foundation
import VoidDisplayRuntime
enum DisplaySurfaceActionPresentation {
static func rowActions(
        isPreviewing: Bool,
        isSharing: Bool,
        canStopPreview: Bool,
        canStopLANWebViewSharing: Bool
    ) -> [DisplaySurfaceRowActionPresentation] {
        [
            isPreviewing
                ? DisplaySurfaceRowActionPresentation(
                    kind: .stopPreview,
                    title: String(localized: "Stop"),
                    help: String(localized: "Stop Preview"),
                    systemImage: "stop.circle",
                    accessibilityIdentifier: "displays_action_stop_preview",
                    isEnabled: canStopPreview,
                    isDestructive: true
                )
                : DisplaySurfaceRowActionPresentation(
                    kind: .openPreview,
                    title: String(localized: "Preview"),
                    systemImage: "dot.scope.display",
                    accessibilityIdentifier: "displays_action_open_preview",
                    isEnabled: true
                ),
            isSharing
                ? DisplaySurfaceRowActionPresentation(
                    kind: .stopLANWebView,
                    title: String(localized: "Stop"),
                    help: String(localized: "Stop Sharing"),
                    systemImage: "stop.circle",
                    accessibilityIdentifier: "displays_action_stop_lan_web_view",
                    isEnabled: canStopLANWebViewSharing,
                    isDestructive: true
                )
                : DisplaySurfaceRowActionPresentation(
                    kind: .openLANWebView,
                    title: String(localized: "Sharing"),
                    help: String(localized: "Sharing"),
                    systemImage: "network",
                    accessibilityIdentifier: "displays_action_open_lan_web_view",
                    isEnabled: true
                )
        ]
    }

    static func accessibilitySummary(
        title: String,
        statusItems: [DisplaySurfaceStatusItemPresentation]
    ) -> String {
        let statuses = statusItems
            .map { "\($0.title): \($0.value)" }
            .joined(separator: ", ")
        return "\(title), \(statuses)"
    }
}
