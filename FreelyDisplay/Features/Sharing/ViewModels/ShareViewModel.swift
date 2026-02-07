import Foundation
import ScreenCaptureKit
import Cocoa
import CoreGraphics
import Observation
import OSLog

@MainActor
@Observable
final class ShareViewModel {
    struct LoadErrorInfo: Equatable {
        var domain: String
        var code: Int
        var description: String
        var failureReason: String?
        var recoverySuggestion: String?
    }

    var hasScreenCapturePermission: Bool?
    var lastPreflightPermission: Bool?
    var lastRequestPermission: Bool?
    var loadErrorMessage: String?
    var lastLoadError: LoadErrorInfo?
    var showDebugInfo = false

    var displays: [SCDisplay]?
    var isLoadingDisplays = false
    var startingDisplayID: CGDirectDisplayID?
    var showOpenPageError = false
    var openPageErrorMessage = ""

    func syncForCurrentState(appHelper: AppHelper) {
        guard hasScreenCapturePermission == true else {
            displays = nil
            isLoadingDisplays = false
            return
        }
        guard appHelper.isWebServiceRunning else {
            displays = nil
            isLoadingDisplays = false
            return
        }
        guard !appHelper.isSharing else { return }
        loadDisplaysIfNeeded()
    }

    func startService(appHelper: AppHelper) {
        guard appHelper.startWebService() else {
            AppLog.sharing.error("Start service failed.")
            presentError(String(localized: "Failed to start web service."))
            return
        }
        syncForCurrentState(appHelper: appHelper)
    }

    func stopService(appHelper: AppHelper) {
        appHelper.stopWebService()
        syncForCurrentState(appHelper: appHelper)
    }

    func openScreenCapturePrivacySettings(openURL: (URL) -> Void) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            openURL(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            openURL(url)
        }
    }

    func requestScreenCapturePermission(appHelper: AppHelper) {
        let requestResult = CGRequestScreenCaptureAccess()
        lastRequestPermission = requestResult

        let preflightResult = CGPreflightScreenCaptureAccess()
        hasScreenCapturePermission = preflightResult
        lastPreflightPermission = preflightResult

        AppLog.capture.notice(
            "Screen capture permission request (sharing): requestResult=\(requestResult, privacy: .public), preflightResult=\(preflightResult, privacy: .public)"
        )

        if !preflightResult {
            displays = nil
            isLoadingDisplays = false
            loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
            AppLog.capture.notice("Screen capture permission request denied (sharing).")
            return
        }
        syncForCurrentState(appHelper: appHelper)
    }

    func refreshPermissionAndMaybeLoad(appHelper: AppHelper) {
        let granted = CGPreflightScreenCaptureAccess()
        hasScreenCapturePermission = granted
        lastPreflightPermission = granted
        if !granted {
            displays = nil
            isLoadingDisplays = false
            return
        }
        syncForCurrentState(appHelper: appHelper)
    }

    func loadDisplaysIfNeeded() {
        guard !isLoadingDisplays, displays == nil else { return }
        loadDisplays()
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
                    self.isLoadingDisplays = false
                }
            } catch {
                let nsError = error as NSError
                AppErrorMapper.logFailure("Load shareable displays (sharing)", error: error, logger: AppLog.capture)
                await MainActor.run {
                    self.loadErrorMessage = String(localized: "Failed to load displays. Check permission and try again.")
                    self.lastLoadError = .init(
                        domain: nsError.domain,
                        code: nsError.code,
                        description: nsError.localizedDescription,
                        failureReason: nsError.localizedFailureReason,
                        recoverySuggestion: nsError.localizedRecoverySuggestion
                    )
                    self.displays = nil
                    self.isLoadingDisplays = false
                }
            }
        }
    }

    func refreshDisplays(appHelper: AppHelper) {
        guard appHelper.isWebServiceRunning, !appHelper.isSharing else { return }
        loadDisplays()
    }

    func startSharing(display: SCDisplay, appHelper: AppHelper) async {
        guard startingDisplayID == nil else { return }
        startingDisplayID = display.displayID
        defer { startingDisplayID = nil }

        guard appHelper.isWebServiceRunning || appHelper.startWebService() else {
            presentError(String(localized: "Web service is not running."))
            return
        }

        let captureSession = await createScreenCapture(display: display)
        let stream = Capture()

        do {
            try captureSession.stream.addStreamOutput(
                stream,
                type: .screen,
                sampleHandlerQueue: stream.sampleHandlerQueue
            )
            try await captureSession.stream.startCapture()
            appHelper.beginSharing(stream: captureSession.stream, output: stream, delegate: captureSession.delegate)
        } catch {
            appHelper.stopSharing()
            AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
            presentError(AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing.")))
        }
    }

    func openSharePage(appHelper: AppHelper) {
        guard let url = sharePageURL(appHelper: appHelper) else {
            if appHelper.isWebServiceRunning {
                AppLog.sharing.notice("No LAN IP available when opening share page.")
                presentError(String(localized: "No available LAN IP address was found. Please connect to Wi-Fi/Ethernet and try again."))
            } else {
                presentError(String(localized: "Web service is not running."))
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func sharePageAddress(appHelper: AppHelper) -> String? {
        sharePageURL(appHelper: appHelper)?.absoluteString
    }

    func clearError() {
        showOpenPageError = false
    }

    private func presentError(_ message: String) {
        openPageErrorMessage = message
        showOpenPageError = true
    }

    private func sharePageURL(appHelper: AppHelper) -> URL? {
        guard appHelper.isWebServiceRunning else {
            return nil
        }
        guard let ip = getLANIPv4Address() else {
            return nil
        }
        let urlString = "http://\(ip):\(appHelper.webServicePortValue)"
        guard let url = URL(string: urlString) else {
            AppLog.sharing.error("Failed to build share URL: \(urlString, privacy: .public)")
            return nil
        }
        return url
    }
}
