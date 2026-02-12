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
    var startingDisplayIDs: Set<CGDirectDisplayID> = []
    var showOpenPageError = false
    var openPageErrorMessage = ""
    private let permissionProvider: any ScreenCapturePermissionProvider

    init(permissionProvider: (any ScreenCapturePermissionProvider)? = nil) {
        self.permissionProvider = permissionProvider ?? ScreenCapturePermissionProviderFactory.makeDefault()
    }

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
        loadDisplaysIfNeeded(appHelper: appHelper)
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
        let requestResult = permissionProvider.request()
        lastRequestPermission = requestResult

        let preflightResult = permissionProvider.preflight()
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
        let granted = permissionProvider.preflight()
        hasScreenCapturePermission = granted
        lastPreflightPermission = granted
        if !granted {
            displays = nil
            isLoadingDisplays = false
            return
        }
        syncForCurrentState(appHelper: appHelper)
    }

    func loadDisplaysIfNeeded(appHelper: AppHelper) {
        guard !isLoadingDisplays, displays == nil else { return }
        loadDisplays(appHelper: appHelper)
    }

    func loadDisplays(appHelper: AppHelper) {
        if UITestRuntime.isEnabled, UITestRuntime.scenario == .permissionDenied {
            hasScreenCapturePermission = false
            lastPreflightPermission = false
            displays = nil
            isLoadingDisplays = false
            return
        }

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
                    appHelper.registerShareableDisplays(content.displays)
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
        guard appHelper.isWebServiceRunning else { return }
        loadDisplays(appHelper: appHelper)
    }

    @discardableResult
    func withDisplayStartLock(
        displayID: CGDirectDisplayID,
        operation: () async -> Void
    ) async -> Bool {
        guard !startingDisplayIDs.contains(displayID) else { return false }
        startingDisplayIDs.insert(displayID)
        defer { startingDisplayIDs.remove(displayID) }
        await operation()
        return true
    }

    func startSharing(display: SCDisplay, appHelper: AppHelper) async {
        _ = await withDisplayStartLock(displayID: display.displayID) {
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
                appHelper.beginSharing(
                    displayID: display.displayID,
                    stream: captureSession.stream,
                    output: stream,
                    delegate: captureSession.delegate
                )
            } catch {
                appHelper.stopSharing(displayID: display.displayID)
                AppErrorMapper.logFailure("Start sharing", error: error, logger: AppLog.sharing)
                presentError(AppErrorMapper.userMessage(for: error, fallback: String(localized: "Failed to start sharing.")))
            }
        }
    }

    func stopSharing(displayID: CGDirectDisplayID, appHelper: AppHelper) {
        appHelper.stopSharing(displayID: displayID)
    }

    func sharePageAddress(for displayID: CGDirectDisplayID, appHelper: AppHelper) -> String? {
        appHelper.sharePageAddress(for: displayID)
    }

    func clearError() {
        showOpenPageError = false
    }

    private func presentError(_ message: String) {
        openPageErrorMessage = message
        showOpenPageError = true
    }
}
