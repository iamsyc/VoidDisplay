import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class CaptureChooseViewModel {
    struct LoadErrorInfo: Equatable {
        var domain: String
        var code: Int
        var description: String
        var failureReason: String?
        var recoverySuggestion: String?
    }

    var displays: [SCDisplay]?
    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var isLoadingDisplays = false
    var loadErrorMessage: String?
    var lastLoadError: LoadErrorInfo?
    var showDebugInfo = false

    func isVirtualDisplay(_ display: SCDisplay, appHelper: AppHelper) -> Bool {
        if appHelper.displays.contains(where: { $0.displayID == display.displayID }) {
            return true
        }

        let name = displayName(for: display)
        if appHelper.displays.contains(where: { $0.name == name }) {
            return true
        }

        let width = Int(display.frame.width)
        let height = Int(display.frame.height)
        let runningConfigs = appHelper.displayConfigs.filter { appHelper.isVirtualDisplayRunning(configId: $0.id) }

        return runningConfigs.contains { config in
            guard config.name == name else { return false }
            return config.modes.contains { mode in
                mode.width == width && mode.height == height
            }
        }
    }

    func displayName(for display: SCDisplay) -> String {
        NSScreen.screens.first(where: { $0.cgDirectDisplayID == display.displayID })?.localizedName ?? "Monitor"
    }

    func resolutionText(for display: SCDisplay) -> String {
        "\(Int(display.frame.width)) × \(Int(display.frame.height))"
    }

    func startMonitoring(display: SCDisplay, appHelper: AppHelper, openWindow: @escaping (UUID) -> Void) async {
        let captureSession = await createScreenCapture(display: display)
        let session = AppHelper.ScreenMonitoringSession(
            id: UUID(),
            displayID: display.displayID,
            displayName: displayName(for: display),
            resolutionText: resolutionText(for: display),
            isVirtualDisplay: isVirtualDisplay(display, appHelper: appHelper),
            stream: captureSession.stream,
            delegate: captureSession.delegate
        )
        appHelper.addMonitoringSession(session)
        openWindow(session.id)
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    func requestScreenCapturePermission() {
        let granted = CGRequestScreenCaptureAccess()
        hasScreenCapturePermission = granted
        lastRequestPermission = granted
        if !granted {
            AppLog.capture.notice("Screen capture permission request denied.")
        }
        if granted {
            loadDisplays()
        }
    }

    func refreshPermissionAndMaybeLoad() {
        let granted = CGPreflightScreenCaptureAccess()
        hasScreenCapturePermission = granted
        lastPreflightPermission = granted
        if !granted {
            AppLog.capture.notice("Screen capture permission preflight denied.")
        }
        if granted {
            loadDisplays()
        }
    }

    func loadDisplays() {
        guard !isLoadingDisplays else { return }
        isLoadingDisplays = true
        loadErrorMessage = nil
        lastLoadError = nil
        displays = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                await MainActor.run {
                    self.displays = content.displays
                    self.hasScreenCapturePermission = true
                    self.lastPreflightPermission = true
                }
            } catch {
                let nsError = error as NSError
                AppErrorMapper.logFailure("Load shareable displays", error: error, logger: AppLog.capture)
                await MainActor.run {
                    self.loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
                    self.lastLoadError = .init(
                        domain: nsError.domain,
                        code: nsError.code,
                        description: nsError.localizedDescription,
                        failureReason: nsError.localizedFailureReason,
                        recoverySuggestion: nsError.localizedRecoverySuggestion
                    )
                }
            }
            await MainActor.run {
                self.isLoadingDisplays = false
            }
        }
    }
}
